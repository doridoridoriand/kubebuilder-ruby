# frozen_string_literal: true

module KrubyController
  module Cache
    class Store
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      def add(delta_type, obj)
        key = namespace_name_key(obj)
        @mutex.synchronize do
          case delta_type
          when Delta::ADDED, Delta::MODIFIED
            @store[key] = obj
          when Delta::DELETED
            @store.delete(key)
          end
        end
      end

      def get(namespace, name)
        @mutex.synchronize { @store["#{namespace}/#{name}"] }
      end

      def list(label_selector: nil)
        @mutex.synchronize do
          results = @store.values
          return results unless label_selector

          results.select { |obj| matches_label_selector?(obj, label_selector) }
        end
      end

      # Atomically replaces the store contents with +items+ (a fresh List
      # result) and returns the [old, new] key -> object maps so the caller
      # can emit ADDED / MODIFIED / DELETED events for the diff.
      def replace(items)
        @mutex.synchronize do
          old = @store
          new_store = {}
          items.each { |item| new_store[namespace_name_key(item)] = item }
          @store = new_store
          [old, new_store]
        end
      end

      private

      def namespace_name_key(source)
        if source.is_a?(Hash)
          ns = source.dig("metadata", "namespace") || ""
          name = source.dig("metadata", "name")
        else
          ns = source.metadata.namespace || ""
          name = source.metadata.name
        end
        "#{ns}/#{name}"
      end

      def matches_label_selector?(obj, selector)
        labels = obj.is_a?(Hash) ? obj.dig("metadata", "labels") || {} : {}
        selector.split(",").all? do |pair|
          key, value = pair.split("=")
          labels[key] == value
        end
      end
    end
  end
end
