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

    def start
      @running = true
      @queue.reset if @queue.shutdown?
      unless @handler_registered
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

      @workers = (1..@max_concurrent).map do |i|
        Thread.new do
          KrubyController.logger.info("Controller #{@name} worker #{i} started")
          worker_loop
        end
      end
    end

    def stop
      @running = false
      @queue.shutdown(@max_concurrent)
      @workers&.each(&:join)
    end

    private

    def worker_loop
      while @running
        item = @queue.get
        break if item.equal?(Queue::WorkQueue::SENTINEL)

        request = item
        key = request.namespaced_name.to_s
        result = nil
        failure = false
        begin
          result = @reconciler.reconcile(request)
        rescue StandardError => e
          failure = true
          KrubyController.logger.error("Reconcile error for #{request}: #{e.message}")
        ensure
          @queue.done(request)
        end
        return if @queue.shutdown?

        if failure
          requeue_with_backoff(request, key)
        else
          handle_result(result, request, key)
        end
      end
    end

    # Re-queues a failed reconcile after a per-key exponential backoff delay
    # (5ms base, doubling per consecutive failure, capped at 5s by default).
    def requeue_with_backoff(request, key)
      delay = @rate_limiter.backoff(key)
      KrubyController.logger.info(
        "Requeueing #{request} in #{(delay * 1000).round} ms " \
        "(consecutive failures: #{@rate_limiter.failures(key)})"
      )
      @queue.add_after(request, delay)
    end

    def handle_result(result, request, key)
      # Explicit backoff requested by the reconciler; leaves the per-key
      # failure count untouched.
      return @queue.add_after(request, result.after) if result.is_a?(Result::RetryAfter)
      # A result carrying an error is a failure: rate-limited requeue.
      return @queue.add_after(request, @rate_limiter.backoff(key)) if result.respond_to?(:error) && result.error
      return @queue.add(request) if result.is_a?(Result::Requeue)

      @queue.forget(request)
    end
  end
end
