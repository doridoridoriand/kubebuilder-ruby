# frozen_string_literal: true

require "yaml"

class CrdSpecCronTask
  include KrubyController::CRD

  self.group = "stable.example.com"
  self.version = "v1"
  self.kind = "CronTask"
  self.namespaced = true
  self.short_names = ["ct"]

  attribute :schedule, type: :string, required: true, description: "Cron 表現"
  attribute :image, type: :string, required: true, description: "コンテナーイメージ"
  attribute :replicas, type: :integer, default: 1, description: "レプリカ数"
  attribute :enabled, type: :boolean, default: true
  attribute :priority, type: :string, enum: %w[low medium high], default: "medium"
  attribute :notification, type: :object, properties: {
    channel: { type: :string },
    webhook_url: { type: :string },
  }
  attribute :labels, type: :array, items: { type: :string }

  status_attribute :last_schedule, type: :string, description: "直前のスケジュール時刻"
  status_attribute :active_job, type: :string, description: "現在実行中の Job 名"
end

class CrdSpecClusterPolicy
  include KrubyController::CRD

  self.group = "policy.example.com"
  self.version = "v1"
  self.namespaced = false

  attribute :mode, type: :string, required: true
end

class CrdSpecDerivedWidget
  include KrubyController::CRD

  self.group = "example.com"
end

RSpec.describe KrubyController::CRD do
  describe "class accessors" do
    it "exposes group, version, kind and namespaced" do
      expect(CrdSpecCronTask.group).to eq("stable.example.com")
      expect(CrdSpecCronTask.version).to eq("v1")
      expect(CrdSpecCronTask.kind).to eq("CronTask")
      expect(CrdSpecCronTask.namespaced).to be true
    end

    it "derives kind from the class name when not set" do
      expect(CrdSpecDerivedWidget.kind).to eq("CrdSpecDerivedWidget")
    end

    it "defaults version to v1 and namespaced to true" do
      klass = Class.new do
        include KrubyController::CRD
        self.group = "example.com"
        self.kind = "Widget"
      end

      expect(klass.version).to eq("v1")
      expect(klass.namespaced).to be true
    end

    it "raises when group is not set" do
      klass = Class.new do
        include KrubyController::CRD
        self.kind = "Widget"
      end

      expect { klass.group }.to raise_error(ArgumentError, /group is not set/)
    end
  end

  describe "attribute" do
    it "stores spec attributes with their options" do
      attrs = CrdSpecCronTask.spec_attributes

      expect(attrs.keys).to include(:schedule, :image, :replicas, :enabled, :priority, :notification, :labels)
      expect(attrs[:schedule].required?).to be true
      expect(attrs[:schedule].description).to eq("Cron 表現")
      expect(attrs[:replicas].default).to eq(1)
      expect(attrs[:priority].enum).to eq(%w[low medium high])
    end

    it "stores status attributes separately" do
      attrs = CrdSpecCronTask.status_attributes

      expect(attrs.keys).to eq(%i[last_schedule active_job])
      expect(attrs[:last_schedule].type).to eq(:string)
    end

    it "normalizes nested properties and array items to CRDAttribute" do
      notification = CrdSpecCronTask.spec_attributes[:notification]
      expect(notification.properties[:channel]).to be_a(KrubyController::CRDAttribute)
      expect(notification.properties[:channel].type).to eq(:string)

      labels = CrdSpecCronTask.spec_attributes[:labels]
      expect(labels.items).to be_a(KrubyController::CRDAttribute)
      expect(labels.items.type).to eq(:string)
    end

    it "does not share attribute hashes with subclasses" do
      child = Class.new(CrdSpecCronTask) do
        self.kind = "CronTaskChild"
        attribute :extra, type: :string
      end

      child.spec_attributes[:extra]
      expect(CrdSpecCronTask.spec_attributes.key?(:extra)).to be false
      expect(child.spec_attributes).not_to equal(CrdSpecCronTask.spec_attributes)
    end
  end

  describe KrubyController::Generator::CrdGenerator do
    subject(:crd) { described_class.new(CrdSpecCronTask).generate }

    it "generates the CRD metadata and names" do
      expect(crd["apiVersion"]).to eq("apiextensions.k8s.io/v1")
      expect(crd["kind"]).to eq("CustomResourceDefinition")
      expect(crd["metadata"]["name"]).to eq("crontasks.stable.example.com")

      names = crd["spec"]["names"]
      expect(names["plural"]).to eq("crontasks")
      expect(names["kind"]).to eq("CronTask")
      expect(names["shortNames"]).to eq(["ct"])
    end

    it "generates scope from namespaced" do
      expect(crd["spec"]["scope"]).to eq("Namespaced")
      expect(described_class.new(CrdSpecClusterPolicy).generate["spec"]["scope"]).to eq("Cluster")
    end

    it "generates the spec and status schemas" do
      properties = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]
      spec_schema = properties["spec"]

      expect(spec_schema["properties"]["schedule"]["description"]).to eq("Cron 表現")
      expect(spec_schema["properties"]["replicas"]["default"]).to eq(1)
      expect(spec_schema["properties"]["priority"]["enum"]).to eq(%w[low medium high])
      expect(spec_schema["properties"]["labels"]).to eq("type" => "array", "items" => { "type" => "string" })
      expect(spec_schema["properties"]["notification"]["properties"]["channel"]).to eq("type" => "string")
      expect(spec_schema["required"]).to match_array(%w[schedule image])

      status_schema = properties["status"]
      expect(status_schema["properties"]["last_schedule"]["description"]).to eq("直前のスケジュール時刻")
    end

    it "uses the plural override when set" do
      klass = Class.new do
        include KrubyController::CRD
        self.group = "example.com"
        self.kind = "Box"
        self.plural = "boxes"
      end

      expect(described_class.new(klass).generate["metadata"]["name"]).to eq("boxes.example.com")
    end

    it "preserves outer metadata on object attributes with properties" do
      klass = Class.new do
        include KrubyController::CRD
        self.group = "example.com"
        self.kind = "Widget"
        attribute :notification, type: :object, description: "通知先", properties: {
          channel: { type: :string },
        }
      end

      properties = described_class.new(klass).generate["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]
      notification = properties["spec"]["properties"]["notification"]

      expect(notification["type"]).to eq("object")
      expect(notification["description"]).to eq("通知先")
      expect(notification["properties"]).to eq("channel" => { "type" => "string" })
    end

    it "produces YAML matching the generated structure" do
      yaml = described_class.new(CrdSpecCronTask).generate_yaml

      expect(YAML.safe_load(yaml)).to eq(crd)
    end
  end

  describe "integration with Manager#add" do
    it "resolves a CRD class into a GVK" do
      reconciler = Class.new(KrubyController::Reconciler) do
        def reconcile(_request)
          KrubyController::Result.ok
        end
      end
      manager = KrubyController::Manager.new

      manager.add(reconciler, for: CrdSpecCronTask)

      controller = manager.instance_variable_get(:@controllers).first
      expect(controller.for_gvk).to eq(
        KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask")
      )
    end
  end
end
