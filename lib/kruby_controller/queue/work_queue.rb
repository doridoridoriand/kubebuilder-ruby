# frozen_string_literal: true

module KrubyController
  module Queue
    # Deduplicating work queue with an in-flight dirty flag
    # (controller-runtime semantics).
    #
    # All state access is guarded by a single mutex (a condition variable
    # provides the blocking `get`), so the dequeue and the pending ->
    # in-flight transition happen atomically: there is no window in which a
    # key is visible as neither pending nor in flight and an informer event
    # can be silently deduped against a stale state.
    #
    # A key is "present" while it is pending (`@pending_keys`) or in flight
    # (`@in_flight`). `add` is a no-op for a key that is already present,
    # except when the key is in flight: then it is recorded in `@dirty`
    # instead of enqueued. When the worker calls `done`, a dirty key is
    # re-queued so the reconciler runs once more for the latest state.
    # Without this, an event for a key that is currently being reconciled
    # would be dropped and never re-triggered.
    #
    # Completions are matched by request-object identity, not by key: a
    # requeued copy is a fresh `Request` object, so a delayed or duplicate
    # `done` for an older copy can never clear the in-flight entry of the
    # newer copy (per-dequeue identity, equivalent to a generation token).
    #
    # Delayed retries (from `add_after` / `add_rate_limited`) are managed by
    # ONE shared scheduler thread per queue instead of one sleeping thread
    # per retry (which scaled linearly with the failure volume). Ordering
    # and priority rules:
    #
    # * Entries fire strictly in deadline order (equal deadlines in
    #   scheduling order). A later deadline for a key that an earlier fire
    #   already enqueued is a dedupe no-op, never a second copy.
    # * An immediate `add` for a key with a pending delayed entry wins: the
    #   key becomes pending/in flight right away and the delayed fire is
    #   deduped when it fires. A delayed entry never preempts in-flight work.
    # * A delayed fire while its key is in flight records the dirty flag
    #   (exactly like an informer event), so the completion re-queues the
    #   key once.
    #
    # shutdown purges pending entries and stops the scheduler thread;
    # reset bumps `@retry_seq`, purges stale entries and lets the next
    # delayed retry lazily start a fresh scheduler. Each entry validates
    # against the retry lifecycle that scheduled it, so a delayed retry from
    # a previous lifecycle is discarded instead of injecting stale work
    # after Controller#start reopens the queue.
    class WorkQueue
      SENTINEL = Object.new.freeze

      # A delayed enqueue promise. Fires at +due_at+ (monotonic clock) and
      # enqueues only if the queue is still open and the retry lifecycle
      # (seq) that scheduled it is still current.
      DelayEntry = Struct.new(:due_at, :seq, :request)

      def initialize(rate_limiter: nil)
        @rate_limiter = rate_limiter
        # Thread::Queue gives us O(1) FIFO push/pop. Its operations are
        # performed while @mutex is held so that popping an item and moving
        # its key from pending to in flight remain one atomic transition.
        @queue = ::Queue.new
        @pending_keys = Set.new
        @in_flight = {}
        @dirty = Set.new
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @closed = false
        # Lifecycle counter for delayed retries. Bumped on every #reset so a
        # retry scheduled in a previous lifecycle is discarded when it fires
        # (Controller#start reopens the same queue via #reset).
        @retry_seq = 0
        # Deadline-sorted pending delayed entries; the shared scheduler
        # thread fires them oldest-deadline-first.
        @delayed = []
        @scheduler_running = false
        @scheduler_thread = nil
        @scheduler_cond = ConditionVariable.new
      end

      def add(request)
        @mutex.synchronize do
          return if @closed

          do_add(request)
        end
      end

      # Schedules +request+ to be enqueued after +seconds+. The retry is owned
      # by the shared scheduler: it is rejected while the queue is closed and
      # is discarded (not enqueued) if the queue is shut down or reset before
      # the deadline fires, so a retry from a previous lifecycle can never
      # inject stale work after Controller#start reopens the queue.
      # Returns false when the queue is already closed and nothing was
      # scheduled; true otherwise.
      def add_after(request, seconds)
        seq = @mutex.synchronize do
          return false if @closed

          @retry_seq
        end
        schedule(DelayEntry.new(monotonic_time + seconds, seq, request))
        true
      end

      # Re-queues +request+ after a delay decided by the rate limiter
      # (controller-runtime's AddRateLimited). Requires a queue built with a
      # rate_limiter. Does nothing (and records no backoff) when the queue is
      # already closed.
      def add_rate_limited(request)
        raise ArgumentError, "WorkQueue#add_rate_limited requires a rate_limiter" unless @rate_limiter

        delay, seq = @mutex.synchronize do
          return false if @closed

          [@rate_limiter.backoff(request.namespaced_name.to_s), @retry_seq]
        end
        schedule(DelayEntry.new(monotonic_time + delay, seq, request))
        true
      end

      # Shared enqueue logic; the caller must hold @mutex.
      def do_add(request)
        key = request.namespaced_name.to_s
        if @in_flight.key?(key)
          @dirty.add(key)
        elsif !@pending_keys.include?(key)
          @pending_keys.add(key)
          @queue << request
        end
        @cond.signal
      end

      # Clears the rate limiter state for +request+'s key (controller-runtime's
      # Forget); a no-op when the queue has no rate limiter.
      def forget(request)
        @rate_limiter&.forget(request.namespaced_name.to_s)
      end

      # Blocks until an item is available, atomically dequeueing it and
      # moving its key from pending to in flight.
      def get
        @mutex.synchronize do
          loop do
            if @queue.empty?
              return SENTINEL if @closed

              @cond.wait(@mutex)
              next
            end

            item = @queue.pop(true)
            return item if item.equal?(SENTINEL)

            key = item.namespaced_name.to_s
            @pending_keys.delete(key)
            @in_flight[key] = item
            return item
          end
        end
      end

      # Marks a request as completed. Only the request object that is
      # currently in flight for its key is considered; any other completion
      # (a duplicate, or a stale one for an older copy) is ignored. An in
      # flight, dirty key is re-queued with a fresh `Request` so the
      # reconciler runs once more for the latest state.
      def done(request)
        return if request.equal?(SENTINEL)

        @mutex.synchronize do
          key = request.namespaced_name.to_s
          current = @in_flight[key]
          return unless current.equal?(request)

          @in_flight.delete(key)
          if @dirty.include?(key)
            @dirty.delete(key)
            namespace, name = key.split("/", 2)
            @pending_keys.add(key)
            @queue << Request.new(namespace: namespace.to_s, name: (name || "").to_s)
            @cond.signal
          end
        end
      end

      def len
        @mutex.synchronize { @queue.length }
      end

      def shutdown(num_workers = 1)
        @mutex.synchronize do
          return if @closed

          @closed = true
          # No delayed retry survives a shutdown: purge the entries and stop
          # the shared scheduler thread (joined below, outside the lock, so
          # its resources are actually released).
          @delayed.clear
          @scheduler_running = false
          @scheduler_cond.broadcast
          # Unblock any workers blocked in get
          num_workers.times { @queue << SENTINEL }
          @cond.broadcast
        end
        thread = @mutex.synchronize { @scheduler_thread }
        thread&.join
      end

      def shutdown?
        @mutex.synchronize { @closed }
      end

      # Reopens the queue after shutdown, keeping any real pending requests
      # and discarding leftover shutdown sentinels.
      def reset
        @mutex.synchronize do
          pending = []
          loop do
            item = @queue.pop(true)
            pending << item unless item.equal?(SENTINEL)
          rescue ThreadError
            break
          end

          @queue = ::Queue.new
          pending.each { |item| @queue << item }
          @pending_keys = Set.new(pending.map { |item| item.namespaced_name.to_s })
          @in_flight = {}
          @dirty = Set.new
          @closed = false
          # Invalidate any delayed retries scheduled in the previous lifecycle
          # and drop their entries outright: every entry holds the previous
          # seq, so purging is both correct and bounded.
          @retry_seq += 1
          @delayed.clear
          @scheduler_cond.broadcast
          @cond.broadcast
        end
      end

      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Records a delayed entry and lazily starts the shared scheduler
      # thread. Held entries are kept sorted by deadline so firing walks the
      # array front-to-back in deadline order.
      def schedule(entry)
        @mutex.synchronize do
          index = @delayed.bsearch_index { |e| e.due_at > entry.due_at } || @delayed.length
          @delayed.insert(index, entry)
          start_scheduler unless @scheduler_running
          # Wake the scheduler early only if the new entry can become the
          # earliest deadline; otherwise the current wait already governs.
          @scheduler_cond.signal if @delayed.first.equal?(entry)
        end
      end

      def start_scheduler
        @scheduler_running = true
        @scheduler_thread = Thread.new { scheduler_loop }
      end

      def scheduler_loop
        loop do
          stop = false
          @mutex.synchronize do
            if !@scheduler_running
              stop = true
            elsif @delayed.empty?
              @scheduler_cond.wait(@mutex)
            else
              now = monotonic_time
              earliest = @delayed.first
              if earliest.due_at > now
                @scheduler_cond.wait(@mutex, earliest.due_at - now)
              else
                fire_due_entries(now)
              end
            end
          end
          return if stop
        end
      end

      # Fires every entry whose deadline has passed, in deadline order. A
      # fire is discarded when its retry lifecycle is stale (a queue reset
      # happened in between) or the queue is closed. Otherwise it goes
      # through the same do_add path as an immediate add, so dedupe, the
      # in-flight dirty flag and the rate limiter all see one consistent
      # state.
      def fire_due_entries(now)
        until @delayed.empty? || @delayed.first.due_at > now
          entry = @delayed.shift
          next unless entry.seq == @retry_seq && !@closed

          do_add(entry.request)
        end
      end
    end
  end
end
