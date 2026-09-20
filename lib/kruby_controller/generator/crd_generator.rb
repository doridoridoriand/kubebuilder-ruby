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
      def plural
        return @klass.plural if @klass.respond_to?(:plural) && @klass.plural

        default_plural
      end

      def default_plural
        word = kind.downcase
        if word.end_with?("s", "x", "z", "ch", "sh")
          "#{word}es"
        elsif word.end_with?("y") && !%w[a e i o u].include?(word[-2])
          "#{word[0..-2]}ies"
        else
          "#{word}s"
        end
      end

      def names_spec
        names = { "plural" => plural, "singular" => kind.downcase, "kind" => kind }
        if @klass.respond_to?(:short_names) && @klass.short_names
          names["shortNames"] = @klass.short_names
        end
        names
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
        properties = {}
        attrs.each { |name, attr| properties[name.to_s] = attribute_to_schema(attr) }
        schema = { "type" => "object", "properties" => properties }
        required = attrs.select { |_k, v| v.required? }.keys.map(&:to_s)
        schema["required"] = required unless required.empty?
        schema
      end

      def attribute_to_schema(attr)
        schema = if attr.type == :object && attr.properties
          build_schema(attr.properties)
        else
          { "type" => TYPE_MAP[attr.type] || "string" }.tap do |s|
            s["items"] = attribute_to_schema(attr.items) if attr.respond_to?(:items) && attr.items
          end
        end

        schema["description"] = attr.description if attr.respond_to?(:description) && attr.description
        schema["default"] = attr.default if attr.respond_to?(:default) && !attr.default.nil?
        schema["enum"] = attr.enum if attr.respond_to?(:enum) && attr.enum
        schema
      end
    end
  end
end
