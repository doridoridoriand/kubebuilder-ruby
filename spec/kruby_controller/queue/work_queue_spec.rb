# frozen_string_literal: true

RSpec.describe KrubyController::Queue::WorkQueue do
  let(:queue) { described_class.new }
  let(:req_a) { KrubyController::Request.new(namespace: "default", name: "a") }
  let(:req_b) { KrubyController::Request.new(namespace: "default", name: "b") }

  def drain
    1.upto(queue.len).map { queue.get }
  end

  describe "#add / #get / #done" do
    it "enqueues and returns the request" do
      queue.add(req_a)
      expect(queue.get).to eq(req_a)
    end

    it "dedupes while the key is waiting in the queue" do
      queue.add(req_a)
      queue.add(req_a)

      expect(queue.len).to eq(1)
      expect(queue.get).to eq(req_a)
    end
  end

  describe "in-flight dirty flag" do
    it "re-enqueues a key that was re-added while in flight" do
      queue.add(req_a)
      in_flight = queue.get
      queue.add(req_a) # dropped into the dirty set, not the queue

      expect(queue.len).to eq(0)

      queue.done(in_flight)
      expect(queue.len).to eq(1)
      requeued = queue.get # a fresh copy, not the in-flight object
      expect(requeued).to eq(req_a)
      queue.done(requeued)
      expect(queue.len).to eq(0)
    end

    it "does not re-enqueue a key with no in-flight re-add" do
      queue.add(req_a)
      in_flight = queue.get
      queue.done(in_flight)

      expect(queue.len).to eq(0)
    end

    it "keeps dedupe while the re-enqueued (dirty) request waits" do
      queue.add(req_a)
      in_flight = queue.get
      queue.add(req_a)
      queue.done(in_flight) # re-queued, key still @known

      queue.add(req_a) # waiting in queue -> deduped again
      expect(queue.len).to eq(1)
    end

    it "ignores a duplicate done for a key that is no longer in flight (idempotent)" do
      queue.add(req_a)
      in_flight = queue.get
      queue.add(req_a) # in flight -> dirty
      queue.done(in_flight) # re-queued as a fresh copy, in_flight no longer in flight

      queue.done(in_flight) # duplicate done: not the in-flight object -> ignored

      # re-add must still dedupe (key is pending), not create a duplicate
      queue.add(req_a)
      expect(queue.len).to eq(1)
      requeued = queue.get
      expect(requeued).to eq(req_a)
      queue.done(requeued)
      expect(queue.len).to eq(0)
    end

    it "ignores a stale done for an older copy after the key was re-queued to another worker" do
      queue.add(req_a)
      copy1 = queue.get
      queue.add(req_a) # in flight -> dirty
      queue.done(copy1) # re-queued with a fresh copy
      copy2 = queue.get # a (second) worker now owns the key
      queue.done(copy1) # stale completion for the old copy

      # copy2 must still be in flight: an event for the key is recorded as
      # dirty, not enqueued as a second copy
      queue.add(req_a)
      expect(queue.len).to eq(0)

      queue.done(copy2) # dirty -> re-queued exactly once
      expect(queue.len).to eq(1)
    end

    it "does not lose a distinct key added while another key is in flight" do
      queue.add(req_a)
      queue.get
      queue.add(req_b)

      expect(drain.map(&:namespaced_name)).to match_array([req_b.namespaced_name])
    end

    it "survives a full reconcile cycle of add-while-processing repeated" do
      queue.add(req_a)
      processed = 0
      3.times do
        item = queue.get
        processed += 1
        queue.add(req_a) # simulate a child event during reconcile
        queue.done(item)
      end
      # Each done re-queued (dirty), plus the initial add: 1 in flight + 1 queued
      queue.add(req_a) # in flight? no: after last done it was re-queued and NOT in flight
      expect(processed).to eq(3)
      expect(queue.len).to eq(1)
    end
  end

  describe "#add_after" do
    it "enqueues after the delay" do
      queue.add_after(req_a, 0.05)

      deadline = Time.now + 2
      sleep 0.02 while queue.len.zero? && Time.now < deadline

      expect(queue.get).to eq(req_a)
    end
  end

  describe "#shutdown / #reset" do
    it "stops accepting and unblocks workers with sentinels" do
      queue.shutdown(1)

      expect { queue.get }.to_not raise_error
      expect(queue.shutdown?).to be true
    end

    it "reset reopens and keeps pending requests" do
      queue.add(req_a)
      queue.add(req_b)
      queue.get # req_a goes in flight; req_b stays pending
      queue.shutdown(1)
      queue.reset

      expect(queue.shutdown?).to be false
      expect(queue.get).to eq(req_b)
      queue.done(req_b)
      expect(queue.len).to eq(0)
    end
  end
end
