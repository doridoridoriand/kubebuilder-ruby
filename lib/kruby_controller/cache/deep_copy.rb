# frozen_string_literal: true

module KrubyController
  module Cache
    # Deep-copies JSON-shaped object trees so the cache and its consumers
    # never share a mutable object (issue #46).
    #
    # Policy: Hash, Array and String are copied recursively (string keys are
    # copied too). nil / true / false / Numeric / Symbol are immutable and
    # are passed through. Any other object (e.g. a kruby resource class
    # instance) is passed through UNCOPIED — the framework's informers
    # deliver JSON-shaped Hashes (parsed per event / per List), so sharing a
    # non-JSON object is a by-convention read-only case, not a copy target.
    #
    # Measured on Ruby 3.4.4 (M2 MacBook): ~12µs for a typical CRD object
    # (~1.3KB of JSON-shaped data), ~23µs for a ~1MB configmap payload.
    module_function

    def deep_copy(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), copy| copy[deep_copy(k)] = deep_copy(v) }
      when Array
        obj.map { |v| deep_copy(v) }
      when String
        obj.dup
      else
        obj
      end
    end
  end
end
