# frozen_string_literal: true

InformerGVK = Struct.new(:group, :version, :kind, :resource)

class InformerSpecEventRecorder
  attr_reader :events

  def initialize
    @events = []
    @mutex = Mutex.new
  end

  def handle(type, obj)
    @mutex.synchronize { @events << [type, obj] }
  end
end

RSpec.describe KrubyController::Cache::Informer do
  let(:gvk) { InformerGVK.new("stable.example.com", "v1", "CronTask", "crontasks") }
  let(:store) { KrubyController::Cache::Store.new }
  let(:response) { double("response") }
  let(:request) { double("request", run: response) }
  let(:api_client) { instance_double(Kubernetes::ApiClient, build_request: request) }
  let(:informer) { described_class.new(gvk: gvk, store: store, api_client: api_client) }

  describe "#populate" do
    context "when list succeeds" do
      let(:response) do
        double(
          "response",
          success?: true,
          code: 200,
          status_message: "OK",
          body: {
            "items" => [
              { "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "100" } },
              { "metadata" => { "namespace" => "default", "name" => "b", "resourceVersion" => "101" } }
            ],
            "metadata" => { "resourceVersion" => "101" }
          }.to_json
        )
      end

      it "stores all items and marks the informer as synced" do
        informer.send(:populate)

        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_a(Hash)
        expect(informer.synced).to be true
      end

      it "tracks the list resourceVersion" do
        informer.send(:populate)

        expect(informer.instance_variable_get(:@resource_version)).to eq("101")
      end

      it "requests the namespaced list path with bearer auth" do
        expect(api_client).to receive(:build_request)
          .with("GET", "/apis/stable.example.com/v1/crontasks", auth_names: ["BearerToken"])
          .and_return(request)

        informer.send(:populate)
      end
    end

    context "when list fails" do
      let(:response) do
        double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}")
      end

      it "records the sync error after exhausting retries instead of raising" do
        allow(informer).to receive(:interruptible_sleep)
        informer.instance_variable_set(:@running, true)

        informer.send(:populate)

        expect(informer.synced).to be false
        expect(informer.sync_error).to be_a(KrubyController::Error)
        expect(informer.sync_error.message).to include("403")
        expect(api_client).to have_received(:build_request).exactly(4).times
      end
    end

    context "when re-populated after a stop (restart)" do
      def make_item(name, rev)
        { "metadata" => { "namespace" => "default", "name" => name, "resourceVersion" => rev } }
      end

      def make_list(items, rev)
        { "items" => items, "metadata" => { "resourceVersion" => rev } }.to_json
      end

      it "replaces the store and emits the diff, dropping objects deleted while stopped" do
        deleted = KrubyController::Cache::Delta::DELETED
        items1 = [make_item("a", "100"), make_item("b", "101")]
        items2 = [make_item("a", "100")]
        resp1 = double("response", success?: true, code: 200, body: make_list(items1, "101"))
        resp2 = double("response", success?: true, code: 200, body: make_list(items2, "105"))
        allow(api_client).to receive(:build_request)
          .and_return(double("request", run: resp1), double("request", run: resp2))
        recorder = InformerSpecEventRecorder.new
        informer.add_handler(recorder)

        informer.instance_variable_set(:@running, true)
        informer.send(:populate) # first run: a, b
        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_a(Hash)

        # Simulate a stop + restart: the store is intact (still a, b).
        informer.instance_variable_set(:@synced, false)
        informer.instance_variable_set(:@resource_version, nil)

        informer.send(:populate) # second run: only a (b was deleted while stopped)

        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_nil # deleted while stopped, now dropped
        expect(recorder.events).to include(
          [deleted, hash_including("metadata" => hash_including("name" => "b"))]
        )
      end
    end
  end

  describe "initial List failure lifecycle" do
    let(:response) do
      double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}")
    end

    it "records the sync error and does not wait forever for the watch" do
      allow(api_client).to receive(:build_request).and_return(double("request", run: response))
      allow(informer).to receive(:interruptible_sleep)
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      watch_started = false
      allow(fake_watch).to receive(:connect) { watch_started = true }

      informer.start
      deadline = Time.now + 5
      sleep 0.05 until informer.sync_error || Time.now >= deadline

      expect(informer.synced).to be false
      expect(informer.sync_error).to be_a(KrubyController::Error)
      # The watch never started: it waits for the List, which failed.
      expect(watch_started).to be false
    ensure
      informer.stop
    end
  end

  describe "list path resolution" do
    it "uses /api for core resources" do
      core_gvk = InformerGVK.new("", "v1", "Pod", "pods")
      informer = described_class.new(gvk: core_gvk, store: store, api_client: api_client)

      expect(informer.send(:list_path_for, core_gvk)).to eq("/api/v1/pods")
    end

    it "uses /apis for group-scoped resources" do
      expect(informer.send(:list_path_for, gvk)).to eq("/apis/stable.example.com/v1/crontasks")
    end

    it "uses the namespaced path for namespaced resources when a namespace is set" do
      ns_informer = described_class.new(gvk: gvk, store: store, api_client: api_client, namespace: "team-a")
      gvk_with_scope = KrubyController::GVK.new(
        group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks"
      )

      expect(ns_informer.send(:list_path_for, gvk_with_scope))
        .to eq("/apis/stable.example.com/v1/namespaces/team-a/crontasks")
    end

    it "uses the namespaced /api path for core resources when a namespace is set" do
      ns_informer = described_class.new(gvk: gvk, store: store, api_client: api_client, namespace: "team-a")
      core_gvk = KrubyController::GVK.new(group: "", version: "v1", kind: "ConfigMap", resource: "configmaps")

      expect(ns_informer.send(:list_path_for, core_gvk)).to eq("/api/v1/namespaces/team-a/configmaps")
    end

    it "keeps cluster-scoped resources cluster-wide even when a namespace is set" do
      ns_informer = described_class.new(gvk: gvk, store: store, api_client: api_client, namespace: "team-a")
      cluster_gvk = KrubyController::GVK.new(
        group: "stable.example.com", version: "v1", kind: "ClusterThing",
        resource: "clusterthings", namespaced: false
      )

      expect(ns_informer.send(:list_path_for, cluster_gvk)).to eq("/apis/stable.example.com/v1/clusterthings")
    end
  end

  describe "watch relist (stale watch recovery)" do
    let(:recorder) { InformerSpecEventRecorder.new }
    let(:informer) { described_class.new(gvk: gvk, store: store, api_client: api_client) }
    let(:added) { KrubyController::Cache::Delta::ADDED }
    let(:deleted) { KrubyController::Cache::Delta::DELETED }

    def item(name, rev, namespace: "default")
      { "metadata" => { "namespace" => namespace, "name" => name, "resourceVersion" => rev } }
    end

    def list_response(items, rev)
      double("response", success?: true, code: 200, status_message: "OK",
                         body: { "items" => items, "metadata" => { "resourceVersion" => rev } }.to_json)
    end

    def stub_list(responses)
      requests = responses.map { |resp| double("request", run: resp) }
      allow(api_client).to receive(:build_request).and_return(*requests, requests.last)
    end

    def stub_watch(&behavior)
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      paths = []
      paths_mutex = Mutex.new
      allow(fake_watch).to receive(:connect) do |path, &block|
        paths_mutex.synchronize { paths << path }
        behavior.call(paths_mutex.synchronize { paths.size }, path, block)
      end
      paths
    end

    def wait_until(timeout: 5)
      deadline = Time.now + timeout
      sleep 0.05 until deadline <= Time.now || yield
    end

    after { informer.stop }

    it "relists, syncs the store, and reconnects with the fresh resourceVersion after a 410 Gone" do
      stub_list([
                  list_response([item("a", "100"), item("b", "101")], "101"),
                  list_response([item("a", "100"), item("c", "102")], "102")
                ])
      paths = stub_watch do |size, _path, _block|
        raise KrubyController::Error, "410 Gone" if size == 1

        sleep 0.05
        raise KrubyController::Error, "410 Gone"
      end

      informer.add_handler(recorder)
      informer.start
      # Waiting for the second connection guarantees the first relist fully
      # completed: the store was replaced, the ADDED/DELETED diff events were
      # emitted to handlers, and @resource_version advanced to 102. Waiting on
      # the store alone would only prove `replace` ran, not that the events
      # were delivered.
      wait_until { paths.size >= 2 }

      expect(store.get("default", "a")).to be_a(Hash)
      expect(store.get("default", "c")).to be_a(Hash)
      expect(store.get("default", "b")).to be_nil
      expect(paths.size).to be >= 2
      expect(paths.last).to include("resourceVersion=102")
      expect(recorder.events).to include(
        [added, hash_including("metadata" => hash_including("name" => "c"))]
      )
      expect(recorder.events).to include(
        [deleted, hash_including("metadata" => hash_including("name" => "b"))]
      )
    end

    it "delivers all relist events to surviving handlers even when one handler raises" do
      raising = Class.new do
        def handle(_type, _obj)
          raise "handler boom"
        end
      end.new
      recorder = InformerSpecEventRecorder.new

      stub_list([
                  list_response([item("a", "100"), item("b", "101")], "101"),
                  list_response([item("a", "100"), item("c", "102")], "102")
                ])
      paths = stub_watch do |size, _path, _block|
        raise KrubyController::Error, "410 Gone" if size == 1

        sleep 0.05
        raise KrubyController::Error, "410 Gone"
      end

      informer.add_handler(raising)
      informer.add_handler(recorder)
      informer.start
      wait_until { paths.size >= 2 }

      # The store snapshot is already committed by the first relist, so a
      # retry would compare identical snapshots and emit nothing. The recorder
      # must still receive every diff event despite the first handler raising.
      names = recorder.events.map { |(_type, obj)| obj.dig("metadata", "name") }
      expect(names).to include("c")
      expect(names).to include("b")
    end

    it "relists when the watch stream closes cleanly" do
      stub_list([list_response([item("a", "100")], "100")])
      paths = stub_watch do |size, _path, _block|
        if size == 1
          # first watch closes cleanly (no error)
        else
          sleep 0.05
          raise KrubyController::Error, "closed"
        end
      end

      informer.start
      wait_until { paths.size >= 2 }

      expect(paths.size).to be >= 2
      expect(store.get("default", "a")).to be_a(Hash)
    end

    it "retries a failed relist until the list succeeds" do
      stub_list([
                  list_response([item("a", "100")], "100"),
                  double("response", success?: false, code: 500, status_message: "ISE", body: "{}"),
                  list_response([item("a", "100"), item("d", "103")], "103")
                ])
      stub_watch do |_size, _path, _block|
        sleep 0.05
        raise KrubyController::Error, "410 Gone"
      end

      informer.start
      wait_until { store.get("default", "d") }

      expect(store.get("default", "d").dig("metadata", "resourceVersion")).to eq("103")
    end
  end
end
