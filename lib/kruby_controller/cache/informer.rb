# frozen_string_literal: true

require "json"

module KrubyController
  module Cache
    class Informer
      attr_reader :store, :gvk, :synced, :sync_error

      def initialize(gvk:, store:, api_client:, handlers: [])
        @gvk = gvk
        @store = store
        @api_client = api_client
        @handlers = handlers
        @resource_version = nil
        @running = false
        @started = false
        @synced = false
        @sync_error = nil
      end

      def start
        return if @started

        @started = true
        @running = true
        # The initial List (with its retry budget) runs to completion before
        # the watch begins, so the watch always starts from the resourceVersion
        # of a completed List and never runs concurrently with a retrying
        # initial population (Kubernetes List/Watch contract).
        @thread = Thread.new { run }
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
        @thread&.join
      end

      def add_handler(handler)
        @handlers << handler
      end

      private

      # Populate first, then watch -- sequentially in one thread. The watch
      # never runs until the initial List has fully succeeded, so a retrying
      # List cannot be clobbered by watch events (and vice versa).
      def run
        populate
        return unless @running
        return unless @synced

        watch_loop
      end

      POPULATE_INITIAL_BACKOFF = 1.0
      POPULATE_MAX_BACKOFF = 30.0
      POPULATE_MAX_ATTEMPTS = 3

      # Lists the initial state up to POPULATE_MAX_ATTEMPTS times. On success
      # it marks the informer synced; once the retry budget is exhausted it
      # records the cause in +sync_error+ (instead of looping until the
      # manager's unrelated timeout) so the cache/manager can surface the real
      # error and fail startup with it.
      def populate
        backoff = POPULATE_INITIAL_BACKOFF
        attempt = 0
        while attempt < POPULATE_MAX_ATTEMPTS
          attempt += 1
          begin
            resp = fetch_list
            items = resp["items"] || []
            items.each { |item| @store.add(Delta::ADDED, item) }
            @resource_version = resp.dig("metadata", "resourceVersion")
            @synced = true
            return
          rescue StandardError => e
            KrubyController.logger.error(
              "Informer populate for #{@gvk} attempt #{attempt}/#{POPULATE_MAX_ATTEMPTS} failed: #{e.message}"
            )
            # A stop is not a sync failure; do not record an error.
            return unless @running

            # Exhausted the retry budget: record the real cause so startup
            # fails with it instead of a generic timeout.
            if attempt == POPULATE_MAX_ATTEMPTS
              @sync_error = e
              return
            end

            interruptible_sleep(backoff)
            # Recheck after the (interruptible) backoff so a stop during the
            # sleep does not trigger one more List, which could write a stale
            # snapshot and re-mark the cache synced after it was cleared.
            return unless @running

            backoff = [backoff * 2, POPULATE_MAX_BACKOFF].min
          end
        end
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
