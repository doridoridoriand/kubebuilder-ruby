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
      expect(informer).to receive(:start)

      cache.start
    end

    it "stop delegates to every informer" do
      informer = cache.register(gvk: gvk)
      expect(informer).to receive(:stop)

      cache.stop
    end

    it "wait_for_sync delegates to every informer" do
      informer = cache.register(gvk: gvk)
      expect(informer).to receive(:wait_for_sync).with(timeout: 30)

      cache.wait_for_sync
    end
  end
end
