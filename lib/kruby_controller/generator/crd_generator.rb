# frozen_string_literal: true

require "yaml"

module KrubyController
  module Generator
    class CrdGenerator
      TYPE_MAP = {
        string: "string", integer: "integer", float: "number",
        boolean: "boolean", object: "object", array: "array",
      }.freeze

      def initialize(klass)
        @klass = klass
      end

      def generate
        {
          "apiVersion" => "apiextensions.k8s.io/v1",
          "kind" => "CustomResourceDefinition",
          "metadata" => { "name" => "#{plural}.#{group}" },
          "spec" => {
            "group" => group,
            "names" => names_spec,
            "scope" => (@klass.respond_to?(:namespaced) && @klass.namespaced) ? "Namespaced" : "Cluster",
            "versions" => [version_spec],
          },
        }
      end

      def generate_yaml
        YAML.dump(generate)
      end

      private

      def group; @klass.group; end
      def version; @klass.version; end
      def kind; @klass.kind; end
      def plural; kind.downcase + "s"; end

      def names_spec
        { "plural" => plural, "singular" => kind.downcase, "kind" => kind }
      end

      def version_spec
        {
          "name" => version,
          "served" => true,
          "storage" => true,
          "subresources" => { "status" => {} },
          "schema" => {
            "openAPIV3Schema" => {
              "type" => "object",
              "properties" => { "spec" => spec_schema, "status" => status_schema },
            },
          },
        }
      end

      def spec_schema; build_schema(@klass.spec_attributes); end
      def status_schema; build_schema(@klass.status_attributes); end

      def build_schema(attrs)
        return {} unless attrs
        {
          "type" => "object",
          "properties" => attrs.transform_values { |a| attribute_to_schema(a) },
          "required" => attrs.select { |_k, v| v.required? }.keys,
        }
      end

      def attribute_to_schema(attr)
        schema = { "type" => TYPE_MAP[attr.type] || "string" }
        schema["description"] = attr.description if attr.respond_to?(:description) && attr.description
        schema["default"] = attr.default if attr.respond_to?(:default) && !attr.default.nil?
        schema["enum"] = attr.enum if attr.respond_to?(:enum) && attr.enum
        schema["properties"] = build_schema(attr.properties) if attr.respond_to?(:properties) && attr.properties
        schema["items"] = attribute_to_schema(attr.items) if attr.respond_to?(:items) && attr.items
        schema
      end
    end
  end
end
