# frozen_string_literal: true

module KrubyController
  module Handler
    class EnqueuedOwner
      def initialize(queue:, owner_gvk:)
        @queue = queue
        @owner_gvk = owner_gvk
      end

      def handle(delta_type, obj)
        (obj.dig("metadata", "ownerReferences") || []).each do |owner|
          next unless owner["kind"] == @owner_gvk.kind
          @queue.add(KrubyController::Request.new(
            namespace: obj.dig("metadata", "namespace") || "",
            name: owner["name"]
          ))
        end
      end
    end
  end
end
