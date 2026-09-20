# frozen_string_literal: true

module KrubyController
  class Controller
    attr_reader :name, :reconciler, :for_gvk

    def initialize(reconciler:, cache:, for_gvk:, max_concurrent: 1, name: nil, owns: [], watches: [], predicate: nil)
      @reconciler = reconciler
      @cache = cache
      @for_gvk = for_gvk
      @max_concurrent = max_concurrent
      @name = name || @for_gvk.kind.downcase
      @owns = Array(owns)
      @watches = Array(watches)
      @predicate = predicate
      @queue = Queue::WorkQueue.new
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
          owns_informer.add_handler(Handler::EnqueuedOwner.new(queue: @queue, owner_gvk: @for_gvk))
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
        result = nil
        error = false
        begin
          result = @reconciler.reconcile(request)
        rescue => e
          error = true
          KrubyController.logger.error("Reconcile error for #{request}: #{e.message}")
          @queue.add_after(request, 5)
        ensure
          @queue.done(request)
        end
        return if @queue.shutdown?
        handle_result(result, request) unless error
      end
    end

    def handle_result(result, request)
      case result
      when Result::RetryAfter
        @queue.add_after(request, result.after)
      when Result::Requeue
        @queue.add(request)
      end
    end
  end
end
