# frozen_string_literal: true

require "json"

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

      def self.parse_retry_after(response)
        headers = response.respond_to?(:headers) ? response.headers : nil
        return nil if headers.nil?

        value = headers["Retry-After"]
        return nil if value.nil? || value.to_s.empty?

        seconds = value.to_f
        seconds.positive? ? seconds : nil
      rescue StandardError
        nil
      end
    end
  end
end
