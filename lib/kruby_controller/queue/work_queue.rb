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
    # * Registration collapses duplicates: at most ONE pending delayed entry
    #   per key exists, always the one with the earliest deadline. A
    #   later-registered deadline for a key that already has a pending entry
    #   is superseded and never produces a second copy; an
    #   earlier-registered deadline replaces the pending one (the sooner
    #   fire reconciles with the latest state either way).
    # * An immediate `add` for a key with a pending delayed entry wins: the
    #   key becomes pending/in flight right away and the delayed fire is
    #   deduped when it fires. A delayed entry never preempts in-flight work.
    # * A delayed fire while its key is pending is a dedupe no-op; while its
    #   key is in flight it records the dirty flag (exactly like an informer
    #   event), so the completion re-queues the key once; while the key is
    #   free (the earlier attempt already completed) it enqueues exactly
    #   once — a fresh, legitimate retry.
    #
    # Lifecycle is serialized against the queue mutex. Registration checks
    # `@closed` and the retry lifecycle in the SAME critical section that
    # inserts the entry and starts the scheduler, so a shutdown cannot slip
    # between the check and the insertion and no scheduler can ever be
    # started for a closed queue. shutdown and reset retire the current
    # scheduler thread (per-scheduler stop flag, captured under the lock)
    # and join it outside the lock, so a scheduler restarted by a reset in
    # that window is never joined by the retiring shutdown.
    class WorkQueue
      SENTINEL = Object.new.freeze

      # A delayed enqueue promise. Fires at +due_at+ (monotonic clock) and
      # enqueues only if the queue is still open and the retry lifecycle
      # (seq) that scheduled it is still current.
      DelayEntry = Struct.new(:due_at, :seq, :request)

      # One scheduler thread with its own stop flag. The flag is per handle
      # so a scheduler started after a shutdown begins can never prevent the
      # retired one from observing its stop (and vice versa).
      SchedulerHandle = Struct.new(:thread, :stop_requested)

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
        # Deadline-sorted pending delayed entries (one per key, earliest
        # deadline wins); the shared scheduler thread fires them
        # oldest-deadline-first. @delayed_by_key gives O(1) duplicate lookup.
        @delayed = []
        @delayed_by_key = {}
        @scheduler = nil
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
      # inject stale work after Controller#start reopens the queue. A second
      # registration for a key that already has a pending entry is superseded
      # (the earliest deadline wins) and returns false.
      # Returns false when the queue is closed or nothing was scheduled; true
      # otherwise.
      def add_after(request, seconds)
        @mutex.synchronize do
          return false if @closed

          entry = DelayEntry.new(monotonic_time + seconds, @retry_seq, request)
          schedule_locked(entry)
        end
      end

      # Re-queues +request+ after a delay decided by the rate limiter
      # (controller-runtime's AddRateLimited). Requires a queue built with a
      # rate_limiter. Does nothing (and records no backoff) when the queue is
      # already closed.
      def add_rate_limited(request)
        raise ArgumentError, "WorkQueue#add_rate_limited requires a rate_limiter" unless @rate_limiter

        @mutex.synchronize do
          return false if @closed

          delay = @rate_limiter.backoff(request.namespaced_name.to_s)
          entry = DelayEntry.new(monotonic_time + delay, @retry_seq, request)
          schedule_locked(entry)
        end
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
        handle = nil
        @mutex.synchronize do
          return if @closed

          @closed = true
          # No delayed retry survives a shutdown: purge the entries and
          # retire the shared scheduler thread. The handle (with its own
          # stop flag) is captured under this lock, so a scheduler started
          # by a registration that ran in this same lock is part of THIS
          # retirement, and a scheduler started after the lock is released
          # belongs to a later lifecycle and is never joined by this call.
          @delayed.clear
          @delayed_by_key.clear
          handle = stop_current_scheduler
          # Unblock any workers blocked in get
          num_workers.times { @queue << SENTINEL }
          @cond.broadcast
        end
        handle&.thread&.join
      end

      def shutdown?
        @mutex.synchronize { @closed }
      end

      # Reopens the queue after shutdown, keeping any real pending requests
      # and discarding leftover shutdown sentinels. The previous lifecycle's
      # scheduler thread is retired (stopped and joined outside the lock);
      # the next delayed retry lazily starts a fresh scheduler.
      def reset
        handle = nil
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
          # seq, so purging is both correct and bounded. The old scheduler has
          # nothing left to serve; retire it (joined below).
          @retry_seq += 1
          @delayed.clear
          @delayed_by_key.clear
          handle = stop_current_scheduler
          @scheduler_cond.broadcast
          @cond.broadcast
        end
        handle&.thread&.join
      end

      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Validates, dedupes, inserts and (lazily) starts the scheduler in ONE
      # critical section: the caller holds @mutex, so a shutdown can never
      # slip between the closed check and the insertion, and no scheduler is
      # ever started for a closed queue.
      def schedule_locked(entry)
        return false if @closed
        return false if entry.seq != @retry_seq

        key = entry.request.namespaced_name.to_s
        superseded = @delayed_by_key[key]
        if superseded
          # At most one pending delayed entry per key: the earliest deadline
          # wins, so a later registration never produces a second copy.
          return false if superseded.due_at <= entry.due_at

          @delayed.delete(superseded)
          @delayed_by_key.delete(key)
        end

        insert_deadline_sorted(entry)
        @delayed_by_key[key] = entry
        begin
          start_scheduler unless @scheduler
        rescue StandardError => e
          # Startup failed: roll the queue back so a later registration can
          # retry (an entry is never left silently unserved).
          @delayed.delete(entry)
          @delayed_by_key.delete(key)
          if superseded
            insert_deadline_sorted(superseded)
            @delayed_by_key[key] = superseded
          end
          KrubyController.logger.warn("WorkQueue: delayed scheduler start failed: #{e.message}")
          return false
        end
        # Wake the scheduler early only if the new entry is the earliest
        # deadline; otherwise the current wait already governs.
        @scheduler_cond.signal if @delayed.first.equal?(entry)
        true
      end

      def insert_deadline_sorted(entry)
        index = @delayed.bsearch_index { |e| e.due_at > entry.due_at } || @delayed.length
        @delayed.insert(index, entry)
      end

      # Retires the current scheduler under the lock: sets ITS stop flag
      # (per-scheduler state, so a fresh scheduler is unaffected) and hands
      # the handle back for the caller to join outside the lock.
      def stop_current_scheduler
        handle = @scheduler
        if handle
          handle.stop_requested = true
          @scheduler = nil
          @scheduler_cond.broadcast
        end
        handle
      end

      def start_scheduler
        handle = SchedulerHandle.new(nil, false)
        handle.thread = Thread.new { scheduler_loop(handle) }
        @scheduler = handle
      end

      def scheduler_loop(handle)
        loop do
          retire = false
          @mutex.synchronize do
            if handle.stop_requested
              retire = true
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
          return if retire
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
          @delayed_by_key.delete(entry.request.namespaced_name.to_s)
          next unless entry.seq == @retry_seq && !@closed

          do_add(entry.request)
        end
      end
    end
  end
end
