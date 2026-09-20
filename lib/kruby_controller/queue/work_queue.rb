# frozen_string_literal: true

module KrubyController
  module Queue
    # Deduplicating work queue with an in-flight dirty flag
    # (controller-runtime semantics).
    #
    # A key is "present" while it is queued (`@queued`) or in flight
    # (`@processing`). `add` is a no-op for a key that is already present,
    # except when the key is in flight: then it is recorded in `@dirty`
    # instead of enqueued. When the worker calls `done`, a dirty key is
    # re-queued so the reconciler runs once more for the latest state.
    # Without this, an event for a key that is currently being reconciled
    # would be dropped and never re-triggered.
    class WorkQueue
      SENTINEL = Object.new.freeze

      def initialize
        @queue = ::Queue.new
        @queued = Set.new
        @processing = Set.new
        @dirty = Set.new
        @mutex = Mutex.new
        @closed = false
      end

      def add(request)
        return if @closed
        @mutex.synchronize do
          key = request.namespaced_name.to_s
          if @processing.include?(key)
            @dirty.add(key)
            return
          end
          return if @queued.include?(key)
          @queued.add(key)
          @queue << request
        end
      end

      def add_after(request, seconds)
        Thread.new { sleep seconds; add(request) }
      end

      def get
        request = @queue.pop
        return request if request.equal?(SENTINEL)

        @mutex.synchronize do
          key = request.namespaced_name.to_s
          @queued.delete(key)
          @processing.add(key)
        end
        request
      end

      # Marks a request as completed. Only requests currently in flight
      # (`@processing`) are considered: a key that is in flight and dirty is
      # re-queued so the reconciler runs once more; a key that is in flight
      # and not dirty is simply removed. Completions for keys that are not in
      # flight (e.g. a duplicate `done` after a dirty requeue, where the
      # re-queued copy is still pending or already handed to a worker) are
      # ignored, keeping `done` idempotent and preventing duplicate
      # enqueues.
      def done(request)
        return if request.equal?(SENTINEL)
        @mutex.synchronize do
          key = request.namespaced_name.to_s
          next unless @processing.include?(key)

          @processing.delete(key)
          if @dirty.include?(key)
            @dirty.delete(key)
            @queued.add(key)
            @queue << request
          else
            @queued.delete(key)
          end
        end
      end

      def len
        @queue.length
      end

      def shutdown(num_workers = 1)
        return if @closed
        @closed = true
        # Unblock any threads blocked on pop
        num_workers.times { @queue << SENTINEL }
      end

      def shutdown?
        @closed
      end

      # Reopens the queue after shutdown, draining any shutdown sentinels that
      # were not consumed by workers (e.g. a worker that returned mid-cycle
      # after checking shutdown?). Real pending requests are preserved.
      def reset
        pending = []
        loop do
          item = @queue.pop(true)
          pending << item unless item.equal?(SENTINEL)
        rescue ThreadError
          break
        end
        @mutex.synchronize do
          pending.each do |request|
            @queue << request
            @queued.add(request.namespaced_name.to_s)
          end
          @processing.clear
          @dirty.clear
        end
        @closed = false
      end
    end
  end
end
