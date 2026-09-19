# frozen_string_literal: true

RSpec.describe KrubyController do
  it "has a version number" do
    expect(KrubyController::VERSION).not_to be_nil
  end

  describe KrubyController::Request do
    it "compares equal with same namespace/name" do
      r1 = KrubyController::Request.new(namespace: "default", name: "foo")
      r2 = KrubyController::Request.new(namespace: "default", name: "foo")
      expect(r1).to eq(r2)
    end

    it "compares unequal with different namespace" do
      r1 = KrubyController::Request.new(namespace: "default", name: "foo")
      r2 = KrubyController::Request.new(namespace: "kube-system", name: "foo")
      expect(r1).not_to eq(r2)
    end
  end

  describe KrubyController::Result do
    it "creates Ok result" do
      expect(KrubyController::Result.ok).to be_a(KrubyController::Result::Ok)
    end

    it "creates RetryAfter result" do
      result = KrubyController::Result.retry_after(30)
      expect(result).to be_a(KrubyController::Result::RetryAfter)
      expect(result.after).to eq(30)
    end

    it "creates Requeue result" do
      expect(KrubyController::Result.requeue).to be_a(KrubyController::Result::Requeue)
    end

    it "rejects zero retry_after" do
      expect { KrubyController::Result.retry_after(0) }.to raise_error(ArgumentError)
    end
  end

  describe KrubyController::Reconciler do
    it "raises NotImplementedError when reconcile is not implemented" do
      reconciler = KrubyController::Reconciler.new
      request = KrubyController::Request.new(namespace: "default", name: "test")
      expect { reconciler.reconcile(request) }.to raise_error(NotImplementedError)
    end
  end

  describe "Queue::WorkQueue" do
    it "adds and gets requests" do
      queue = KrubyController::Queue::WorkQueue.new
      request = KrubyController::Request.new(namespace: "default", name: "foo")
      queue.add(request)
      expect(queue.get).to eq(request)
    end

    it "deduplicates requests" do
      queue = KrubyController::Queue::WorkQueue.new
      request = KrubyController::Request.new(namespace: "default", name: "foo")
      queue.add(request)
      queue.add(request)
      queue.get
      expect(queue.len).to eq(0)
    end

    it "re-enqueues after done" do
      queue = KrubyController::Queue::WorkQueue.new
      request = KrubyController::Request.new(namespace: "default", name: "foo")
      queue.add(request)
      queue.get
      queue.done(request)
      queue.add(request)
      expect(queue.get).to eq(request)
    end

    it "ignores adds after shutdown and accepts them again after reset" do
      queue = KrubyController::Queue::WorkQueue.new
      request = KrubyController::Request.new(namespace: "default", name: "foo")
      queue.shutdown(1)
      queue.get # consume the sentinel

      queue.add(request)
      expect(queue.len).to eq(0)

      queue.reset
      queue.add(request)
      expect(queue.get).to eq(request)
    end

    it "preserves pending requests and drains leftover sentinels on reset" do
      queue = KrubyController::Queue::WorkQueue.new
      request = KrubyController::Request.new(namespace: "default", name: "foo")
      queue.add(request)
      queue.shutdown(1) # a worker that exits mid-cycle leaves the sentinel in the queue

      queue.reset

      expect(queue.get).to eq(request)
    end
  end
end
