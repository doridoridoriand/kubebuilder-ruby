# frozen_string_literal: true

RSpec.describe KrubyController::Cache::Store do
  def item(name, rev, namespace: "default")
    { "metadata" => { "namespace" => namespace, "name" => name, "resourceVersion" => rev } }
  end

  describe "#add / #get / #list" do
    it "stores and deletes objects by namespace/name" do
      store = described_class.new
      store.add(KrubyController::Cache::Delta::ADDED, item("a", "1"))
      store.add(KrubyController::Cache::Delta::DELETED, item("a", "1"))

      expect(store.get("default", "a")).to be_nil
      expect(store.list).to be_empty
    end

    it "filters list by label selector" do
      store = described_class.new
      keep = { "metadata" => { "namespace" => "default", "name" => "a", "labels" => { "app" => "cron" } } }
      drop = { "metadata" => { "namespace" => "default", "name" => "b", "labels" => { "app" => "other" } } }
      store.add(KrubyController::Cache::Delta::ADDED, keep)
      store.add(KrubyController::Cache::Delta::ADDED, drop)

      expect(store.list(label_selector: "app=cron").map { |o| o.dig("metadata", "name") }).to eq(["a"])
    end
  end

  describe "#replace" do
    it "replaces the contents and returns the old and new maps" do
      store = described_class.new
      store.add(KrubyController::Cache::Delta::ADDED, item("a", "1"))
      store.add(KrubyController::Cache::Delta::ADDED, item("b", "2"))

      old, new = store.replace([item("b", "3"), item("c", "4")])

      expect(old.keys).to match_array(%w[default/a default/b])
      expect(new.keys).to match_array(%w[default/b default/c])
      expect(store.get("default", "a")).to be_nil
      expect(store.get("default", "b").dig("metadata", "resourceVersion")).to eq("3")
      expect(store.get("default", "c")).to be_a(Hash)
    end

    it "accepts an empty list, emptying the store" do
      store = described_class.new
      store.add(KrubyController::Cache::Delta::ADDED, item("a", "1"))

      _old, new = store.replace([])

      expect(new).to be_empty
      expect(store.list).to be_empty
    end
  end
end
