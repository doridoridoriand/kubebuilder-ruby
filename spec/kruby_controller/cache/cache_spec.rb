# frozen_string_literal: true

RSpec.describe KrubyController::Cache::SharedCache do
  def informers_of(cache)
    cache.instance_variable_get(:@informers)
  end

  describe "#wait_for_sync" do
    it "returns true immediately when there are no informers" do
      cache = described_class.new

      expect(cache.wait_for_sync(timeout: 1)).to be(true)
    end

    it "returns true once every informer is synced" do
      cache = described_class.new
      slow = double("informer")
      allow(slow).to receive(:synced).and_return(false, false, true)
      informers_of(cache)["g/v, Kind=Slow"] = slow
      informers_of(cache)["g/v, Kind=Fast"] = double("informer", synced: true)

      expect(cache.wait_for_sync(timeout: 2)).to be(true)
    end

    it "returns false when an informer does not sync within the timeout" do
      cache = described_class.new
      informers_of(cache)["g/v, Kind=Stuck"] = double("informer", synced: false)

      expect(cache.wait_for_sync(timeout: 0.3)).to be(false)
    end
  end
end
