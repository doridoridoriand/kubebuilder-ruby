# frozen_string_literal: true

require "json"

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
        resp = fetch_list
        items = resp["items"] || []
        items.each { |item| @store.add(Delta::ADDED, item) }
        @resource_version = resp.dig("metadata", "resourceVersion")
        @synced = true
      rescue StandardError => e
        KrubyController.logger.error("Informer populate failed: #{e.message}")
        raise
      end

      def fetch_list
        list_path = list_path_for(@gvk)
        request = @api_client.build_request("GET", list_path, auth_names: ["BearerToken"])
        response = request.run
        unless response.success?
          raise KrubyController::Error,
                "Informer list failed for #{@gvk} at #{list_path} (HTTP #{response.code}): #{response.status_message}"
        end
        JSON.parse(response.body)
      end

      def watch_loop
        while @running
          # Wait for the initial List (or a relist after a break) so the
          # watch always starts from a known resourceVersion.
          sleep 0.1 while @running && @resource_version.nil?
          break unless @running

          watch_once
          break unless @running

          relist
        end
      end

      # Runs a single watch from the current resourceVersion. Any break --
      # 410 Gone (stale RV), 404, network error, or a clean server-side
      # close -- falls through to relist, which re-syncs the cache.
      def watch_once
        watch = Kubernetes::Watch.new(@api_client)
        watch_path = watch_path_for(@gvk, @resource_version)
        watch.connect(watch_path) do |event|
          type = delta_type(event)
          obj = event["object"]
          @resource_version = obj.dig("metadata", "resourceVersion")
          @store.add(type, obj)
          notify(type, obj)
        end
      rescue StandardError => e
        KrubyController.logger.warn("Watch for #{@gvk} disconnected: #{e.message}; relisting")
        sleep 1
      end

      # Re-Lists the resource, replaces the store contents, and emits
      # ADDED / MODIFIED / DELETED events for the diff so controllers
      # reconcile the state that changed while the watch was down.
      def relist
        resp = fetch_list
        items = resp["items"] || []
        old, new = @store.replace(items)
        emit_relist_events(old, new)
        @resource_version = resp.dig("metadata", "resourceVersion")
      rescue StandardError => e
        KrubyController.logger.warn("Informer relist failed for #{@gvk}: #{e.message}; retrying in 1s")
        sleep 1
        retry if @running
      end

      def emit_relist_events(old, new)
        (new.keys - old.keys).each { |key| notify(Delta::ADDED, new[key]) }
        (old.keys & new.keys).each do |key|
          old_rv = old[key].dig("metadata", "resourceVersion").to_s
          new_rv = new[key].dig("metadata", "resourceVersion").to_s
          notify(Delta::MODIFIED, new[key]) if old_rv != new_rv
        end
        (old.keys - new.keys).each { |key| notify(Delta::DELETED, old[key]) }
      end

      def notify(type, obj)
        @handlers.each { |h| h.handle(type, obj) }
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
