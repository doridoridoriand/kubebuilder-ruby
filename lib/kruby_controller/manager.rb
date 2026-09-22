# frozen_string_literal: true

module KrubyController
  class Manager
    attr_reader :cache, :stopped

    def initialize(
      kube_config: nil,
      namespace: nil,
      leader_elect: true,
      lease_name: "kruby-controller-lock",
      lease_namespace: "kube-system",
      lease_duration: 15,
      renew_deadline: 10,
      retry_period: 2,
      logger: nil
    )
      @kube_config = kube_config
      @namespace = namespace
      @leader_elect = leader_elect
      @lease_opts = { lease_name:, lease_namespace:, lease_duration:, renew_deadline:, retry_period: }
      @logger = logger
      @cache = Cache::SharedCache.new(kube_config:)
      @controllers = []
      @stopped = false
      @stop_channel = Channel.new
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
        watches: Array(options.fetch(:watches, [])).map { |w| w[:gvk] ? w.merge(gvk: resolve_target(w[:gvk], options)) : w },
        predicate: options[:predicate]
      )
      @controllers << controller
      controller
    end

    def for(gvk)
      Builder::ControllerBuilder.new(self, gvk)
    end

    def start
      KrubyController.logger.info("Starting manager...")

      if @leader_elect
        @leader_elector = Election::LeaderElector.new(
          client: coordination_client,
          on_stopped_leading: -> { stop_components },
          **@lease_opts
        )
        @leader_elector.run { start_and_sync }
      else
        start_and_sync
      end

      setup_signal_handlers
      @stop_channel.receive
    end

    def stop(timeout: 30)
      return if @stopped
      @stopped = true
      KrubyController.logger.info("Stopping manager...")
      @leader_elector&.stop
      stop_components
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
      start_controllers
      @cache.start
      @cache.wait_for_sync
    end

    def stop_components
      @controllers.each(&:stop)
      @cache.stop
    end

    def start_controllers
      @controllers.each(&:start)
    end

    def setup_signal_handlers
      %w[TERM INT].each do |sig|
        Signal.trap(sig) { stop }
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
    end
  end
end
