# frozen_string_literal: true

module KrubyController
  module Queue
    class WorkQueue
      SENTINEL = Object.new.freeze

      def initialize
        @queue = ::Queue.new
        @known = Set.new
        @mutex = Mutex.new
        @closed = false
      end

      def add(request)
        return if @closed
        key = request.namespaced_name.to_s
        @mutex.synchronize do
          return if @known.include?(key)
          @known.add(key)
          @queue << request
        end
      end

      def add_after(request, seconds)
        Thread.new { sleep seconds; add(request) }
      end

      def get
        @queue.pop
      end

      def done(request)
        key = request.namespaced_name.to_s
        @mutex.synchronize { @known.delete(key) }
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
        pending.each { |request| @queue << request }
        @closed = false
      end
    end
  end
end
