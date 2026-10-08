# frozen_string_literal: true

RSpec.describe KrubyController::Cache::SharedCache do
  def informers_of(cache)
    cache.instance_variable_get(:@informers)
  end

  describe "#wait_for_sync" do
    it "returns true immediately when there are no informers" do
      expect(described_class.new.wait_for_sync(timeout: 1)).to be(true)
    end

    it "raises the informer's sync error when one exhausts its initial-List retries" do
      cache = described_class.new
      err = KrubyController::Error.new("Informer list failed for g/v (HTTP 403): Forbidden")
      informers_of(cache)["g/v, Kind=Bad"] = double("informer", synced: false, sync_error: err)

      expect { cache.wait_for_sync(timeout: 1) }.to raise_error(KrubyController::Error, /403/)
    end

    it "returns false when an informer does not sync within the timeout" do
      cache = described_class.new
      informers_of(cache)["g/v, Kind=Stuck"] = double("informer", synced: false, sync_error: nil)

      expect(cache.wait_for_sync(timeout: 0.3)).to be(false)
    end
  end
end
