# frozen_string_literal: true

module KrubyController
  module Handler
    # Enqueues the parent object when an owned object changes.
    #
    # Only ownerReferences with `controller: true` are considered, and the
    # reference must match the owner GVK by both apiVersion and kind
    # (kind alone would let a same-kind owner from another API group through).
    #
    # The enqueued request carries the OWNER's namespace: for a namespaced
    # owner that is the child's namespace, but a cluster-scoped owner lives
    # under the empty namespace, so the child's namespace must not leak in.
    class EnqueuedOwner
      def initialize(queue:, owner_gvk:, owner_namespaced: true)
        @queue = queue
        @owner_gvk = owner_gvk
        @owner_namespaced = owner_namespaced
      end

      def handle(delta_type, obj)
        (obj.dig("metadata", "ownerReferences") || []).each do |owner|
          next unless owner["controller"] == true
          next unless owner_matches?(owner)

          @queue.add(KrubyController::Request.new(
            namespace: owner_namespace(obj),
            name: owner["name"]
          ))
        end
      end

      private

      def owner_matches?(owner)
        owner["kind"] == @owner_gvk.kind && owner["apiVersion"] == api_version
      end

      def owner_namespace(obj)
        return "" unless @owner_namespaced

        obj.dig("metadata", "namespace") || ""
      end

      def api_version
        group = @owner_gvk.group.to_s
        group.empty? ? @owner_gvk.version : "#{group}/#{@owner_gvk.version}"
      end
    end
  end
end
