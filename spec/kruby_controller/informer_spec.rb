# frozen_string_literal: true

require "timeout"

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
    let(:generation) { informer.instance_variable_get(:@generation) }

    before { informer.instance_variable_set(:@running, true) }

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
        informer.send(:populate, generation)

        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_a(Hash)
        expect(informer.synced).to be true
      end

      it "tracks the list resourceVersion" do
        informer.send(:populate, generation)

        expect(informer.instance_variable_get(:@resource_version)).to eq("101")
      end

      it "requests the namespaced list path with bearer auth" do
        expect(api_client).to receive(:build_request)
          .with("GET", "/apis/stable.example.com/v1/crontasks", auth_names: ["BearerToken"])
          .and_return(request)

        informer.send(:populate, generation)
      end

      it "allows a handler to stop the run before further delivery or sync" do
        stopping = double("stopping handler")
        allow(stopping).to receive(:handle) { informer.stop }
        recorder = InformerSpecEventRecorder.new
        informer.add_handler(stopping)
        informer.add_handler(recorder)

        informer.send(:populate, generation)

        expect(stopping).to have_received(:handle).once
        expect(recorder.events).to be_empty
        expect(informer.synced).to be false
      end
    end

    context "when list fails" do
      let(:response) do
        double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}")
      end

      it "records the sync error after exhausting retries instead of raising" do
        allow(informer).to receive(:interruptible_sleep)
        informer.instance_variable_set(:@running, true)

        informer.send(:populate, generation)

        expect(informer.synced).to be false
        expect(informer.sync_error).to be_a(KrubyController::Error)
        expect(informer.sync_error.message).to include("403")
        expect(api_client).to have_received(:build_request).exactly(4).times
      end

      it "does not record a sync error when stopped mid-retry" do
        allow(api_client).to receive(:build_request).and_return(double("request", run: response))
        allow(informer).to receive(:interruptible_sleep) do
          informer.instance_variable_set(:@running, false) # simulate a stop during backoff
        end
        informer.instance_variable_set(:@running, true)

        informer.send(:populate, generation)

        expect(informer.synced).to be false
        expect(informer.sync_error).to be_nil
        expect(api_client).to have_received(:build_request).once
      end
    end

    context "when list fails transiently then succeeds" do
      it "succeeds on a later attempt and syncs" do
        failed = double(
          "request",
          run: double("response", success?: false, code: 500, status_message: "ISE", body: "{}")
        )
        ok_body = {
          "items" => [{ "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "100" } }],
          "metadata" => { "resourceVersion" => "100" }
        }.to_json
        ok = double("request", run: double("response", success?: true, code: 200, status_message: "OK", body: ok_body))
        allow(api_client).to receive(:build_request).and_return(failed, ok)
        allow(informer).to receive(:interruptible_sleep)
        informer.instance_variable_set(:@running, true)

        informer.send(:populate, generation)

        expect(informer.synced).to be true
        expect(store.get("default", "a")).to be_a(Hash)
      end

      it "can recover on the third retry with exponential backoff" do
        calls = 0
        allow(informer).to receive(:fetch_list) do
          calls += 1
          raise KrubyController::Error, "transient failure" if calls < 4

          { "items" => [], "metadata" => { "resourceVersion" => "100" } }
        end
        expect(informer).to receive(:interruptible_sleep).with(1.0, generation).ordered
        expect(informer).to receive(:interruptible_sleep).with(2.0, generation).ordered
        expect(informer).to receive(:interruptible_sleep).with(4.0, generation).ordered

        informer.send(:populate, generation)

        expect(informer.synced).to be true
        expect(informer.sync_error).to be_nil
        expect(informer).to have_received(:fetch_list).exactly(4).times
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
        informer.send(:populate, generation) # first run: a, b
        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_a(Hash)

        # Simulate a stop + restart: the store is intact (still a, b).
        informer.instance_variable_set(:@synced, false)
        informer.instance_variable_set(:@resource_version, nil)

        informer.send(:populate, generation) # second run: only a (b was deleted while stopped)

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

    it "does not start the watch until the retried List succeeds" do
      # The first List attempt fails and the second succeeds. The watch must
      # not start while the List is still retrying; it connects only after the
      # List has actually succeeded, so it cannot race a retrying List.
      calls = 0
      allow(informer).to receive(:fetch_list) do
        calls += 1
        raise KrubyController::Error, "transient list failure" if calls == 1

        { "items" => [], "metadata" => { "resourceVersion" => "100" } }
      end
      allow(informer).to receive(:interruptible_sleep)
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      synced_when_connected = []
      allow(fake_watch).to receive(:connect) { synced_when_connected << informer.synced }

      informer.start
      deadline = Time.now + 5
      sleep 0.05 until informer.synced || Time.now >= deadline
      deadline = Time.now + 2
      sleep 0.05 until synced_when_connected.any? || Time.now >= deadline

      expect(informer.synced).to be true
      # Every time the watch connected, the List had already succeeded.
      expect(synced_when_connected).not_to be_empty
      expect(synced_when_connected).to all(be(true))
    ensure
      informer.stop
    end

    it "clears a stale sync error before a new run" do
      informer.instance_variable_set(:@sync_error, KrubyController::Error.new("stale 403"))
      allow(informer).to receive(:populate) # no-op: do not re-set sync_error

      informer.start

      expect(informer.sync_error).to be_nil
    ensure
      informer.stop
    end
  end

  describe "#stop (bounded join)" do
    it "does not block longer than the join timeout when a worker thread is stuck" do
      stuck = Thread.new { sleep 120 }
      start = Time.now
      informer.send(:join_bounded, stuck, timeout: 0.2)
      elapsed = Time.now - start

      expect(elapsed).to be < 5
      # The stuck thread is left running (it will end when its stream closes);
      # we do not kill it here, only to keep the spec tidy.
      expect(stuck.alive?).to be true
    ensure
      stuck.kill if stuck&.alive?
    end

    it "returns immediately for an already-finished thread" do
      done = Thread.new { nil }
      done.join
      start = Time.now
      informer.send(:join_bounded, done, timeout: 0.2)
      expect(Time.now - start).to be < 0.5
    end
  end

  describe "workers that outlive stop" do
    let(:recorder) { InformerSpecEventRecorder.new }
    let(:workers) { [] }
    let(:list_started) { ::Queue.new }
    let(:list_release) { ::Queue.new }
    let(:watch_connections) { ::Queue.new }
    let(:watch_gates) { [] }

    def snapshot(name, version)
      {
        "items" => [{ "metadata" => { "namespace" => "default", "name" => name, "resourceVersion" => version } }],
        "metadata" => { "resourceVersion" => version }
      }
    end

    def start_run
      informer.start
      workers << informer.instance_variable_get(:@populate_thread)
      workers << informer.instance_variable_get(:@watch_thread)
    end

    def next_connection
      Timeout.timeout(3) { watch_connections.pop }
    end

    before do
      stub_const("#{described_class}::STOP_JOIN_TIMEOUT", 0.05)
      informer.add_handler(recorder)
      watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(watch)
      allow(watch).to receive(:connect) do |path, &callback|
        gate = ::Queue.new
        watch_gates << gate
        watch_connections << { path: path, gate: gate, thread: Thread.current }
        loop do
          event = gate.pop
          break unless event

          callback.call(event)
        end
      end
    end

    after do
      informer.stop
      workers.size.times { list_release << nil }
      watch_gates.each { |gate| gate << nil }
      workers.each do |worker|
        joined = worker.join(3)
        worker.kill unless joined
        expect(joined).not_to be_nil
      end
    end

    it "ignores an initial List response arriving after stop" do
      allow(informer).to receive(:fetch_list) do
        list_started << true
        list_release.pop
        snapshot("stale", "100")
      end
      start_run
      Timeout.timeout(3) { list_started.pop }

      informer.stop
      expect(workers.first.alive?).to be true
      list_release << nil
      expect(workers.first.join(3)).not_to be_nil

      expect(store.list).to be_empty
      expect(recorder.events).to be_empty
      expect(informer.synced).to be false
      expect(informer.sync_error).to be_nil
      expect(watch_connections).to be_empty
    end

    it "does not let a previous List overwrite the restarted run's snapshot" do
      calls = 0
      allow(informer).to receive(:fetch_list) do
        calls += 1
        if calls == 1
          list_started << true
          list_release.pop
          snapshot("stale", "100")
        else
          snapshot("current", "200")
        end
      end
      start_run
      Timeout.timeout(3) { list_started.pop }
      old_populate = workers.first
      informer.stop

      start_run
      connection = next_connection
      events = recorder.events.dup
      list_release << nil
      expect(old_populate.join(3)).not_to be_nil

      expect(store.list).to eq(snapshot("current", "200")["items"])
      expect(recorder.events).to eq(events)
      expect(informer.instance_variable_get(:@resource_version)).to eq("200")
      expect(informer.synced).to be true
      expect(connection[:path]).to include("resourceVersion=200")
    end

    it "does not retry or publish an old List failure after restart" do
      calls = 0
      allow(informer).to receive(:fetch_list) do
        calls += 1
        if calls == 1
          list_started << true
          list_release.pop
          raise KrubyController::Error, "old List failed"
        end

        snapshot("current", "200")
      end
      allow(informer).to receive(:interruptible_sleep)
      start_run
      Timeout.timeout(3) { list_started.pop }
      old_populate = workers.first
      informer.stop

      start_run
      next_connection
      list_release << nil
      expect(old_populate.join(3)).not_to be_nil

      expect(informer).to have_received(:fetch_list).twice
      expect(informer.sync_error).to be_nil
      expect(store.list).to eq(snapshot("current", "200")["items"])
    end

    it "does not publish an exhausted List error from a previous run" do
      calls = 0
      allow(informer).to receive(:fetch_list) do
        calls += 1
        if calls <= 4
          if calls == 4
            list_started << true
            list_release.pop
          end
          raise KrubyController::Error, "old List failed"
        end

        snapshot("current", "200")
      end
      allow(informer).to receive(:interruptible_sleep)
      start_run
      Timeout.timeout(3) { list_started.pop }
      old_populate = workers.first
      informer.stop

      start_run
      next_connection
      list_release << nil
      expect(old_populate.join(3)).not_to be_nil

      expect(informer.sync_error).to be_nil
      expect(informer.synced).to be true
      expect(informer).to have_received(:fetch_list).exactly(5).times
    end

    it "ignores Watch events after stop and does not reconnect" do
      allow(informer).to receive(:fetch_list).and_return(snapshot("current", "200"))
      start_run
      connection = next_connection
      events = recorder.events.dup

      informer.stop
      expect(connection[:thread].alive?).to be true
      connection[:gate] << { "type" => "DELETED", "object" => snapshot("current", "201")["items"].first }
      connection[:gate] << nil
      expect(connection[:thread].join(3)).not_to be_nil

      expect(store.list).to eq(snapshot("current", "200")["items"])
      expect(recorder.events).to eq(events)
      expect(informer.instance_variable_get(:@resource_version)).to eq("200")
      expect(informer.synced).to be false
      expect(informer).to have_received(:fetch_list).once
      expect(watch_connections).to be_empty
    end

    it "does not let an old Watch update or relist after restart" do
      allow(informer).to receive(:fetch_list).and_return(snapshot("old", "100"), snapshot("current", "200"))
      start_run
      old_connection = next_connection
      informer.stop

      start_run
      current_connection = next_connection
      events = recorder.events.dup
      old_connection[:gate] << { "type" => "ADDED", "object" => snapshot("stale", "101")["items"].first }
      old_connection[:gate] << nil
      expect(old_connection[:thread].join(3)).not_to be_nil

      expect(store.list).to eq(snapshot("current", "200")["items"])
      expect(recorder.events).to eq(events)
      expect(informer.instance_variable_get(:@resource_version)).to eq("200")
      expect(informer).to have_received(:fetch_list).twice
      expect(current_connection[:path]).to include("resourceVersion=200")
      expect(watch_connections).to be_empty
    end

    it "still applies Watch events and notifies handlers in the active run" do
      allow(informer).to receive(:fetch_list).and_return(snapshot("current", "200"))
      start_run
      connection = next_connection
      object = snapshot("current", "201")["items"].first
      event = [KrubyController::Cache::Delta::MODIFIED, object]

      connection[:gate] << { "type" => "MODIFIED", "object" => object }
      Timeout.timeout(3) { sleep 0.01 until recorder.events.include?(event) }

      expect(store.get("default", "current")).to eq(object)
      expect(informer.instance_variable_get(:@resource_version)).to eq("201")
      expect(informer.synced).to be true
      expect(informer).to have_received(:fetch_list).once
    end

    it "discards a relist response from a stopped run after restart" do
      calls = 0
      allow(informer).to receive(:fetch_list) do
        calls += 1
        if calls == 2
          list_started << true
          list_release.pop
          snapshot("stale", "101")
        else
          snapshot("current", "200")
        end
      end
      start_run
      old_connection = next_connection
      old_connection[:gate] << nil
      Timeout.timeout(3) { list_started.pop }
      informer.stop

      start_run
      next_connection
      events = recorder.events.dup
      list_release << nil
      expect(old_connection[:thread].join(3)).not_to be_nil

      expect(store.list).to eq(snapshot("current", "200")["items"])
      expect(recorder.events).to eq(events)
      expect(informer.instance_variable_get(:@resource_version)).to eq("200")
      expect(informer).to have_received(:fetch_list).exactly(3).times
      expect(watch_connections).to be_empty
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
