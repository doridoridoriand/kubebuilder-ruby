# frozen_string_literal: true

RSpec.describe KrubyController::Cache::SharedCache do
  let(:api_client) { instance_double(Kubernetes::ApiClient) }
  let(:cache) { described_class.new }
  let(:gvk) { KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask") }
  let(:other_gvk) { KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "Job") }

  before { allow(cache).to receive(:api_client).and_return(api_client) }

  describe "#register" do
    it "creates an informer wired to the shared api client" do
      informer = cache.register(gvk: gvk)

      expect(informer).to be_a(KrubyController::Cache::Informer)
      expect(informer.gvk).to be(gvk)
      # The informer must hold the cache's shared client (not some other one).
      expect(informer.instance_variable_get(:@api_client)).to be(api_client)
    end

    it "memoizes the informer per GVK" do
      expect(cache.register(gvk: gvk)).to be(cache.register(gvk: gvk))
    end

    it "returns distinct informers for distinct GVKs" do
      expect(cache.register(gvk: gvk)).not_to be(cache.register(gvk: other_gvk))
    end
  end

  describe "#get" do
    it "delegates to the informer store" do
      informer = cache.register(gvk: gvk)
      obj = { "metadata" => { "namespace" => "default", "name" => "a" } }
      informer.store.add(KrubyController::Cache::Delta::ADDED, obj)

      expect(cache.get(gvk, "default", "a")).to eq(obj)
    end

    it "returns nil when no informer is registered" do
      expect(cache.get(gvk, "default", "a")).to be_nil
    end
  end

  describe "#list" do
    it "returns all objects when no namespace filter is given" do
      informer = cache.register(gvk: gvk)
      informer.store.add(KrubyController::Cache::Delta::ADDED,
                         { "metadata" => { "namespace" => "team-a", "name" => "a" } })
      informer.store.add(KrubyController::Cache::Delta::ADDED,
                         { "metadata" => { "namespace" => "team-b", "name" => "b" } })

      expect(cache.list(gvk).size).to eq(2)
    end

    it "filters results by namespace" do
      informer = cache.register(gvk: gvk)
      informer.store.add(KrubyController::Cache::Delta::ADDED,
                         { "metadata" => { "namespace" => "team-a", "name" => "a" } })
      informer.store.add(KrubyController::Cache::Delta::ADDED,
                         { "metadata" => { "namespace" => "team-b", "name" => "b" } })

      result = cache.list(gvk, namespace: "team-a")

      expect(result.map { |o| o.dig("metadata", "name") }).to eq(["a"])
    end

    it "returns an empty list when no informer is registered" do
      expect(cache.list(gvk)).to eq([])
    end
  end

  describe "lifecycle delegation" do
    it "start delegates to every informer" do
      informer = cache.register(gvk: gvk)
      other = cache.register(gvk: other_gvk)
      expect(informer).to receive(:start)
      expect(other).to receive(:start)

      cache.start
    end

    it "stop delegates to every informer" do
      informer = cache.register(gvk: gvk)
      other = cache.register(gvk: other_gvk)
      expect(informer).to receive(:stop)
      expect(other).to receive(:stop)

      cache.stop
    end

    it "returns true once every informer is synced" do
      informer = cache.register(gvk: gvk)
      other = cache.register(gvk: other_gvk)
      allow(informer).to receive(:synced).and_return(true)
      allow(informer).to receive(:sync_error).and_return(nil)
      allow(other).to receive(:synced).and_return(true)
      allow(other).to receive(:sync_error).and_return(nil)

      expect(cache.wait_for_sync).to be(true)
    end

    it "does not report synced until every informer is synced" do
      informer = cache.register(gvk: gvk)
      other = cache.register(gvk: other_gvk)
      allow(informer).to receive(:synced).and_return(true)
      allow(informer).to receive(:sync_error).and_return(nil)
      # 'other' never syncs, so wait_for_sync must time out (false), proving
      # it waits for every registered informer, not just the first.
      allow(other).to receive(:synced).and_return(false)
      allow(other).to receive(:sync_error).and_return(nil)

      expect(cache.wait_for_sync(timeout: 0.2)).to be(false)
    end

    it "raises the informer's sync error when one exhausts its initial-List retries" do
      informer = cache.register(gvk: gvk)
      err = KrubyController::Error.new("Informer list failed (HTTP 403)")
      allow(informer).to receive(:synced).and_return(false)
      allow(informer).to receive(:sync_error).and_return(err)

      expect { cache.wait_for_sync(timeout: 1) }.to raise_error(KrubyController::Error, /403/)
    end
  end

  describe "lifecycle against a fake API (integration)" do
    let(:fake_api_client) { instance_double(Kubernetes::ApiClient) }

    before { allow(cache).to receive(:api_client).and_return(fake_api_client) }

    def list_response(items, rev)
      double("response", success?: true, code: 200, status_message: "OK",
                         body: { "items" => items, "metadata" => { "resourceVersion" => rev } }.to_json)
    end

    it "populates informers from the API and serves synchronized objects" do
      allow(fake_api_client).to receive(:build_request).and_return(
        double("request", run: list_response(
          [
            { "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "1" } },
            { "metadata" => { "namespace" => "default", "name" => "b", "resourceVersion" => "2" } }
          ], "2"
        ))
      )
      # The watch stream is closed immediately; the informer falls back to its
      # reconnect loop. The List above is what populates and syncs the store.
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      allow(fake_watch).to receive(:connect) { raise StandardError, "watch stream closed" }

      informer = cache.register(gvk: gvk)
      cache.start
      cache.wait_for_sync(timeout: 5)
      expect(informer.synced).to be true

      expect(cache.get(gvk, "default", "a")).to be_a(Hash)
      expect(cache.list(gvk).map { |o| o.dig("metadata", "name") }.sort).to eq(%w[a b])
    ensure
      cache.stop
    end
  end
end
