# frozen_string_literal: true

require "json"
require "time"

module KrubyController
  module Cache
    # An API request failure carrying its HTTP code and optional Retry-After
    # (seconds), so callers can back off correctly (issue #45). Both the
    # informer's List path and WatchStream raise this for HTTP failures.
    class RequestError < KrubyController::Error
      attr_reader :code, :retry_after

      def initialize(message, code: nil, retry_after: nil)
        super(message)
        @code = code
        @retry_after = retry_after
      end

      # Builds the error from a raw API response object (Typhoeus-shaped:
      # #code, #headers, #status_message), picking up Retry-After when the
      # server sent one (429 and 5xx responses).
      def self.from_response(message_prefix, response)
        code = response.respond_to?(:code) ? response.code.to_i : nil
        retry_after = parse_retry_after(response)
        message = "#{message_prefix} (HTTP #{code})"
        message += ": #{response.status_message}" if response.respond_to?(:status_message) && response.status_message

        new(message, code: code, retry_after: retry_after)
      end

      # Parses a Retry-After value in either form allowed by RFC 7231: a
      # non-negative integer of seconds, or an HTTP-date. HTTP-dates are
      # converted to the remaining delay; invalid or already-past values are
      # discarded (nil) so the caller falls back to its own backoff.
      def self.parse_retry_after(response)
        headers = response.respond_to?(:headers) ? response.headers : nil
        return nil if headers.nil?

        value = headers["Retry-After"] || headers["retry-after"]
        return nil if value.nil? || value.to_s.strip.empty?

        value = value.to_s.strip
        if value.match?(/\A\d+(\.\d+)?\z/)
          delay = value.to_f
        else
          delay = Time.httpdate(value) - Time.now
        end
        delay.is_a?(Numeric) && delay.positive? ? delay : nil
      rescue StandardError
        nil
      end
    end
  end
end
