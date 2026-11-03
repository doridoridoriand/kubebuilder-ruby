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

    it "rejects scheduling while the queue is closed" do
      queue.shutdown(1)

      expect(queue.add_after(req_a, 0.05)).to be(false)
      # Only the shutdown sentinel is present; req_a was not scheduled.
      expect(queue.get).to equal(KrubyController::Queue::WorkQueue::SENTINEL)
      expect(queue.len).to eq(0)
    end

    it "discards a pending delayed retry after shutdown + reset (no stale work)" do
      queue.add_after(req_a, 0.1)
      queue.shutdown(1)
      queue.reset

      # Let the (now invalidated) timer fire; it must not enqueue stale work.
      sleep 0.25
      expect(queue.len).to eq(0)
    end
  end

  describe "#add_rate_limited / #forget" do
    def wait_until_len(work_queue, count, timeout: 2)
      deadline = Time.now + timeout
      sleep 0.01 while work_queue.len < count && Time.now < deadline
    end

    it "raises when the queue has no rate limiter" do
      expect { queue.add_rate_limited(req_a) }.to raise_error(ArgumentError, /rate_limiter/)
    end

    it "does not record a backoff or schedule when the queue is closed" do
      limiter = KrubyController::Queue::ExponentialBackoffRateLimiter.new(base: 0.05, max: 1)
      q = described_class.new(rate_limiter: limiter)
      q.shutdown(1)

      q.add_rate_limited(req_a)

      expect(limiter.failures("default/a")).to eq(0)
      sleep 0.1
      # Only the shutdown sentinel is present; no rate-limited work was scheduled.
      expect(q.get).to equal(KrubyController::Queue::WorkQueue::SENTINEL)
      expect(q.len).to eq(0)
    end

    it "enqueues after the limiter's delay" do
      limiter = KrubyController::Queue::ExponentialBackoffRateLimiter.new(base: 0.05, max: 1)
      q = described_class.new(rate_limiter: limiter)
      q.add_rate_limited(req_a)

      wait_until_len(q, 1)
      expect(q.get).to eq(req_a)
      expect(limiter.failures("default/a")).to eq(1)
    end

    it "increases the delay for repeated failures of the same key" do
      limiter = KrubyController::Queue::ExponentialBackoffRateLimiter.new(base: 0.02, max: 1)
      q = described_class.new(rate_limiter: limiter)

      q.add_rate_limited(req_a)
      wait_until_len(q, 1)
      first = q.get
      q.done(first)

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      q.add_rate_limited(req_a) # second failure -> 2 * base
      wait_until_len(q, 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(elapsed).to be >= 0.03
      second = q.get
      expect(second).to eq(req_a)
    end

    it "forget clears the limiter state for the key" do
      limiter = KrubyController::Queue::ExponentialBackoffRateLimiter.new(base: 1, max: 100)
      q = described_class.new(rate_limiter: limiter)
      limiter.backoff("default/a")

      q.forget(req_a)

      expect(limiter.failures("default/a")).to eq(0)
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

  describe "shared scheduler (#47)" do
    def req(name)
      KrubyController::Request.new(namespace: "default", name: name)
    end

    def wait_for_len(work_queue, count, timeout: 5)
      deadline = Time.now + timeout
      sleep 0.02 while work_queue.len < count && Time.now < deadline
      work_queue.len
    end

    it "processes mass delayed retries with a bounded number of threads" do
      q = described_class.new
      baseline = Thread.list.size
      200.times { |i| q.add_after(req("m-#{i}"), 0.3) }

      # While all 200 deadlines are pending, only the shared scheduler thread
      # may exist: the per-request implementation would have ~200 sleeping
      # threads alive here.
      sleep 0.1
      expect(Thread.list.size - baseline).to be <= 3
    ensure
      q&.shutdown(1)
    end

    it "fires delayed retries in deadline order" do
      q = described_class.new
      q.add_after(req("c"), 0.15)
      q.add_after(req("a"), 0.02)
      q.add_after(req("b"), 0.08)

      expect(wait_for_len(q, 3)).to eq(3)

      popped = 3.times.map { q.get.namespaced_name.to_s }
      expect(popped).to eq(%w[default/a default/b default/c])
    ensure
      q&.shutdown(1)
    end

    it "dedupes a delayed fire against an immediate add for the same key" do
      q = described_class.new
      q.add_after(req_a, 0.05)
      q.add(req_a) # immediate add wins: the key is pending right away

      expect(q.len).to eq(1)

      in_flight = q.get
      sleep 0.15 # the delayed fire happens while the key is in flight
      q.done(in_flight)

      expect(q.len).to eq(1) # the fire was deduped (dirty), not a second copy
      expect(q.get).to eq(req_a)
    ensure
      q&.shutdown(1)
    end

    it "collapses two delayed retries of the same key into one enqueue" do
      q = described_class.new
      expect(q.add_after(req_a, 0.02)).to be(true)
      expect(q.add_after(req_a, 0.08)).to be(false) # superseded: the earliest deadline wins

      expect(wait_for_len(q, 1, timeout: 2)).to eq(1)
      first = q.get
      sleep 0.15 # well past the superseded 0.08 deadline: no second fire
      q.done(first)

      expect(q.len).to eq(0) # exactly one enqueue, no second copy
    ensure
      q&.shutdown(1)
    end

    it "never enqueues a second copy when the earlier retry completes before the later deadline" do
      q = described_class.new
      q.add_after(req_a, 0.02)
      q.add_after(req_a, 0.20) # far later: superseded at registration

      expect(wait_for_len(q, 1, timeout: 2)).to eq(1)
      first = q.get
      q.done(first) # the earlier attempt completes long before 0.20
      sleep 0.3

      expect(q.len).to eq(0) # the superseded registration never fires
    ensure
      q&.shutdown(1)
    end

    it "keeps the pending entry with the earliest deadline when replacing a later one" do
      q = described_class.new
      q.add_after(req_a, 0.10)
      q.add_after(req_a, 0.02) # earlier: replaces the 0.10 entry

      delayed = q.instance_variable_get(:@delayed)
      expect(delayed.size).to eq(1)
      # fire it and confirm only one enqueue happens
      expect(wait_for_len(q, 1, timeout: 2)).to eq(1)
      expect(q.get).to eq(req_a)
    ensure
      q&.shutdown(1)
    end

    it "records the dirty flag (not a duplicate) when a delayed fire hits an in-flight key" do
      q = described_class.new
      q.add(req_a)
      in_flight = q.get
      q.add_after(req_a, 0.02)

      sleep 0.1 # the fire happens while the key is in flight

      expect(q.len).to eq(0)
      q.done(in_flight)
      expect(q.len).to eq(1) # dirty -> re-queued exactly once
      expect(q.get).to eq(req_a)
    ensure
      q&.shutdown(1)
    end

    it "invalidates pre-shutdown entries and restarts the scheduler after reset" do
      q = described_class.new
      q.add_after(req_a, 0.05)
      q.shutdown(1)
      q.reset

      sleep 0.2
      expect(q.len).to eq(0) # the pre-shutdown entry never enqueues

      q.add_after(req_b, 0.05) # a fresh scheduler is started lazily
      expect(wait_for_len(q, 1)).to eq(1)
      expect(q.get).to eq(req_b)
    ensure
      q&.shutdown(1)
    end

    it "frees the shared scheduler thread on shutdown" do
      q = described_class.new
      q.add_after(req_a, 0.3)
      thread = q.instance_variable_get(:@scheduler)&.thread
      expect(thread).not_to be_nil

      q.shutdown(1)
      deadline = Time.now + 2
      sleep 0.02 while thread.alive? && Time.now < deadline

      expect(thread.alive?).to be(false)
      # Only the shutdown sentinel remains: the purged entry did not enqueue.
      expect(q.get).to equal(KrubyController::Queue::WorkQueue::SENTINEL)
      expect(q.len).to eq(0)
    end

    it "converges a mass-retry burst and frees the scheduler on stop" do
      q = described_class.new
      300.times { |i| q.add_after(req("b-#{i}"), 0.02) }

      expect(wait_for_len(q, 300)).to eq(300)

      thread = q.instance_variable_get(:@scheduler)&.thread
      expect(thread).not_to be_nil

      q.shutdown(1)
      deadline = Time.now + 2
      sleep 0.02 while thread.alive? && Time.now < deadline
      expect(thread.alive?).to be(false)
    end

    it "survives concurrent add_after calls without duplication" do
      q = described_class.new
      50.times.map do |i|
        Thread.new { q.add_after(req("p-#{i}"), 0.03) }
      end.each(&:join)

      expect(wait_for_len(q, 50)).to eq(50)

      q.shutdown(1)
    end

    it "never leaves a live scheduler on a closed queue when scheduling races shutdown" do
      40.times do
        q = described_class.new
        racers = 6.times.map do
          Thread.new do
            10.times { |i| q.add_after(req("r-#{i}"), 0.001 + (rand * 0.01)) }
          end
        end
        closer = Thread.new do
          sleep 0.002
          q.shutdown(1)
        end

        closer.join
        racers.each(&:join)

        handle = q.instance_variable_get(:@scheduler)
        expect(handle.nil? || !handle.thread.alive?).to be(true)
      end
    end

    it "retires and rejoins the scheduler when reset reopens a live queue" do
      q = described_class.new
      q.add_after(req_a, 0.3)
      thread = q.instance_variable_get(:@scheduler)&.thread
      expect(thread).not_to be_nil

      q.reset # reset on a LIVE queue (no prior shutdown)

      deadline = Time.now + 2
      sleep 0.02 while thread.alive? && Time.now < deadline
      expect(thread.alive?).to be(false)
      expect(q.len).to eq(0) # the purged entry never fired

      q.add_after(req_b, 0.05)
      expect(wait_for_len(q, 1)).to eq(1)
      expect(q.get).to eq(req_b)
    ensure
      q&.shutdown(1)
    end
  end
end
