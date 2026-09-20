# frozen_string_literal: true

module KrubyController
  module Handler
    # Enqueues the parent object when an owned object changes.
    #
    # Only ownerReferences with `controller: true` are considered, and the
    # reference must match the owner GVK by both apiVersion and kind
    # (kind alone would let a same-kind owner from another API group through).
    class EnqueuedOwner
      def initialize(queue:, owner_gvk:)
        @queue = queue
        @owner_gvk = owner_gvk
      end

      def handle(delta_type, obj)
        (obj.dig("metadata", "ownerReferences") || []).each do |owner|
          next unless owner["controller"] == true
          next unless owner_matches?(owner)

          @queue.add(KrubyController::Request.new(
            namespace: obj.dig("metadata", "namespace") || "",
            name: owner["name"]
          ))
        end
      end

      private

      def owner_matches?(owner)
        owner["kind"] == @owner_gvk.kind && owner["apiVersion"] == api_version
      end

      def api_version
        group = @owner_gvk.group.to_s
        group.empty? ? @owner_gvk.version : "#{group}/#{@owner_gvk.version}"
      end
    end
  end
end
