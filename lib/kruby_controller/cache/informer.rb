# frozen_string_literal: true

require "cgi"
require "json"
require "monitor"

module KrubyController
  module Cache
    class Informer
      attr_reader :store, :gvk, :synced, :sync_error, :list_page_size

      def initialize(gvk:, store:, api_client:, handlers: [], namespace: nil, list_page_size: nil)
        @gvk = gvk
        @store = store
        @api_client = api_client
        @handlers = handlers
        @namespace = namespace
        # Optional page size for paged LISTs (issue #45). nil sends no limit
        # and simply follows the server's continue tokens.
        @list_page_size = list_page_size
        @resource_version = nil
        @running = false
        @started = false
        @synced = false
        @sync_error = nil
        @generation = 0
        @lifecycle_lock = Monitor.new
      end

      def start
        @lifecycle_lock.synchronize do
          return if @started

          @started = true
          @running = true
          @synced = false
          @sync_error = nil
          @resource_version = nil
          @generation += 1
          generation = @generation
          @populate_thread = Thread.new { populate(generation) }
          @watch_thread = Thread.new { watch_loop(generation) }
        end
      end

      def wait_for_sync(timeout: 30)
        deadline = Time.now + timeout
        sleep 0.1 until @synced || Time.now >= deadline
        @synced
      end

      def stop
        workers = @lifecycle_lock.synchronize do
          @running = false
          @started = false
          @synced = false
          @generation += 1
          threads = [@populate_thread, @watch_thread]
          @populate_thread = @watch_thread = nil
          threads
        end
        # A handler may stop the informer reentrantly. Joining while the
        # handler holds the monitor would prevent other workers from exiting.
        return if @lifecycle_lock.mon_owned?

        workers.each { |thread| join_bounded(thread) }
      end

      def add_handler(handler)
        @lifecycle_lock.synchronize { @handlers << handler }
      end

      private

      def running?(generation)
        @lifecycle_lock.synchronize { @running && @generation == generation }
      end

      # Invalidate workers before joining them. Network calls stay outside
      # this monitor, but commits and handler delivery share it with stop so
      # a stopped generation cannot mutate state, even after a new start.
      # Monitor permits handlers to call stop without a recursive-lock error.
      def with_active_run(generation)
        @lifecycle_lock.synchronize do
          return unless @running && @generation == generation

          yield
        end
      end

      # How long #stop waits for a worker thread to exit before giving up.
      # The watch stream (Typhoeus) exposes no cancellation API, so a stream
      # that stays open cannot be interrupted; bounding the join keeps
      # cleanup from blocking the startup-error path indefinitely.
      STOP_JOIN_TIMEOUT = 10

      POPULATE_INITIAL_BACKOFF = 1.0
      POPULATE_MAX_BACKOFF = 30.0
      # Initial List plus three retries (design: "3 retries -> Manager
      # startup failure"), so four total attempts.
      POPULATE_MAX_ATTEMPTS = 4

      # Lists the initial state up to POPULATE_MAX_ATTEMPTS times. On success
      # it replaces the store (dropping objects deleted since the previous
      # run) and emits the snapshot diff, then marks the informer synced;
      # once the retry budget is exhausted it records the cause in
      # +sync_error+ so the cache/manager can surface it and fail startup,
      # instead of leaving the informer inert.
      #
      # Replacing (rather than upserting) matters when the same informer is
      # reused after a stop (e.g. leadership reacquisition): an object deleted
      # while the informer was stopped would otherwise linger in the store
      # forever, since the resumed watch starts at the fresh List's
      # resourceVersion. On the first run the store is empty, so the diff is
      # simply ADDED for every object (standard informer initial-list).
      def populate(generation)
        backoff = POPULATE_INITIAL_BACKOFF
        attempt = 0
        while running?(generation) && attempt < POPULATE_MAX_ATTEMPTS
          attempt += 1
          begin
            resp = fetch_list
            apply_list(resp, generation, initial: true)
            return
          rescue StandardError => e
            return unless running?(generation)

            KrubyController.logger.error(
              "Informer populate for #{@gvk} attempt #{attempt}/#{POPULATE_MAX_ATTEMPTS} failed: #{e.message}"
            )
            if attempt == POPULATE_MAX_ATTEMPTS
              with_active_run(generation) { @sync_error = e }
              return
            end

            interruptible_sleep(respect_retry_after(e, backoff), generation)
            return unless running?(generation)

            backoff = [backoff * 2, POPULATE_MAX_BACKOFF].min
          end
        end
      end

      # Sleeps up to +seconds+, waking early when the informer is stopped so
      # #stop (which joins this thread) stays responsive.
      def interruptible_sleep(seconds, generation)
        slept = 0.0
        while slept < seconds && running?(generation)
          step = [0.5, seconds - slept].min
          sleep step
          slept += step
        end
      end

      # Honors the server's Retry-After when present (issue #45): wait at
      # least that long, or the caller's own backoff, whichever is longer.
      def respect_retry_after(error, fallback)
        retry_after = error.respond_to?(:retry_after) ? error.retry_after : nil
        [retry_after, fallback].compact.max
      end

      # Joins +thread+ for at most +timeout+ seconds. Returns once the thread
      # has exited; if it is still alive (e.g. blocked in a watch stream that
      # cannot be canceled), logs a warning and returns so the caller is not
      # blocked indefinitely.
      def join_bounded(thread, timeout: STOP_JOIN_TIMEOUT)
        return if thread.nil? || thread == Thread.current
        return unless thread.join(timeout).nil?

        KrubyController.logger.warn(
          "Informer #{@gvk}: a worker thread did not exit within #{timeout}s; " \
          "proceeding with the stopped worker disabled"
        )
      end

      # Lists the resource, following metadata.continue tokens until the
      # collection is exhausted (issue #45). The whole snapshot is collected
      # before anything is applied: a failure on page N leaves the store
      # untouched, and the caller's retry starts from page 1 — which is also
      # what an expired continue token (410 Gone) needs.
      def fetch_list
        items = []
        continue = nil
        resource_version = nil
        loop do
          path = paged_list_path(continue)
          response = run_list_request(path)
          page = JSON.parse(response.body)
          raise RequestError.new("Informer list response for #{@gvk} has no items array") unless page["items"].is_a?(Array)

          items.concat(page["items"])
          resource_version = page.dig("metadata", "resourceVersion")
          continue = page.dig("metadata", "continue")
          break if continue.nil? || continue.empty?
        end

        # Every page of one logical LIST shares the snapshot resourceVersion
        # pinned by the continue token, so the final page's RV is the
        # snapshot's RV. A missing RV is a protocol violation: continuing
        # with a nil RV would make every subsequent watch start blind.
        raise RequestError.new("Informer list response for #{@gvk} has no resourceVersion") if missing_rv?(resource_version)

        { "items" => items, "metadata" => { "resourceVersion" => resource_version } }
      end

      def missing_rv?(value)
        value.nil? || value.to_s.empty?
      end

      def run_list_request(path)
        request = @api_client.build_request("GET", path, auth_names: ["BearerToken"])
        response = request.run
        return response if response.success?

        raise RequestError.from_response("Informer list failed for #{@gvk} at #{path}", response)
      end

      def watch_loop(generation)
        while running?(generation)
          # Wait for the initial List to complete: success sets @synced, an
          # exhausted retry budget sets @sync_error. Do not block forever on
          # a failed initial List (that would leave the informer inert).
          sleep 0.1 while running?(generation) && !@synced && @sync_error.nil?
          break unless running?(generation)
          break if @sync_error

          watch_once(generation)
          break unless running?(generation)

          relist(generation)
        end
      end

      # Runs a single watch from the current resourceVersion. Any break --
      # 410 Gone (stale RV), another ERROR event, HTTP error, network error,
      # or a clean server-side close -- falls through to relist, which
      # re-syncs the cache. A 410 relists immediately; every other failure
      # backs off first (honoring Retry-After when present).
      def watch_once(generation)
        watch_path = with_active_run(generation) { watch_path_for(@gvk, @resource_version) }
        return unless watch_path

        stream = WatchStream.new(@api_client)
        stream.connect(watch_path) do |event|
          with_active_run(generation) do
            handle_watch_event(event, generation)
          end
        end
      rescue WatchStream::Gone
        return unless running?(generation)

        KrubyController.logger.info("Watch for #{@gvk}: resourceVersion expired (410 Gone); relisting")
      rescue WatchStream::Error => e
        return unless running?(generation)

        KrubyController.logger.warn("Watch for #{@gvk} disconnected: #{e.message}; relisting")
        interruptible_sleep(respect_retry_after(e, 1.0), generation)
      rescue StandardError => e
        return unless running?(generation)

        KrubyController.logger.warn("Watch for #{@gvk} disconnected: #{e.message}; relisting")
        interruptible_sleep(1.0, generation)
      end

      # Classifies a watch event (issue #45). Only ADDED / MODIFIED /
      # DELETED reach the store and the handlers. BOOKMARK carries a valid
      # resourceVersion for the current state and only advances the RV —
      # nothing is stored or delivered. ERROR events raise: 410 Gone tells
      # watch_loop to relist immediately, anything else disconnects the
      # stream and backs off before relisting. Unknown or malformed events
      # are logged and ignored without touching the RV.
      def handle_watch_event(event, generation)
        obj = event["object"]
        case event["type"]
        when "ADDED", "MODIFIED", "DELETED"
          rv = obj.is_a?(Hash) ? obj.dig("metadata", "resourceVersion") : nil
          @resource_version = rv unless missing_rv?(rv)

          type = delta_type(event)
          @store.add(type, obj)
          notify(type, obj, generation)
        when "BOOKMARK"
          rv = obj.is_a?(Hash) ? obj.dig("metadata", "resourceVersion") : nil
          @resource_version = rv unless missing_rv?(rv)
        when "ERROR"
          code = obj.is_a?(Hash) ? obj["code"] : nil
          if code == 410
            raise WatchStream::Gone.new("watch resourceVersion expired (410 Gone)", code: 410)
          end

          raise WatchStream::Error.new("watch ERROR event (code: #{code.inspect})", code: code)
        else
          KrubyController.logger.warn(
            "Informer #{@gvk}: unclassified watch event type #{event["type"].inspect}; ignoring"
          )
        end
      end

      # Re-Lists the resource, replaces the store contents, and emits
      # ADDED / MODIFIED / DELETED events for the diff so controllers
      # reconcile the state that changed while the watch was down.
      def relist(generation)
        return unless running?(generation)

        resp = fetch_list
        apply_list(resp, generation)
      rescue StandardError => e
        return unless running?(generation)

        KrubyController.logger.warn("Informer relist failed for #{@gvk}: #{e.message}; retrying")
        interruptible_sleep(respect_retry_after(e, 1.0), generation)
        retry if running?(generation)
      end

      def apply_list(resp, generation, initial: false)
        with_active_run(generation) do
          old, new = @store.replace(resp["items"] || [])
          new_rv = resp.dig("metadata", "resourceVersion")
          @resource_version = new_rv unless missing_rv?(new_rv)
          emit_relist_events(old, new, generation)
          @synced = true if initial && running?(generation)
        end
      end

      def emit_relist_events(old, new, generation)
        (new.keys - old.keys).each { |key| notify(Delta::ADDED, new[key], generation) }
        (old.keys & new.keys).each do |key|
          old_rv = old[key].dig("metadata", "resourceVersion").to_s
          new_rv = new[key].dig("metadata", "resourceVersion").to_s
          notify(Delta::MODIFIED, new[key], generation) if old_rv != new_rv
        end
        (old.keys - new.keys).each { |key| notify(Delta::DELETED, old[key], generation) }
      end

      # Delivers an event to every registered handler. The delivered object
      # is an independent deep copy of the store-owned object (issue #46):
      # a handler (or a reconciler, predicate, or anything the handler
      # passes it to) may mutate the copy freely without ever corrupting the
      # cache. All handlers of one event share the single copy, so a handler
      # that mutates it is visible to the other handlers of the SAME event —
      # treat the delivered object as read-only, like controller-runtime
      # does. A handler that raises is logged and skipped so one bad handler
      # cannot suppress the remaining handlers for this event, nor the
      # events that follow it (critical during a relist, where the store
      # snapshot is already committed).
      def notify(type, obj, generation)
        delivered = Cache.deep_copy(obj)
        @handlers.each do |h|
          with_active_run(generation) { h.handle(type, delivered) }
        rescue StandardError => e
          KrubyController.logger.error("Handler for #{@gvk} failed on #{type}: #{e.message}")
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

      # Adds the optional page size and the continue token for a paged LIST
      # (issue #45). The bare path is unchanged when neither applies.
      def paged_list_path(continue)
        params = []
        params << "limit=#{@list_page_size}" if @list_page_size
        params << "continue=#{CGI.escape(continue)}" if continue
        return list_path_for(@gvk) if params.empty?

        "#{list_path_for(@gvk)}?#{params.join('&')}"
      end

      def watch_path_for(gvk, resource_version)
        "#{list_path_for(gvk)}?watch=true&resourceVersion=#{resource_version}"
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
