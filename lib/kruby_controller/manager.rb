# frozen_string_literal: true

module KrubyController
  class Manager
    attr_reader :cache, :stopped

    # Interval at which the running thread polls for a stop request (the
    # signal flag, a programmatic stop, or a startup failure).
    SIGNAL_POLL_INTERVAL = 0.1

    def initialize(
      kube_config: nil,
      namespace: nil,
      leader_elect: true,
      lease_name: "kruby-controller-lock",
      lease_namespace: "kube-system",
      lease_duration: 15,
      renew_deadline: 10,
      retry_period: 2,
      stop_timeout: 30,
      logger: nil
    )
      @kube_config = kube_config
      @namespace = namespace
      @leader_elect = leader_elect
      @lease_opts = { lease_name:, lease_namespace:, lease_duration:, renew_deadline:, retry_period: }
      @stop_timeout = stop_timeout
      @logger = logger
      @cache = Cache::SharedCache.new(kube_config:, namespace:)
      @controllers = []
      @stopped = false
      @stop_requested_by_signal = false
      @stop_channel = Channel.new
      @startup_error = nil
      KrubyController.logger = @logger if @logger
    end

    def add(controller_or_reconciler, **options)
      reconciler = instantiate_reconciler(controller_or_reconciler)
      gvk = resolve_gvk(options)
      controller = Controller.new(
        reconciler:,
        cache: @cache,
        for_gvk: gvk,
        max_concurrent: options.fetch(:max_concurrent, 1),
        name: options[:name],
        owns: Array(options.fetch(:owns, [])).map { |target| resolve_target(target, options) },
        watches: Array(options.fetch(:watches, [])).map do |w|
          w[:gvk] ? w.merge(gvk: resolve_target(w[:gvk], options)) : w
        end,
        predicate: options[:predicate],
        rate_limiter: options[:rate_limiter]
      )
      @controllers << controller
      controller
    end

    def for(gvk)
      Builder::ControllerBuilder.new(self, gvk)
    end

    def start
      KrubyController.logger.info("Starting manager...")

      # Both modes block until stop is requested: SIGTERM/SIGINT set a flag
      # (trap handlers must not acquire Mutexes) and the running thread
      # performs the actual stop from normal context.
      setup_signal_handlers

      if @leader_elect
        @leader_elector = Election::LeaderElector.new(
          client: coordination_client,
          on_stopped_leading: -> { stop_components },
          **@lease_opts
        )
        @leader_elector.run { start_leading }
        wait_for_stop
        # Safe from this thread (a different thread than the elector's
        # election_loop), so #stop's join cannot deadlock. Stopping first
        # releases the lease and halts renewal before we fail startup.
        @leader_elector&.stop
        raise @startup_error if @startup_error
      else
        start_and_sync
        wait_for_stop
      end
    end

    # Startup work under leadership. On a fatal startup failure (the cache
    # cannot sync), record the error and signal the stop channel so
    # Manager#start fails with the real cause instead of keeping leadership
    # with running controllers and an inert informer. start_and_sync has
    # already stopped the components before re-raising.
    def start_leading
      start_and_sync
    rescue StandardError => e
      @startup_error = e
      @stop_channel.send(:stopped)
      raise
    end

    def stop(timeout: @stop_timeout)
      return if @stopped

      @stopped = true
      KrubyController.logger.info("Stopping manager...")
      @leader_elector&.stop
      # The drain budget is split evenly across controllers so the total
      # reconcile wait stays bounded by `timeout`: each controller may use up
      # to its share, and a worker still inside a reconcile after its share
      # is abandoned (it exits on its next loop check; the closed queue
      # delivers no further work). Manager#stop returns per contract even
      # when a reconcile or watch does not respond.
      budget = drain_budget
      @controllers.each { |c| c.stop(timeout: budget) }
      @cache.stop
      @stop_channel.send(:stopped)
    end

    def leader?
      return true unless @leader_elect

      @leader_elector&.leader || false
    end

    private

    def instantiate_reconciler(controller_or_reconciler)
      if controller_or_reconciler.is_a?(Class) && controller_or_reconciler < Reconciler
        controller_or_reconciler.new
      else
        controller_or_reconciler
      end
    end

    def resolve_gvk(options)
      resolve_target(options[:for] || options[:for_gvk], options)
    end

    def resolve_target(target, options = {})
      case target
      when GVK
        target
      when Class
        GVK.new(
          group: target.group,
          version: target.version,
          kind: target.kind,
          resource: target.respond_to?(:plural) ? target.plural : nil,
          namespaced: target.respond_to?(:namespaced) ? target.namespaced : options.fetch(:namespaced, true)
        )
      when String, Symbol
        group = options[:group]
        version = options[:version]
        unless group && version
          raise ArgumentError,
                "a bare Kind (#{target}) cannot be resolved; pass a GVK, a CRD class, " \
                "or provide group:/version: options"
        end
        GVK.new(group:, version:, kind: target.to_s, namespaced: options.fetch(:namespaced, true))
      else
        raise ArgumentError, "for:/for_gvk:/owns:/watches: must be a KrubyController::GVK, a CRD class, or a Kind"
      end
    end

    def start_and_sync
      # A stop requested before startup began: register nothing, start nothing.
      return if @stopped

      register_controllers
      @cache.start
      # A cache that is not synced within the timeout is just as fatal as one
      # that fails outright: fail startup (stopping the components we just
      # started) instead of running controllers against an empty/stale cache.
      synced = @cache.wait_for_sync
      if @stopped || !leader?
        # A stop raced in during the sync wait, or leadership was lost while
        # the cache was syncing (the elector flags the loss before its
        # on_stopped_leading cleanup runs). stop() may already have stopped
        # the components; stop_components is idempotent. Workers must never
        # start without the lease or on a stopped manager.
        stop_components
        return
      end
      raise KrubyController::Error, "Manager: cache did not sync within the timeout" unless synced

      # Workers start only after every informer completed its initial List
      # (FR-03). Events observed during the wait are held in the work queue
      # and replayed once workers run, so no reconcile sees a partially
      # synced cache and no initial event is lost.
      start_controllers
    rescue StandardError => e
      # A cache that cannot sync is fatal: stop the components we just
      # started and let the error propagate (Manager#start fails with it).
      KrubyController.logger.error("Manager: cache sync failed: #{e.message}; stopping components")
      stop_components
      raise
    end

    def stop_components
      # The leader-election stop path (on_stopped_leading inside the
      # elector's thread) and the startup-failure rescue share this drain:
      # it must use the same bounded budget as Manager#stop, or an
      # unresponsive reconcile would block the elector join — and with it
      # Manager#stop — beyond stop_timeout in the default mode.
      budget = drain_budget
      @controllers.each { |c| c.stop(timeout: budget) }
      @cache.stop
    end

    def drain_budget
      @stop_timeout.to_f / [@controllers.size, 1].max
    end

    def start_controllers
      @controllers.each(&:start)
    end

    def register_controllers
      @controllers.each(&:register)
    end

    def setup_signal_handlers
      %w[TERM INT].each do |sig|
        # A trap handler must not acquire Mutexes (raises ThreadError in trap
        # context); only record the request. The running thread observes the
        # flag in #wait_for_stop and performs the actual stop there.
        Signal.trap(sig) { @stop_requested_by_signal = true }
      end
    end

    # Blocks until the manager is stopped AND the stop's own cleanup has
    # completed: #stop sets @stopped before draining, so observing only the
    # flag would let this thread return while another thread is still
    # draining (a main-thread start returning early can kill the drainer).
    # Either #stop's channel send (or the startup-failure signal) ends the
    # wait; a signal received here performs #stop first, which sends on the
    # channel when its drain finishes.
    def wait_for_stop
      loop do
        stop if @stop_requested_by_signal
        return @stop_channel.receive if @stopped
        return if @stop_channel.received?

        sleep SIGNAL_POLL_INTERVAL
      end
    end

    def coordination_client
      @coordination_client ||= begin
        config = if @kube_config
                   cfg = Kubernetes::Configuration.new
                   Kubernetes::KubeConfig.new(@kube_config).configure(cfg)
                   cfg
                 else
                   Kubernetes::Configuration.default_config
                 end
        Kubernetes::CoordinationV1Api.new(Kubernetes::ApiClient.new(config))
      end
    end

    class Channel
      def initialize
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @value = nil
      end

      def send(value = nil)
        @mutex.synchronize do
          @value = value
          @cond.signal
        end
      end

      def receive
        @mutex.synchronize do
          @cond.wait(@mutex) until @value
          @value
        end
      end

      # Non-blocking check used by #wait_for_stop, which cannot block on
      # #receive and also poll the signal flag in the same thread.
      def received?
        @mutex.synchronize { !@value.nil? }
      end
    end
  end
end
