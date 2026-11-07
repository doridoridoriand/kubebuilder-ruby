# frozen_string_literal: true

RSpec.describe KrubyController::Cache::RequestError do
  def response_with(headers)
    double("response", code: 429, headers: headers, status_message: "Too Many Requests")
  end

  describe ".parse_retry_after" do
    it "parses a numeric delta-seconds value" do
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => "30" }))).to eq(30.0)
    end

    it "parses a fractional value" do
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => "0.5" }))).to eq(0.5)
    end

    it "ignores a non-positive numeric value" do
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => "0" }))).to be_nil
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => "-3" }))).to be_nil
    end

    it "converts a future HTTP-date to the remaining delay" do
      future = (Time.now + 45).utc.strftime("%a, %d %b %Y %H:%M:%S GMT")
      delay = described_class.parse_retry_after(response_with({ "Retry-After" => future }))

      expect(delay).to be_between(40.0, 46.0)
    end

    it "discards a past HTTP-date" do
      past = (Time.now - 60).utc.strftime("%a, %d %b %Y %H:%M:%S GMT")
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => past }))).to be_nil
    end

    it "discards an invalid value" do
      expect(described_class.parse_retry_after(response_with({ "Retry-After" => "not-a-number-or-date" }))).to be_nil
    end

    it "handles lowercase header names" do
      expect(described_class.parse_retry_after(response_with({ "retry-after" => "12" }))).to eq(12.0)
    end

    it "returns nil when there are no headers or no key" do
      expect(described_class.parse_retry_after(double("response", code: 503, headers: nil, status_message: "x"))).to be_nil
      expect(described_class.parse_retry_after(response_with({}))).to be_nil
    end
  end

  describe ".from_response" do
    it "carries the code and a numeric Retry-After" do
      error = described_class.from_response("Watch failed", response_with({ "Retry-After" => "17" }))

      expect(error.code).to eq(429)
      expect(error.retry_after).to eq(17.0)
      expect(error.message).to include("429")
    end
  end
end
