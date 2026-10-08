# frozen_string_literal: true

module KrubyController
  module Cache
    class SharedCache
      def initialize(kube_config: nil, namespace: nil)
        @kube_config = kube_config
        @namespace = namespace
        @informers = {}
        @mutex = Mutex.new
      end

      def register(gvk:)
        @mutex.synchronize do
          return @informers[gvk.to_s] if @informers.key?(gvk.to_s)

          store = Store.new
          informer = Informer.new(gvk:, store:, api_client: api_client, handlers: [], namespace: @namespace)
          @informers[gvk.to_s] = informer
          informer
        end
      end

      def get(gvk, namespace, name)
        informer = @informers[gvk.to_s]
        return nil unless informer

        informer.store.get(namespace, name)
      end

      def list(gvk, namespace: nil, label_selector: nil)
        informer = @informers[gvk.to_s]
        return [] unless informer

        results = informer.store.list(label_selector:)
        results = results.select { |o| ns_matches?(o, namespace) } if namespace
        results
      end

      # Waits until every informer is synced. If an informer exhausts its
      # initial-List retry budget, the recorded cause is raised so Manager
      # startup fails with the real error instead of hanging.
      def wait_for_sync(timeout: 30)
        deadline = Time.now + timeout
        loop do
          informers = @mutex.synchronize { @informers.values }
          failed = informers.find { |i| !i.synced && i.sync_error }
          raise failed.sync_error if failed

          return true if informers.all?(&:synced)
          return false if Time.now >= deadline

          sleep 0.1
        end
      end

      def start
        @informers.values.each(&:start)
      end

      def stop
        @informers.values.each(&:stop)
      end

      private

      def api_client
        @api_client ||= begin
          config = if @kube_config
                     cfg = Kubernetes::Configuration.new
                     Kubernetes::KubeConfig.new(@kube_config).configure(cfg)
                     cfg
                   else
                     Kubernetes::Configuration.default_config
                   end
          Kubernetes::ApiClient.new(config)
        end
      end

      def ns_matches?(obj, namespace)
        obj_ns = obj.is_a?(Hash) ? obj.dig("metadata", "namespace") : ""
        obj_ns == namespace
      end
    end
  end
end
