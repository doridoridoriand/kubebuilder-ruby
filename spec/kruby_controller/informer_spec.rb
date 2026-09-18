# frozen_string_literal: true

InformerGVK = Struct.new(:group, :version, :kind, :resource)

RSpec.describe KrubyController::Cache::Informer do
  let(:gvk) { InformerGVK.new("stable.example.com", "v1", "CronTask", "crontasks") }
  let(:store) { KrubyController::Cache::Store.new }
  let(:response) { double("response") }
  let(:request) { double("request", run: response) }
  let(:api_client) { instance_double(Kubernetes::ApiClient, build_request: request) }
  let(:informer) { described_class.new(gvk: gvk, store: store, api_client: api_client) }

  describe "#populate" do
    context "when list succeeds" do
      let(:response) do
        double(
          "response",
          success?: true,
          code: 200,
          status_message: "OK",
          body: {
            "items" => [
              { "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "100" } },
              { "metadata" => { "namespace" => "default", "name" => "b", "resourceVersion" => "101" } }
            ],
            "metadata" => { "resourceVersion" => "101" }
          }.to_json
        )
      end

      it "stores all items and marks the informer as synced" do
        informer.send(:populate)

        expect(store.get("default", "a")).to be_a(Hash)
        expect(store.get("default", "b")).to be_a(Hash)
        expect(informer.synced).to be true
      end

      it "tracks the list resourceVersion" do
        informer.send(:populate)

        expect(informer.instance_variable_get(:@resource_version)).to eq("101")
      end

      it "requests the namespaced list path with bearer auth" do
        expect(api_client).to receive(:build_request)
          .with("GET", "/apis/stable.example.com/v1/crontasks", auth_names: ["BearerToken"])
          .and_return(request)

        informer.send(:populate)
      end
    end

    context "when list fails" do
      let(:response) do
        double("response", success?: false, code: 403, status_message: "Forbidden", body: "{}")
      end

      it "raises an error containing the HTTP status" do
        expect { informer.send(:populate) }.to raise_error(StandardError, /list failed.*403/)
        expect(informer.synced).to be false
      end
    end
  end

  describe "list path resolution" do
    it "uses /api for core resources" do
      core_gvk = InformerGVK.new("", "v1", "Pod", "pods")
      informer = described_class.new(gvk: core_gvk, store: store, api_client: api_client)

      expect(informer.send(:list_path_for, core_gvk)).to eq("/api/v1/pods")
    end

    it "uses /apis for group-scoped resources" do
      expect(informer.send(:list_path_for, gvk)).to eq("/apis/stable.example.com/v1/crontasks")
    end
  end
end
