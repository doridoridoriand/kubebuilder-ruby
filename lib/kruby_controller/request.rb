# frozen_string_literal: true

module KrubyController
  class Request
    attr_reader :namespace, :name

    def initialize(namespace:, name:)
      @namespace = namespace.to_s
      @name = name.to_s
    end

    def namespaced_name
      NamespacedName.new(@namespace, @name)
    end

    def ==(other)
      return false unless other.is_a?(Request)

      @namespace == other.namespace && @name == other.name
    end
    alias eql? ==

    def hash
      [@namespace, @name].hash
    end

    def inspect
      "#<Request #{namespaced_name}>"
    end

    class NamespacedName
      attr_reader :namespace, :name

      def initialize(namespace, name)
        @namespace = namespace
        @name = name
      end

      def to_s
        "#{@namespace}/#{@name}"
      end

      def hash
        [@namespace, @name].hash
      end

      def ==(other)
        return false unless other.is_a?(NamespacedName)

        @namespace == other.namespace && @name == other.name
      end
      alias eql? ==

      def inspect
        "NamespacedName(#{self})"
      end
    end
  end
end
