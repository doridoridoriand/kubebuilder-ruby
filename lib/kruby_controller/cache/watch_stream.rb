# frozen_string_literal: true

require "json"

module KrubyController
  module Cache
    # A minimal watch stream over the framework's ApiClient: one HTTP
    # connection, newline-delimited JSON events, no automatic reconnection.
    #
    # It exists because kruby's Kubernetes::Watch reconnects internally on a
    # 410 Gone — resetting the resourceVersion and watching from "now" —
    # which silently drops every event between the stale RV and the
    # reconnect. This stream yields EVERY parsed event (including ERROR and
    # BOOKMARK events — classification is the informer's responsibility, so
    # it raises WatchStream::Error subclasses from its event handler and
    # this stream surfaces them after the transfer completes) and leaves all
    # reconnection policy to the informer.
    class WatchStream
      # A watch request failure. +code+ is the HTTP code, +retry_after+ the
      # server's Retry-After in seconds.
      class Error < RequestError; end

      # A 410 Gone: the resourceVersion the watch started from is no longer
      # served. The informer must relist from a fresh LIST.
      class Gone < Error; end

      # Typhoeus: 0 disables the total timeout so an idle watch stream is
      # not killed mid-poll (the connection-establishment timeout still
      # applies).
      WATCH_IDLE_TIMEOUT = 0

      def initialize(api_client)
        @api_client = api_client
      end

      # Streams watch events from +path+ (which carries the resourceVersion
      # query). Yields each parsed event Hash — including ERROR and
      # BOOKMARK events; classification is the informer's responsibility.
      # Raises Error for non-200 responses (with Retry-After when present)
      # and transport failures, and surfaces WatchStream::Error subclasses
      # raised by the event handler after the transfer completes. A clean
      # server-side close returns normally once the buffered tail (an event
      # without its trailing newline) has been processed.
      def connect(path)
        request = @api_client.build_request("GET", path, auth_names: ["BearerToken"])
        request.options[:timeout] = WATCH_IDLE_TIMEOUT

        buffer = +""
        error = nil
        headers_seen = nil
        request.on_headers { |headers| headers_seen = headers }
        request.on_body do |chunk|
          next if error
          next if chunk.nil?
          next if headers_seen && !success_code?(headers_seen)

          buffer << chunk
          lines, buffer = split_complete_lines(buffer)
          lines.each do |line|
            event = parse_event(line)
            next unless event

            begin
              yield event
            rescue WatchStream::Error => e
              # Classified errors (410 Gone, ERROR events) surface after the
              # transfer completes, so the HTTP machinery is never left in a
              # half-aborted state.
              error = e
              break
            end
          end
        end

        response = request.run
        raise error if error

        check_response(response, headers_seen)
        event = parse_event(buffer)
        yield event if event
      end

      private

      def success_code?(headers_or_response)
        code = headers_or_response.code.to_i
        (200..299).cover?(code)
      end

      def check_response(response, headers_seen)
        source = response || headers_seen
        return if source.nil? || success_code?(source)

        raise WatchStream::Error.from_response("Watch request failed", source)
      end

      # Splits +buffer+ into the complete newline-terminated lines and the
      # remainder that is still waiting for its newline.
      def split_complete_lines(buffer)
        index = buffer.rindex("\n")
        return [[], buffer] unless index

        [buffer[0..index].split("\n"), buffer[(index + 1)..]]
      end

      def parse_event(line)
        return nil if line.nil? || line.strip.empty?

        event = JSON.parse(line)
        return nil unless event.is_a?(Hash)

        event
      rescue JSON::ParserError => e
        KrubyController.logger.warn("WatchStream: failed to parse watch event: #{e.message}")
        nil
      end
    end
  end
end
