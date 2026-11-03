# frozen_string_literal: true

RSpec.describe KrubyController::Cache::SharedCache do
  def informers_of(cache)
    cache.instance_variable_get(:@informers)
  end

  describe "#wait_for_sync" do
    it "returns true immediately when there are no informers" do
      expect(described_class.new.wait_for_sync(timeout: 1)).to be(true)
    end

    it "returns true once every informer is synced" do
      cache = described_class.new
      slow = double("informer", sync_error: nil)
      allow(slow).to receive(:synced).and_return(false, false, true)
      informers_of(cache)["g/v, Kind=Slow"] = slow
      informers_of(cache)["g/v, Kind=Fast"] = double("informer", synced: true, sync_error: nil)

      expect(cache.wait_for_sync(timeout: 2)).to be(true)
    end

    it "returns false when an informer does not sync within the timeout" do
      cache = described_class.new
      informers_of(cache)["g/v, Kind=Stuck"] = double("informer", synced: false, sync_error: nil)

      expect(cache.wait_for_sync(timeout: 0.3)).to be(false)
    end

    it "raises the informer's sync error when one exhausts its initial-List retries" do
      cache = described_class.new
      err = KrubyController::Error.new("Informer list failed for g/v (HTTP 403): Forbidden")
      informers_of(cache)["g/v, Kind=Bad"] = double("informer", synced: false, sync_error: err)

      expect { cache.wait_for_sync(timeout: 1) }.to raise_error(KrubyController::Error, /403/)
    end
  end

  describe "object ownership (deep copy, #46)" do
    let(:gvk) do
      KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
    end
    let(:cache) do
      cache = described_class.new
      # register builds an informer with an api_client; stub it so no real
      # kubeconfig is needed (the copy contract never touches the network).
      allow(cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
      cache
    end
    let(:rich_obj) do
      {
        "metadata" => { "namespace" => "default", "name" => "rich", "labels" => { "app" => "cron" } },
        "spec" => { "steps" => [{ "name" => "one" }] },
        "status" => { "notes" => "original" }
      }
    end

    before do
      store = cache.register(gvk: gvk).store
      store.add(KrubyController::Cache::Delta::ADDED, rich_obj)
    end

    it "get returns an independent copy: a reconciler mutation before an API update never rewrites the cache" do
      obj = cache.get(gvk, "default", "rich")
      obj["status"]["notes"] = "pre-update-mutation"
      obj["spec"]["steps"].clear

      expect(cache.get(gvk, "default", "rich").dig("status", "notes")).to eq("original")
      expect(cache.get(gvk, "default", "rich").dig("spec", "steps").size).to eq(1)
    end

    it "list returns independent copies" do
      objs = cache.list(gvk)
      objs.each { |o| o["status"]["notes"] = "mutated" }

      expect(cache.list(gvk).first.dig("status", "notes")).to eq("original")
    end

    it "copy: false returns the store-owned object" do
      raw = cache.get(gvk, "default", "rich", copy: false)
      expect(raw).to equal(cache.get(gvk, "default", "rich", copy: false))
    end
  end
end
