# frozen_string_literal: true

module KrubyController
  module Cache
    class Informer
      attr_reader :store, :gvk, :synced

      def initialize(gvk:, store:, api_client:, handlers: [])
        @gvk = gvk
        @store = store
        @api_client = api_client
        @handlers = handlers
        @resource_version = nil
        @running = false
        @synced = false
      end

      def start
        @running = true
        @populate_thread = Thread.new { populate }
        @watch_thread = Thread.new { watch_loop }
      end

      def wait_for_sync(timeout: 30)
        deadline = Time.now + timeout
        sleep 0.1 until @synced || Time.now >= deadline
        @synced
      end

      def stop
        @running = false
        @populate_thread&.join
        @watch_thread&.join
      end

      def add_handler(handler)
        @handlers << handler
      end

      private

      def populate
        list_path = list_path_for(@gvk)
        resp = @api_client.get(list_path)
        items = resp.dig("items") || []
        items.each { |item| @store.add(Delta::ADDED, item) }
        @resource_version = resp.dig("metadata", "resourceVersion")
        @synced = true
      rescue => e
        KrubyController.logger.error("Informer populate failed: #{e.message}")
        raise
      end

      def watch_loop
        loop while @running do
          watch = Kubernetes::Watch.new(@api_client)
          watch_path = watch_path_for(@gvk, @resource_version)
          watch.connect(watch_path) do |event|
            type = delta_type(event)
            obj = event["object"]
            @resource_version = obj.dig("metadata", "resourceVersion")
            @store.add(type, obj)
            @handlers.each { |h| h.handle(type, obj) }
          end
        rescue => e
          KrubyController.logger.warn("Watch disconnected: #{e.message}")
          sleep 1
          retry
        end
      end

      def list_path_for(gvk)
        if gvk.group.empty?
          "/api/#{gvk.version}/#{gvk.resource}"
        else
          "/apis/#{gvk.group}/#{gvk.version}/#{gvk.resource}"
        end
      end

      def watch_path_for(gvk, rv)
        "#{list_path_for(gvk)}?watch=true&resourceVersion=#{rv}"
      end

      def delta_type(event)
        case event["type"]
        when "ADDED" then Delta::ADDED
        when "MODIFIED" then Delta::MODIFIED
        when "DELETED" then Delta::DELETED
        else Delta::BOOKKEEPER
        end
      end
    end
  end
end
