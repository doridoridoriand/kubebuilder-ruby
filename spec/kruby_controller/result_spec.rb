# frozen_string_literal: true

RSpec.describe KrubyController::Result do
  describe ".ok" do
    it "returns an Ok result" do
      expect(described_class.ok).to be_a(described_class::Ok)
    end

    it "carries an optional error" do
      error = StandardError.new("boom")
      expect(described_class.ok(error:).error).to be(error)
    end
  end

  describe ".retry_after" do
    it "returns a RetryAfter result with the delay" do
      result = described_class.retry_after(30)

      expect(result).to be_a(described_class::RetryAfter)
      expect(result.after).to eq(30)
    end

    it "carries an optional error" do
      error = StandardError.new("slow")
      expect(described_class.retry_after(5, error:).error).to be(error)
    end

    it "raises when the delay is not positive" do
      expect { described_class.retry_after(0) }.to raise_error(ArgumentError, /positive/)
      expect { described_class.retry_after(-1) }.to raise_error(ArgumentError, /positive/)
    end
  end

  describe ".requeue" do
    it "returns a Requeue result" do
      expect(described_class.requeue).to be_a(described_class::Requeue)
    end
  end

  describe "class-level factories" do
    it "Ok.ok builds an Ok" do
      expect(described_class::Ok.ok).to be_a(described_class::Ok)
    end

    it "RetryAfter.retry_after builds a RetryAfter" do
      expect(described_class::RetryAfter.retry_after(7).after).to eq(7)
    end

    it "Requeue.requeue builds a Requeue" do
      expect(described_class::Requeue.requeue).to be_a(described_class::Requeue)
    end
  end

  describe "type discrimination" do
    it "keeps the result types distinct" do
      expect(described_class.ok).not_to be_a(described_class::Requeue)
      expect(described_class.requeue).not_to be_a(described_class::RetryAfter)
    end
  end
end
