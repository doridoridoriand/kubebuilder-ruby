# frozen_string_literal: true

RSpec.describe KrubyController::GVK do
  describe "#initialize" do
    it "stores group, version and kind" do
      gvk = described_class.new(group: "stable.example.com", version: "v1", kind: "CronTask")

      expect(gvk.group).to eq("stable.example.com")
      expect(gvk.version).to eq("v1")
      expect(gvk.kind).to eq("CronTask")
    end

    it "infers the plural resource name" do
      gvk = described_class.new(group: "stable.example.com", version: "v1", kind: "CronTask")

      expect(gvk.resource).to eq("crontasks")
    end

    it "handles common pluralization rules" do
      expect(described_class.new(group: "g", version: "v1", kind: "Box").resource).to eq("boxes")
      expect(described_class.new(group: "g", version: "v1", kind: "Status").resource).to eq("statuses")
      expect(described_class.new(group: "g", version: "v1", kind: "Policy").resource).to eq("policies")
      expect(described_class.new(group: "g", version: "v1", kind: "Day").resource).to eq("days")
    end

    it "prefers an explicit resource over inference" do
      gvk = described_class.new(group: "g", version: "v1", kind: "CronTask", resource: "ctasks")

      expect(gvk.resource).to eq("ctasks")
    end

    it "coerces symbol input to strings" do
      gvk = described_class.new(group: :g, version: :v1, kind: :CronTask)

      expect(gvk.group).to eq("g")
      expect(gvk.version).to eq("v1")
      expect(gvk.kind).to eq("CronTask")
    end
  end

  describe "#namespaced?" do
    it "defaults to true" do
      expect(described_class.new(group: "g", version: "v1", kind: "K")).to be_namespaced
    end

    it "returns false when cluster scoped" do
      expect(described_class.new(group: "g", version: "v1", kind: "K", namespaced: false)).not_to be_namespaced
    end
  end

  describe "#to_s" do
    it "renders group/version and kind" do
      gvk = described_class.new(group: "stable.example.com", version: "v1", kind: "CronTask")

      expect(gvk.to_s).to eq("stable.example.com/v1, Kind=CronTask")
    end
  end

  describe "==" do
    let(:gvk) { described_class.new(group: "g", version: "v1", kind: "K") }

    it "is equal for the same identity" do
      expect(gvk).to eq(described_class.new(group: "g", version: "v1", kind: "K"))
    end

    it "is not equal when the group differs" do
      expect(gvk).not_to eq(described_class.new(group: "other", version: "v1", kind: "K"))
    end

    it "is usable as a hash key" do
      hash = { gvk => 1 }

      expect(hash[described_class.new(group: "g", version: "v1", kind: "K")]).to eq(1)
    end
  end
end
