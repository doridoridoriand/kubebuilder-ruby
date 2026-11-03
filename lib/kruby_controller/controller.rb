# frozen_string_literal: true

module KrubyController
  class Controller
    attr_reader :name, :reconciler, :for_gvk, :rate_limiter

    def initialize(reconciler:, cache:, for_gvk:, max_concurrent: 1, name: nil, owns: [], watches: [], predicate: nil,
                   rate_limiter: nil)
      @reconciler = reconciler
      @cache = cache
      @for_gvk = for_gvk
      @max_concurrent = max_concurrent
      @name = name || @for_gvk.kind.downcase
      @owns = Array(owns)
      @watches = Array(watches)
      @predicate = predicate
      @rate_limiter = rate_limiter || Queue::ExponentialBackoffRateLimiter.new
      @queue = Queue::WorkQueue.new(rate_limiter: @rate_limiter)
      @running = false
      @reconciler.cache = cache
      @reconciler.logger = KrubyController.logger
    end

    # Reopens the queue from a previous lifecycle BEFORE the registration
    # guard: on leadership reacquisition the handlers are already registered
    # (this method is a no-op) and the restarted cache emits its initial List
    # diff while workers are still down, so the queue must accept events
    # again or the changes observed while leaderless are silently dropped.
    def register
      @queue.reset if @queue.shutdown?
      return if @handler_registered

      informer = @cache.register(gvk: @for_gvk)
      base = Handler::EnqueuedObject.new(queue: @queue)
      informer.add_handler(@predicate ? Handler::Predicated.new(handler: base, predicate: @predicate) : base)

      @owns.each do |owner_gvk|
        owns_informer = @cache.register(gvk: owner_gvk)
        owns_informer.add_handler(
          Handler::EnqueuedOwner.new(queue: @queue, owner_gvk: @for_gvk, owner_namespaced: @for_gvk.namespaced?)
        )
      end

      @watches.each do |watch|
        watch_informer = @cache.register(gvk: watch[:gvk])
        handler = watch[:handler] || Handler::EnqueuedObject.new(queue: @queue)
        handler = Handler::Predicated.new(handler: handler, predicate: watch[:predicate]) if watch[:predicate]
        watch_informer.add_handler(handler)
      end

      @handler_registered = true
    end

    def start
      register
      @running = true
      @workers = (1..@max_concurrent).map do |i|
        Thread.new do
          KrubyController.logger.info("Controller #{@name} worker #{i} started")
          worker_loop
        end
      end
    end

    # Stops the controller. With +timeout+, waits at most `timeout` seconds
    # in total for the workers to finish their in-flight reconcile; a worker
    # that does not return within the remaining budget is abandoned (it
    # exits on its next loop check; the closed queue delivers no further
    # work). Without +timeout+ the join is unbounded (previous behavior).
    def stop(timeout: nil)
      @running = false
      @queue.shutdown(@max_concurrent)
      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      (@workers || []).each do |worker|
        remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining && remaining <= 0
          KrubyController.logger.warn(
            "Controller #{@name}: stop budget exhausted; abandoning a running worker"
          )
          next
        end

        join_worker(worker, remaining)
      end
    end

    private

    def join_worker(worker, timeout)
      return worker.join if timeout.nil?
      return if worker.join(timeout)

      KrubyController.logger.warn(
        "Controller #{@name}: a reconcile did not return within #{timeout.round(1)}s; abandoning the worker"
      )
    end

    def worker_loop
      while @running
        request = @queue.get
        break if request.equal?(Queue::WorkQueue::SENTINEL)

        key = request.namespaced_name.to_s
        failure = false
        result = nil
        begin
          begin
            result = @reconciler.reconcile(request)
          rescue StandardError => e
            failure = true
            KrubyController.logger.error("Reconcile error for #{request}: #{e.message}")
          end

          if @queue.shutdown?
            # Only a truly successful completion clears the failure history.
            # Controller#start reopens the queue without replacing the
            # limiter, so a stale streak would otherwise make the first
            # failure after restart wait a doubled delay; but an error-bearing
            # result (or a raised exception) is a failure and must keep its
            # streak. The requeue itself is still suppressed.
            @queue.forget(request) if clear_failure_on_shutdown?(failure, result)
            return
          end

          # Rate-limit / forget bookkeeping runs while the key is still in
          # flight, so a concurrent event for the same key is parked in the
          # dirty set instead of racing the failure counter.
          if failure
            requeue_with_backoff(request, key)
          else
            handle_result(result, request, key)
          end
        ensure
          @queue.done(request)
        end
      end
    end

    # Re-queues a failed reconcile after a per-key exponential backoff delay
    # (5s base, doubling per consecutive failure, capped at 300s by default).
    def requeue_with_backoff(request, key)
      delay = @rate_limiter.backoff(key)
      KrubyController.logger.info(
        "Requeueing #{request} in #{delay} s " \
        "(consecutive failures: #{@rate_limiter.failures(key)})"
      )
      @queue.add_after(request, delay)
    end

    def handle_result(result, request, key)
      # A result carrying an error is a failure: rate-limited requeue,
      # regardless of the explicit delay the reconciler requested. Checking
      # this first keeps error-bearing RetryAfter responses on the exponential
      # schedule instead of retrying on the fixed explicit delay.
      if result.respond_to?(:error) && result.error
        @queue.add_after(request, @rate_limiter.backoff(key))
        return
      end

      # Error-free RetryAfter: honor the explicit delay and reset the streak.
      if result.is_a?(Result::RetryAfter)
        @queue.forget(request)
        @queue.add_after(request, result.after)
        return
      end

      # Ok, or an error-free Requeue: reset the streak. A Requeue additionally
      # schedules an immediate retry.
      @queue.forget(request)
      @queue.add(request) if result.is_a?(Result::Requeue)
    end

    # Whether a completion that finishes while the queue is shutting down
    # should clear its per-key failure history. Only a truly successful
    # completion does: no raised exception (+failed+) and no error-bearing
    # result. An error-bearing result (or exception) is a failure, and its
    # streak must survive so the next failure after a restart does not drop
    # back to the base delay.
    def clear_failure_on_shutdown?(failed, result)
      return false if failed
      return false if result.respond_to?(:error) && !result.error.nil?

      true
    end
  end
end
