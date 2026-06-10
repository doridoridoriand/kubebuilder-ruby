# frozen_string_literal: true

module KrubyController
  class Controller
    attr_reader :name, :reconciler

    def initialize(reconciler:, cache:, for_gvk:, max_concurrent: 1, name: nil)
      @reconciler = reconciler
      @cache = cache
      @for_gvk = for_gvk
      @max_concurrent = max_concurrent
      @name = name || @for_gvk.kind.downcase
      @queue = Queue::WorkQueue.new
      @running = false
      @reconciler.cache = cache
      @reconciler.logger = KrubyController.logger
    end

    def start
      @running = true
      informer = @cache.register(gvk: @for_gvk)
      informer.add_handler(Handler::EnqueuedObject.new(queue: @queue))

      @workers = (1..@max_concurrent).map do |i|
        Thread.new do
          KrubyController.logger.info("Controller #{@name} worker #{i} started")
          worker_loop
        end
      end
    end

    def stop
      @running = false
      @queue.shutdown
      @workers&.each(&:join)
    end

    private

    def worker_loop
      while @running
        request = @queue.get
        begin
          result = @reconciler.reconcile(request)
          handle_result(result, request)
        rescue => e
          KrubyController.logger.error("Reconcile error for #{request}: #{e.message}")
          @queue.add_after(request, 5)
        ensure
          @queue.done(request)
        end
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
