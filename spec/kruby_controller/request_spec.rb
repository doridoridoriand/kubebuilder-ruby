# frozen_string_literal: true

RSpec.describe KrubyController::Request do
  describe "#initialize" do
    it "stores namespace and name" do
      request = described_class.new(namespace: "default", name: "cron")

      expect(request.namespace).to eq("default")
      expect(request.name).to eq("cron")
    end

    it "coerces non-string input to strings" do
      request = described_class.new(namespace: :default, name: 42)

      expect(request.namespace).to eq("default")
      expect(request.name).to eq("42")
    end
  end

  describe "#namespaced_name" do
    it "builds a NamespacedName" do
      request = described_class.new(namespace: "default", name: "cron")

      expect(request.namespaced_name).to be_a(described_class::NamespacedName)
      expect(request.namespaced_name.to_s).to eq("default/cron")
    end

    it "renders an empty namespace for cluster-scoped keys" do
      request = described_class.new(namespace: "", name: "policy")

      expect(request.namespaced_name.to_s).to eq("/policy")
    end
  end

  describe "==" do
    let(:request) { described_class.new(namespace: "default", name: "cron") }

    it "is equal for the same namespace and name" do
      expect(request).to eq(described_class.new(namespace: "default", name: "cron"))
    end

    it "is not equal when the name differs" do
      expect(request).not_to eq(described_class.new(namespace: "default", name: "other"))
    end

    it "is not equal to non-Request objects" do
      expect(request).not_to eq("default/cron")
    end

    it "is usable as a hash key and in a Set" do
      key = described_class.new(namespace: "default", name: "cron")
      hash = { key => :done }
      set = Set.new([key])

      expect(hash[described_class.new(namespace: "default", name: "cron")]).to be(:done)
      expect(set).to include(described_class.new(namespace: "default", name: "cron"))
    end
  end

  describe "#inspect" do
    it "includes the namespaced name" do
      request = described_class.new(namespace: "default", name: "cron")

      expect(request.inspect).to eq("#<Request default/cron>")
    end
  end

  describe KrubyController::Request::NamespacedName do
    subject(:name) { described_class.new("default", "cron") }

    it "exposes namespace and name" do
      expect(name.namespace).to eq("default")
      expect(name.name).to eq("cron")
    end

    it "compares by namespace and name" do
      expect(name).to eq(described_class.new("default", "cron"))
      expect(name).not_to eq(described_class.new("other", "cron"))
    end

    it "is not equal to non-NamespacedName objects" do
      expect(name).not_to eq("default/cron")
    end

    it "is usable as a hash key" do
      hash = { name => 1 }
      expect(hash[described_class.new("default", "cron")]).to eq(1)
    end
  end
end
