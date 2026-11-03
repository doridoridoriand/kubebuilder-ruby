# frozen_string_literal: true

RSpec.describe KrubyController::Cache::WatchStream do
  # A Typhoeus-shaped request fake: records callbacks and streams the
  # configured chunks during run.
  class WatchStreamSpecRequest
    attr_reader :options

    def initialize(response, chunks)
      @response = response
      @chunks = chunks
      @options = {}
    end

    def on_headers(&block)
      @on_headers = block
    end

    def on_body(&block)
      @on_body = block
    end

    def run
      code = @response.respond_to?(:code) ? @response.code : nil
      @on_headers&.call(Struct.new(:code).new(code))
      @chunks.each { |chunk| @on_body&.call(chunk) }
      @response
    end
  end

  let(:api_client) { double("api client") }
  let(:stream) { described_class.new(api_client) }
  let(:events) { [] }

  def stub_request!(response, chunks)
    request = WatchStreamSpecRequest.new(response, chunks)
    allow(api_client).to receive(:build_request).and_return(request)
    request
  end

  def ok_response(code: 200)
    double("response", code: code, success?: true, headers: nil, body: "")
  end

  def run!(chunks, response: ok_response)
    request = stub_request!(response, chunks)
    stream.connect("/apis/g/v/crontasks?watch=true&resourceVersion=1") { |event| events << event }
    request
  end

  it "yields an event split across chunk boundaries" do
    run!([
           '{"type":"ADDED","object":{"metadata":{"na',
           'me":"a","resourceVersion":"1"}}}' \
           "\n"
         ])

    expect(events.size).to eq(1)
    expect(events.first.dig("object", "metadata", "name")).to eq("a")
    expect(events.first.dig("object", "metadata", "resourceVersion")).to eq("1")
  end

  it "yields multiple events and processes an unterminated trailing line" do
    run!([
           '{"type":"ADDED","object":{"metadata":{"name":"a"}}}' "\n",
           '{"type":"MODIFIED","object":{"metadata":{"name":"b"}}}' "\n" \
           '{"type":"DELETED","object":{"metadata":{"name":"c"}}}'
         ])

    expect(events.map { |e| e["type"] }).to eq(%w[ADDED MODIFIED DELETED])
  end

  it "skips malformed lines, blank lines and non-object JSON" do
    run!([
           "not json\n",
           "\n",
           '"bare string"' "\n",
           '{"type":"ADDED","object":{"metadata":{"name":"a"}}}' "\n"
         ])

    expect(events.size).to eq(1)
    expect(events.first.dig("object", "metadata", "name")).to eq("a")
  end

  it "returns normally on a clean server-side close" do
    expect { run!([]) }.not_to raise_error
    expect(events).to be_empty
  end

  it "yields ERROR events to the handler for classification" do
    run!([
           '{"type":"ERROR","object":{"code":410,"reason":"Expired"}}' "\n",
           '{"type":"ERROR","object":{"code":500}}' "\n"
         ])

    expect(events.map { |e| e.dig("object", "code") }).to eq([410, 500])
  end

  it "surfaces a classified error raised inside the event handler after the transfer completes" do
    chunks = [
      '{"type":"ADDED","object":{"metadata":{"name":"a"}}}' "\n",
      '{"type":"ERROR","object":{"code":410}}' "\n",
      '{"type":"ADDED","object":{"metadata":{"name":"never"}}}' "\n"
    ]
    stub_request!(ok_response, chunks)

    expect do
      stream.connect("/watch") do |event|
        raise KrubyController::Cache::WatchStream::Gone.new("gone", code: 410) if event["type"] == "ERROR"

        events << event
      end
    end.to raise_error(described_class::Gone)

    # events before the error are delivered; parsing stops after it
    expect(events.map { |e| e.dig("object", "metadata", "name") }).to eq(["a"])
  end
  it "raises Error with Retry-After for a 429 response" do
    response = double(
      "response",
      code: 429,
      success?: false,
      headers: { "Retry-After" => "5" },
      body: '{"kind":"Status","code":429}',
      status_message: "Too Many Requests"
    )
    request = stub_request!(response, [""])

    expect { stream.connect("/watch") { |e| events << e } }
      .to raise_error(described_class::Error) do |e|
        expect(e.code).to eq(429)
        expect(e.retry_after).to eq(5.0)
      end

    # the non-200 body is never parsed as an event
    expect(events).to be_empty
  end

  it "raises Error without Retry-After for other failed responses" do
    response = double("response", code: 500, success?: false, headers: nil, body: "", status_message: "boom")

    expect { run!([], response: response) }
      .to raise_error(described_class::Error) { |e| expect(e.retry_after).to be_nil }
  end

  it "raises Gone for an HTTP 410 response (not only a streamed ERROR event)" do
    response = double("response", code: 410, success?: false, headers: nil, body: "", status_message: "Gone")

    expect { run!([], response: response) }.to raise_error(described_class::Gone) { |e| expect(e.code).to eq(410) }
  end

  it "disables the idle timeout so an idle stream is not killed mid-poll" do
    request = run!([])

    expect(request.options[:timeout]).to eq(described_class::WATCH_IDLE_TIMEOUT)
  end

  it "surfaces a classified error raised inside the event handler after the transfer completes" do
    chunks = [
      '{"type":"ADDED","object":{"metadata":{"name":"a"}}}' "\n",
      '{"type":"ERROR","object":{"code":410}}' "\n",
      '{"type":"ADDED","object":{"metadata":{"name":"never"}}}' "\n"
    ]
    stub_request!(ok_response, chunks)

    expect do
      stream.connect("/watch") do |event|
        raise KrubyController::Cache::WatchStream::Gone.new("gone", code: 410) if event["type"] == "ERROR"

        events << event
      end
    end.to raise_error(described_class::Gone)

    # events before the error are delivered; parsing stops after it
    expect(events.map { |e| e.dig("object", "metadata", "name") }).to eq(["a"])
  end

  it "collects all events when the handler never raises" do
    chunks = [
      '{"type":"ADDED","object":{"metadata":{"name":"a"}}}' "\n",
      '{"type":"ADDED","object":{"metadata":{"name":"never"}}}' "\n"
    ]
    run!(chunks)

    expect(events.map { |e| e.dig("object", "metadata", "name") }).to eq(%w[a never])
  end
end
