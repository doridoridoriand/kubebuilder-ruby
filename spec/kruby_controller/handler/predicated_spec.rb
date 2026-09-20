# frozen_string_literal: true

RSpec.describe KrubyController::Handler::Predicated do
  let(:queue) { KrubyController::Queue::WorkQueue.new }
  let(:base) { KrubyController::Handler::EnqueuedObject.new(queue: queue) }
  let(:obj) { { "metadata" => { "namespace" => "default", "name" => "a", "labels" => { "managed-by" => "cron" } } } }
  let(:other) { { "metadata" => { "namespace" => "default", "name" => "b" } } }

  class RecordingHandler
    attr_reader :captured

    def initialize
      @captured = []
    end

    def handle(delta_type, obj)
      @captured << [delta_type, obj]
    end
  end

  it "forwards events the predicate accepts" do
    handler = described_class.new(handler: base, predicate: ->(o) { o.dig("metadata", "labels", "managed-by") == "cron" })

    handler.handle(KrubyController::Cache::Delta::ADDED, obj)
    expect(queue.len).to eq(1)
    expect(queue.get).to eq(KrubyController::Request.new(namespace: "default", name: "a"))
  end

  it "swallows events the predicate rejects" do
    handler = described_class.new(handler: base, predicate: ->(o) { o.dig("metadata", "labels", "managed-by") == "cron" })

    handler.handle(KrubyController::Cache::Delta::ADDED, other)
    expect(queue.len).to eq(0)
  end

  it "passes delta_type through to the wrapped handler" do
    spy = RecordingHandler.new
    handler = described_class.new(handler: spy, predicate: ->(_) { true })

    handler.handle(KrubyController::Cache::Delta::DELETED, obj)
    expect(spy.captured).to eq([[KrubyController::Cache::Delta::DELETED, obj]])
  end
end
