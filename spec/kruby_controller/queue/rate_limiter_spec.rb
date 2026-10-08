# frozen_string_literal: true

RSpec.describe KrubyController::Queue::ExponentialBackoffRateLimiter do
  describe "#backoff" do
    it "doubles the delay per consecutive failure, starting at base" do
      limiter = described_class.new(base: 1, max: 100)
      expect(limiter.backoff("k")).to eq(1)
      expect(limiter.backoff("k")).to eq(2)
      expect(limiter.backoff("k")).to eq(4)
      expect(limiter.backoff("k")).to eq(8)
    end

    it "caps the delay at max" do
      limiter = described_class.new(base: 1, max: 3)
      expect(limiter.backoff("k")).to eq(1)
      expect(limiter.backoff("k")).to eq(2)
      expect(limiter.backoff("k")).to eq(3)
      expect(limiter.backoff("k")).to eq(3)
    end

    it "tracks keys independently" do
      limiter = described_class.new(base: 1, max: 100)
      expect(limiter.backoff("a")).to eq(1)
      expect(limiter.backoff("b")).to eq(1)
      expect(limiter.backoff("a")).to eq(2)
      expect(limiter.failures("b")).to eq(1)
    end

    it "defaults to a 5s base / 300s cap per issue #8" do
      limiter = described_class.new
      expect(limiter.base).to eq(5.0)
      expect(limiter.max).to eq(300.0)
    end

    it "rejects non-positive base or max" do
      expect { described_class.new(base: 0) }.to raise_error(ArgumentError, /base/)
      expect { described_class.new(max: 0) }.to raise_error(ArgumentError, /max/)
    end
  end

  describe "#forget" do
    it "resets the failure count for the key" do
      limiter = described_class.new(base: 1, max: 100)
      3.times { limiter.backoff("k") }
      expect(limiter.failures("k")).to eq(3)

      limiter.forget("k")

      expect(limiter.failures("k")).to eq(0)
      expect(limiter.backoff("k")).to eq(1)
    end

    it "leaves other keys untouched" do
      limiter = described_class.new(base: 1, max: 100)
      limiter.backoff("a")
      limiter.backoff("b")
      limiter.forget("a")

      expect(limiter.failures("b")).to eq(1)
    end
  end

  it "is safe under concurrent backoff calls" do
    limiter = described_class.new(base: 1, max: 10_000)
    threads = 8.times.map { Thread.new { 50.times { limiter.backoff("k") } } }
    threads.each(&:join)

    expect(limiter.failures("k")).to eq(400)
  end
end
