# frozen_string_literal: true

module KrubyController
  module Status
    class StatusUpdater
      def initialize(client:, gvk:)
        @client = client
        @gvk = gvk
      end

      def update_status(obj, status_patch)
        patched = deep_merge(obj, { "status" => status_patch })
        @client.patch_status(patched)
      end

      def merge_status(obj, status_update)
        current = obj.dig("status") || {}
        merged = deep_merge(current, status_update)
        update_status(obj, merged)
      end

      private

      def deep_merge(h1, h2)
        h1.merge(h2) { |_k, o, n| o.is_a?(Hash) && n.is_a?(Hash) ? deep_merge(o, n) : n }
      end
    end
  end
end
