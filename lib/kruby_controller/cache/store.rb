# frozen_string_literal: true

module KrubyController
  module Cache
    # The store owns an independent deep copy of every object it holds
    # (issue #46): both the ingest side (the object passed to #add /
    # #replace belongs to the caller afterwards and may be mutated or
    # reused without affecting the cache) and the outbound side (#get /
    # #list return a deep copy by default, so a caller mutation can never
    # rewrite the cache before an API write). Copying is the default and
    # the only behavior that protects the cache; +copy: false+ hands back
    # the store-owned object for hot paths where the caller only reads it
    # and does not retain it — mutating a +copy: false+ result WILL corrupt
    # the cache (and be visible to every other reader), so that opt-out
    # must never be used by code that mutates.
    class Store
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      def add(delta_type, obj)
        key = namespace_name_key(obj)
        stored = Cache.deep_copy(obj)
        @mutex.synchronize do
          case delta_type
          when Delta::ADDED, Delta::MODIFIED
            @store[key] = stored
          when Delta::DELETED
            @store.delete(key)
          end
        end
      end

      def get(namespace, name, copy: true)
        @mutex.synchronize do
          obj = @store["#{namespace}/#{name}"]
          return nil if obj.nil?

          copy ? Cache.deep_copy(obj) : obj
        end
      end

      def list(label_selector: nil, copy: true)
        @mutex.synchronize do
          results = @store.values
          results = results.select { |obj| matches_label_selector?(obj, label_selector) } if label_selector
          copy ? results.map { |obj| Cache.deep_copy(obj) } : results
        end
      end

      # Atomically replaces the store contents with +items+ (a fresh List
      # result; the store takes an independent deep copy of each item) and
      # returns the [old, new] key -> object maps so the caller can emit
      # ADDED / MODIFIED / DELETED events for the diff. Both maps hold
      # store-owned objects, never the caller's input objects.
      def replace(items)
        @mutex.synchronize do
          old = @store
          new_store = {}
          items.each do |item|
            stored = Cache.deep_copy(item)
            new_store[namespace_name_key(item)] = stored
          end
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
