# frozen_string_literal: true

module KrubyController
  module Handler
    class EnqueuedObject
      def initialize(queue:)
        @queue = queue
      end

      def handle(delta_type, obj)
        ns = obj.dig("metadata", "namespace") || ""
        name = obj.dig("metadata", "name")
        return unless name
        @queue.add(KrubyController::Request.new(namespace: ns, name: name))
      end
    end
  end
end
