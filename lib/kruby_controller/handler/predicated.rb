# frozen_string_literal: true

module KrubyController
  module Handler
    # Wraps another handler and only forwards events whose object
    # satisfies the predicate. The predicate is a callable that receives
    # the event object and returns a truthy value to pass it through.
    class Predicated
      def initialize(handler:, predicate:)
        @handler = handler
        @predicate = predicate
      end

      def handle(delta_type, obj)
        return unless @predicate.call(obj)

        @handler.handle(delta_type, obj)
      end
    end
  end
end
