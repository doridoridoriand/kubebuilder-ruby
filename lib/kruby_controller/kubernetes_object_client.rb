# frozen_string_literal: true

require "json"

module KrubyController
  # Adapter over a raw Kubernetes::ApiClient that exposes the two write verbs the
  # helper modules (FinalizerManager / StatusUpdater) need: a full-object
  # replace (`update`) and a `/status` subresource patch (`patch_status`).
  #
  # It exists because kruby's CustomObjectsApi does not offer a PUT `update` and
  # its `patch_*` methods are hardwired to `application/json-patch+json` (a
  # JSON-Patch *array* body), which cannot carry a full object. Building the
  # requests directly on the ApiClient (the same path Informer uses) lets us
  # pick the correct verb and content type per operation.
  #
  # Pass an instance as the `client:` for FinalizerManager / StatusUpdater:
  #
  #   api_client = Kubernetes::ApiClient.new(config)
  #   client = KrubyController::KubernetesObjectClient.new(api_client: api_client, gvk: gvk)
  #   fm = KrubyController::Finalizer::FinalizerManager.new(client: client, gvk: gvk)
  #   su = KrubyController::Status::StatusUpdater.new(client: client, gvk: gvk)
  class KubernetesObjectClient
    def initialize(api_client:, gvk:)
      @api_client = api_client
      @gvk = gvk
    end

    # Replace the object on the server (PUT, application/json).
    def update(obj)
      send_object("PUT", object_path(obj), obj, "application/json")
    end

    # Patch only the `/status` subresource (PATCH, merge-patch).
    def patch_status(obj)
      send_object("PATCH", "#{object_path(obj)}/status", obj, "application/merge-patch+json")
    end

    private

    def object_path(obj)
      name = obj.dig("metadata", "name")
      raise KrubyController::Error, "object has no metadata.name" if name.nil? || name.empty?

      base = @gvk.group.to_s.empty? ? "/api" : "/apis/#{@gvk.group}"
      [base, @gvk.version, namespace_segment(obj, name), @gvk.resource, name].compact.join("/")
    end

    def namespace_segment(obj, name)
      return nil unless @gvk.namespaced?

      namespace = obj.dig("metadata", "namespace")
      if namespace.nil? || namespace.empty?
        raise KrubyController::Error, "namespaced object '#{name}' has no metadata.namespace"
      end

      "namespaces/#{namespace}"
    end

    def send_object(method, path, obj, content_type)
      request = @api_client.build_request(
        method,
        path,
        header_params: { "Content-Type" => content_type },
        body: obj.to_json,
        auth_names: ["BearerToken"]
      )
      response = request.run
      unless response.success?
        raise KrubyController::Error,
              "#{method} #{path} failed (HTTP #{response.code}): #{response.status_message}"
      end

      body = response.body
      body.nil? || body.empty? ? nil : JSON.parse(body)
    end
  end
end
