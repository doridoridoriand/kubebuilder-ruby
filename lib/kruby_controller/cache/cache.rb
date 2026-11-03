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

      # Returns an independent deep copy of the cached object by default
      # (issue #46): the reconciler may mutate the result — e.g. before an
      # API update — without ever rewriting the cache. +copy: false+ hands
      # back the store-owned object for hot paths that only read it and do
      # not retain it; mutating that result corrupts the cache.
      def get(gvk, namespace, name, copy: true)
        informer = @informers[gvk.to_s]
        return nil unless informer

        informer.store.get(namespace, name, copy:)
      end

      # See #get for the copy contract. The +namespace+ filter runs BEFORE
      # the copy, so a filtered +list+ only pays for the objects it returns:
      # the store hands out an un-copied snapshot (store-owned objects are
      # never mutated in place, so the snapshot stays a consistent view), the
      # namespace selection runs on it outside the store lock, and only the
      # selected objects are deep-copied — also outside the lock.
      def list(gvk, namespace: nil, label_selector: nil, copy: true)
        informer = @informers[gvk.to_s]
        return [] unless informer

        results = informer.store.list(label_selector:, copy: false)
        results = results.select { |o| ns_matches?(o, namespace) } if namespace
        copy ? results.map { |o| Cache.deep_copy(o) } : results
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
