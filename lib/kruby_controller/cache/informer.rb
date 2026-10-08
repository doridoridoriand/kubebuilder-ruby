# frozen_string_literal: true

require "json"

module KrubyController
  module Cache
    class Informer
      attr_reader :store, :gvk, :synced

      def initialize(gvk:, store:, api_client:, handlers: [], namespace: nil)
        @gvk = gvk
        @store = store
        @api_client = api_client
        @handlers = handlers
        @namespace = namespace
        @resource_version = nil
        @running = false
        @started = false
        @synced = false
      end

      def start
        return if @started

        @started = true
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
        @started = false
        @synced = false
        @populate_thread&.join
        @watch_thread&.join
      end

      def add_handler(handler)
        @handlers << handler
      end

      private

      def populate
        list_path = list_path_for(@gvk)
        request = @api_client.build_request("GET", list_path, auth_names: ["BearerToken"])
        response = request.run
        unless response.success?
          raise KrubyController::Error,
                "Informer list failed for #{@gvk} at #{list_path} (HTTP #{response.code}): #{response.status_message}"
        end
        resp = JSON.parse(response.body)
        items = resp["items"] || []
        items.each { |item| @store.add(Delta::ADDED, item) }
        @resource_version = resp.dig("metadata", "resourceVersion")
        @synced = true
      rescue StandardError => e
        KrubyController.logger.error("Informer populate failed: #{e.message}")
        raise
      end

      def watch_loop
        while @running
          begin
            watch = Kubernetes::Watch.new(@api_client)
            watch_path = watch_path_for(@gvk, @resource_version)
            watch.connect(watch_path) do |event|
              type = delta_type(event)
              obj = event["object"]
              @resource_version = obj.dig("metadata", "resourceVersion")
              @store.add(type, obj)
              @handlers.each { |h| h.handle(type, obj) }
            end
          rescue StandardError => e
            KrubyController.logger.warn("Watch disconnected: #{e.message}")
            sleep 1
            retry if @running
          end
        end
      end

      # Namespaces the list path only for namespaced resources; cluster-scoped
      # resources stay cluster-wide even when a namespace is configured.
      def list_path_for(gvk)
        prefix = if gvk.group.empty?
                   "/api/#{gvk.version}"
                 else
                   "/apis/#{gvk.group}/#{gvk.version}"
                 end
        scope = if @namespace && gvk.respond_to?(:namespaced?) && gvk.namespaced?
                  "/namespaces/#{@namespace}"
                else
                  ""
                end

        "#{prefix}#{scope}/#{gvk.resource}"
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
