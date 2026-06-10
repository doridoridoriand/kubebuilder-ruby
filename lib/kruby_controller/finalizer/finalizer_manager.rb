# frozen_string_literal: true

module KrubyController
  module Finalizer
    class FinalizerManager
      def initialize(client:, gvk:)
        @client = client
        @gvk = gvk
      end

      def add_finalizer(obj, finalizer)
        return if has_finalizer?(obj, finalizer)
        (obj["metadata"]["finalizers"] ||= []) << finalizer
        @client.update(obj)
      end

      def remove_finalizer(obj, finalizer)
        obj["metadata"]["finalizers"]&.delete(finalizer)
        @client.update(obj)
      end

      def has_finalizer?(obj, finalizer)
        (obj.dig("metadata", "finalizers") || []).include?(finalizer)
      end

      def deleting?(obj)
        !obj.dig("metadata", "deletionTimestamp").to_s.empty?
      end
    end
  end
end
