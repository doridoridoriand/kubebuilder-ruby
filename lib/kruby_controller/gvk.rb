# frozen_string_literal: true

module KrubyController
  # Group/Version/Kind identifier for a Kubernetes resource type.
  #
  #   GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask")
  #   # => resource inferred as "crontasks"
  #
  # Value object: compared by group/version/kind/resource/namespaced.
  class GVK
    attr_reader :group, :version, :kind, :resource

    def initialize(group:, version:, kind:, resource: nil, namespaced: true)
      @group = group.to_s
      @version = version.to_s
      @kind = kind.to_s
      @resource = (resource || infer_resource).to_s
      @namespaced = namespaced
    end

    def namespaced?
      @namespaced
    end

    def to_s
      "#{@group}/#{@version}, Kind=#{@kind}"
    end

    def ==(other)
      other.is_a?(GVK) &&
        [group, version, kind, resource, namespaced?] ==
          [other.group, other.version, other.kind, other.resource, other.namespaced?]
    end
    alias eql? ==

    def hash
      [group, version, kind, resource, namespaced?].hash
    end

    def inspect
      "#<KrubyController::GVK #{self} namespaced=#{@namespaced}>"
    end

    private

    def infer_resource
      singular = kind.downcase
      if singular.end_with?("s", "x", "z", "ch", "sh")
        "#{singular}es"
      elsif singular.end_with?("y") && !VOWELS.include?(singular[-2])
        "#{singular[0..-2]}ies"
      else
        "#{singular}s"
      end
    end

    VOWELS = %w[a e i o u].freeze
  end
end
