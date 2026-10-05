# frozen_string_literal: true

InformerGVK = Struct.new(:group, :version, :kind, :resource)

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

      it "retries the list instead of raising, and stops when the informer is stopped" do
        allow(informer).to receive(:sleep) # skip the backoff
        informer.instance_variable_set(:@running, true) # as if started
        thread = Thread.new { informer.send(:populate) }

        sleep 0.2
        expect(informer.synced).to be false
        expect(api_client).to have_received(:build_request).at_least(:twice)

        informer.stop
        thread.join
        expect(thread).not_to be_alive
      end
    end

    context "when list fails transiently then succeeds" do
      let(:failed_request) do
        double("request", run: double("response", success?: false, code: 500, status_message: "ISE", body: "{}"))
      end
      let(:ok_request) do
        double(
          "request",
          run: double(
            "response",
            success?: true,
            code: 200,
            status_message: "OK",
            body: {
              "items" => [
                { "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "100" } }
              ],
              "metadata" => { "resourceVersion" => "100" }
            }.to_json
          )
        )
      end

      it "succeeds on a later attempt and syncs" do
        allow(api_client).to receive(:build_request).and_return(failed_request, ok_request)
        allow(informer).to receive(:sleep) # skip the backoff
        informer.instance_variable_set(:@running, true) # as if started

        informer.send(:populate)

        expect(informer.synced).to be true
        expect(store.get("default", "a")).to be_a(Hash)
      end
    end

    context "when the list keeps failing" do
      let(:failing_request) do
        double("request", run: double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}"))
      end

      it "gives up after the initial List plus 3 retries and records the sync error" do
        allow(api_client).to receive(:build_request).and_return(failing_request)
        allow(informer).to receive(:interruptible_sleep)
        informer.instance_variable_set(:@running, true)

        informer.send(:populate)

        expect(api_client).to have_received(:build_request).exactly(4).times
        expect(informer.synced).to be false
        expect(informer.sync_error).to be_a(KrubyController::Error)
        expect(informer.sync_error.message).to include("403")
      end

      it "does not record a sync error when stopped mid-retry" do
        allow(api_client).to receive(:build_request).and_return(failing_request)
        allow(informer).to receive(:interruptible_sleep) do
          informer.instance_variable_set(:@running, false) # simulate a stop during backoff
        end
        informer.instance_variable_set(:@running, true)

        informer.send(:populate)

        expect(informer.synced).to be false
        expect(informer.sync_error).to be_nil
      end
    end

    it "never opens the watch while the initial List is still failing" do
      watch_connects = 0
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      allow(fake_watch).to receive(:connect) { |_path, &_blk| watch_connects += 1 }

      allow(api_client).to receive(:build_request).and_return(
        double("request",
               run: double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}"))
      )
      allow(informer).to receive(:interruptible_sleep)

      informer.start
      deadline = Time.now + 5
      sleep 0.05 until informer.sync_error || Time.now >= deadline

      expect(informer.synced).to be false
      expect(watch_connects).to eq(0)
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

  describe "list path resolution" do
    it "uses /api for core resources" do
      core_gvk = InformerGVK.new("", "v1", "Pod", "pods")
      informer = described_class.new(gvk: core_gvk, store: store, api_client: api_client)

      expect(informer.send(:list_path_for, core_gvk)).to eq("/api/v1/pods")
    end

    it "uses /apis for group-scoped resources" do
      expect(informer.send(:list_path_for, gvk)).to eq("/apis/stable.example.com/v1/crontasks")
    end
  end
end
