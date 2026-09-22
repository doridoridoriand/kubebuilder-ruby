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
    class WorkQueue
      SENTINEL = Object.new.freeze

      def initialize
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
      end

      def add(request)
        @mutex.synchronize do
          return if @closed

          key = request.namespaced_name.to_s
          if @in_flight.key?(key)
            @dirty.add(key)
          elsif !@pending_keys.include?(key)
            @pending_keys.add(key)
            @queue << request
          end
          @cond.signal
        end
      end

      def add_after(request, seconds)
        Thread.new { sleep seconds; add(request) }
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
          # Unblock any workers blocked in get
          num_workers.times { @queue << SENTINEL }
          @cond.broadcast
        end
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
          @cond.broadcast
        end
      end
    end
  end
end
