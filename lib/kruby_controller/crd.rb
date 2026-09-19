# frozen_string_literal: true

module KrubyController
  # A single attribute of a CRD schema (spec or status field).
  class CRDAttribute
    attr_reader :name, :type, :default, :description, :enum, :properties, :items

    def initialize(name, type:, required: false, default: nil, description: nil, enum: nil, properties: nil, items: nil)
      @name = name
      @type = type
      @required = required
      @default = default
      @description = description
      @enum = enum
      @properties = normalize_properties(properties)
      @items = items.is_a?(Hash) ? self.class.new(name, **items) : items
    end

    def required?
      @required
    end

    def to_h
      {
        type: @type,
        required: @required,
        default: @default,
        description: @description,
        enum: @enum,
        properties: @properties,
        items: @items
      }
    end

    private

    def normalize_properties(properties)
      return nil unless properties.is_a?(Hash)

      properties.transform_values { |opts| self.class.new(nil, **opts) }
    end
  end

  # DSL for declaring a custom resource definition schema.
  #
  #   class CronTask
  #     include KrubyController::CRD
  #
  #     self.group = "stable.example.com"
  #     self.version = "v1"
  #     self.kind = "CronTask"
  #     self.namespaced = true
  #
  #     attribute :schedule, type: :string, required: true, description: "Cron expression"
  #     attribute :replicas, type: :integer, default: 1
  #     status_attribute :last_schedule, type: :string, description: "Last scheduled time"
  #   end
  module CRD
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def group=(value)
        @group = value
      end

      def group
        raise ArgumentError, "CRD group is not set for #{name}" if @group.nil?

        @group
      end

      def version=(value)
        @version = value
      end

      def version
        @version || "v1"
      end

      def kind=(value)
        @kind = value
      end

      def kind
        @kind || name.to_s.split("::").last
      end

      def namespaced=(value)
        @namespaced = value
      end

      def namespaced
        return true if @namespaced.nil?

        @namespaced
      end

      def plural=(value)
        @plural = value
      end

      def plural
        @plural
      end

      def short_names=(value)
        @short_names = value
      end

      def short_names
        @short_names
      end

      def attribute(attr_name, **options)
        spec_attributes[attr_name] = CRDAttribute.new(attr_name, **options)
      end

      def status_attribute(attr_name, **options)
        status_attributes[attr_name] = CRDAttribute.new(attr_name, **options)
      end

      def spec_attributes
        @spec_attributes ||= inherited_attributes(:spec_attributes)
      end

      def status_attributes
        @status_attributes ||= inherited_attributes(:status_attributes)
      end

      private

      def inherited_attributes(accessor)
        return {} unless superclass.respond_to?(accessor)

        superclass.public_send(accessor).dup
      end
    end
  end
end
