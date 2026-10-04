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

      POPULATE_INITIAL_BACKOFF = 1.0
      POPULATE_MAX_BACKOFF = 30.0

      # Repeatedly Lists the initial state until it succeeds (or the informer
      # is stopped), so a transient API failure at startup does not leave the
      # informer unsynced forever.
      def populate
        backoff = POPULATE_INITIAL_BACKOFF
        loop do
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
          return
        rescue StandardError => e
          KrubyController.logger.error(
            "Informer populate failed for #{@gvk}: #{e.message}; retrying in #{backoff}s"
          )
          return unless @running

          interruptible_sleep(backoff)
          backoff = [backoff * 2, POPULATE_MAX_BACKOFF].min
        end
      end

      # Sleeps up to +seconds+, waking early when the informer is stopped so
      # #stop (which joins this thread) stays responsive.
      def interruptible_sleep(seconds)
        slept = 0.0
        while slept < seconds && @running
          step = [0.5, seconds - slept].min
          sleep step
          slept += step
        end
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
