# frozen_string_literal: true

RSpec.describe KrubyController::KubernetesObjectClient do
  let(:gvk) do
    KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
  end
  let(:core_gvk) { KrubyController::GVK.new(group: "", version: "v1", kind: "Pod", resource: "pods") }
  let(:cluster_gvk) do
    KrubyController::GVK.new(
      group: "policy.example.com", version: "v1", kind: "Policy", resource: "policies", namespaced: false
    )
  end
  let(:api_client) { instance_double(Kubernetes::ApiClient) }
  let(:request) { double("request") }
  let(:success_body) { { "metadata" => { "name" => "a" } }.to_json }
  let(:response) { double("response", success?: true, code: 200, status_message: "OK", body: success_body) }

  let(:namespaced_obj) do
    {
      "apiVersion" => "stable.example.com/v1",
      "kind" => "CronTask",
      "metadata" => { "name" => "a", "namespace" => "default", "resourceVersion" => "100" },
      "spec" => { "schedule" => "*/5 * * * *" }
    }
  end

  let(:client) { described_class.new(api_client: api_client, gvk: gvk) }

  def expect_request(method, path, content_type, body)
    expect(api_client).to receive(:build_request)
      .with(method, path,
            header_params: { "Content-Type" => content_type },
            body: body,
            auth_names: ["BearerToken"])
      .and_return(request)
  end

  describe "#update" do
    it "replaces a namespaced object via PUT with the namespaced path and json content type" do
      expect_request(
        "PUT",
        "/apis/stable.example.com/v1/namespaces/default/crontasks/a",
        "application/json",
        namespaced_obj.to_json
      )
      allow(request).to receive(:run).and_return(response)

      result = client.update(namespaced_obj)
      expect(result).to eq("metadata" => { "name" => "a" })
    end

    it "uses the /api path for core-group resources" do
      core_client = described_class.new(api_client: api_client, gvk: core_gvk)
      pod = { "metadata" => { "name" => "p", "namespace" => "default" } }

      expect_request("PUT", "/api/v1/namespaces/default/pods/p", "application/json", pod.to_json)
      allow(request).to receive(:run).and_return(response)

      core_client.update(pod)
    end

    it "omits the namespaces segment for cluster-scoped resources" do
      cluster_client = described_class.new(api_client: api_client, gvk: cluster_gvk)
      policy = { "metadata" => { "name" => "x" } }

      expect_request("PUT", "/apis/policy.example.com/v1/policies/x", "application/json", policy.to_json)
      allow(request).to receive(:run).and_return(response)

      cluster_client.update(policy)
    end

    it "raises when the object has no metadata.name" do
      expect { client.update({ "metadata" => {} }) }.to raise_error(KrubyController::Error, /no metadata\.name/)
    end

    it "raises for a namespaced object without metadata.namespace" do
      expect { client.update({ "metadata" => { "name" => "a" } }) }
        .to raise_error(KrubyController::Error, /no metadata\.namespace/)
    end

    it "raises with the HTTP status when the request fails" do
      allow(api_client).to receive(:build_request).and_return(request)
      failed = double("response", success?: false, code: 409, status_message: "Conflict", body: "")
      allow(request).to receive(:run).and_return(failed)

      expect { client.update(namespaced_obj) }.to raise_error(KrubyController::Error, /PUT.*409/)
    end
  end

  describe "#patch_status" do
    it "patches the /status subresource via merge-patch" do
      expect_request(
        "PATCH",
        "/apis/stable.example.com/v1/namespaces/default/crontasks/a/status",
        "application/merge-patch+json",
        namespaced_obj.to_json
      )
      allow(request).to receive(:run).and_return(response)

      result = client.patch_status(namespaced_obj)
      expect(result).to eq("metadata" => { "name" => "a" })
    end

    it "patches cluster-scoped status without a namespace segment" do
      cluster_client = described_class.new(api_client: api_client, gvk: cluster_gvk)
      policy = { "metadata" => { "name" => "x" } }

      expect_request(
        "PATCH",
        "/apis/policy.example.com/v1/policies/x/status",
        "application/merge-patch+json",
        policy.to_json
      )
      allow(request).to receive(:run).and_return(response)

      cluster_client.patch_status(policy)
    end

    it "returns nil when the server responds with an empty body" do
      allow(api_client).to receive(:build_request).and_return(request)
      empty = double("response", success?: true, code: 200, status_message: "OK", body: "")
      allow(request).to receive(:run).and_return(empty)

      expect(client.patch_status(namespaced_obj)).to be_nil
    end
  end

  describe "as the client for the helper modules" do
    it "satisfies FinalizerManager#add_finalizer (update interface)" do
      fm = KrubyController::Finalizer::FinalizerManager.new(client: client, gvk: gvk)
      obj = namespaced_obj.dup

      expect(api_client).to receive(:build_request)
        .with("PUT", "/apis/stable.example.com/v1/namespaces/default/crontasks/a",
              hash_including(header_params: { "Content-Type" => "application/json" }))
        .and_return(request)
      allow(request).to receive(:run).and_return(response)

      fm.add_finalizer(obj, "crontask.example.com/finalizer")
      expect(obj.dig("metadata", "finalizers")).to include("crontask.example.com/finalizer")
    end

    it "satisfies StatusUpdater#update_status (patch_status interface)" do
      su = KrubyController::Status::StatusUpdater.new(client: client, gvk: gvk)
      obj = namespaced_obj.dup

      expect(api_client).to receive(:build_request)
        .with("PATCH", "/apis/stable.example.com/v1/namespaces/default/crontasks/a/status",
              hash_including(header_params: { "Content-Type" => "application/merge-patch+json" }))
        .and_return(request)
      allow(request).to receive(:run).and_return(response)

      su.update_status(obj, { "phase" => "Running" })
    end
  end
end
