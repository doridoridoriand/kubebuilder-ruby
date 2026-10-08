# frozen_string_literal: true

RSpec.describe KrubyController::Cache::Store do
  subject(:store) { described_class.new }

  let(:obj_a) { { "metadata" => { "namespace" => "default", "name" => "a" } } }
  let(:obj_b) { { "metadata" => { "namespace" => "default", "name" => "b" } } }
  let(:added) { KrubyController::Cache::Delta::ADDED }
  let(:modified) { KrubyController::Cache::Delta::MODIFIED }
  let(:deleted) { KrubyController::Cache::Delta::DELETED }
  let(:bookkeeper) { KrubyController::Cache::Delta::BOOKKEEPER }

  def item(name, rev, namespace: "default")
    { "metadata" => { "namespace" => namespace, "name" => name, "resourceVersion" => rev } }
  end

  describe "#add" do
    it "stores an object on ADDED" do
      store.add(added, obj_a)

      expect(store.get("default", "a")).to eq(obj_a)
    end

    it "replaces an existing object on MODIFIED" do
      store.add(added, obj_a)
      updated = { "metadata" => { "namespace" => "default", "name" => "a", "resourceVersion" => "2" } }
      store.add(modified, updated)

      expect(store.get("default", "a")).to eq(updated)
    end

    it "removes the object on DELETED" do
      store.add(added, obj_a)
      store.add(deleted, obj_a)

      expect(store.get("default", "a")).to be_nil
    end

    it "ignores BOOKKEEPER deltas" do
      store.add(added, obj_a)
      store.add(bookkeeper, obj_a)

      expect(store.get("default", "a")).to eq(obj_a)
      expect(store.list.size).to eq(1)
    end

    it "keys cluster-scoped objects by an empty namespace" do
      cluster = { "metadata" => { "name" => "policy" } }
      store.add(added, cluster)

      expect(store.get("", "policy")).to eq(cluster)
    end
  end

  describe "#get" do
    it "returns nil for a missing object" do
      expect(store.get("default", "nope")).to be_nil
    end
  end

  describe "#list" do
    before do
      store.add(added, obj_a)
      store.add(added, obj_b)
    end

    it "returns all stored objects" do
      expect(store.list.size).to eq(2)
    end

    it "filters by a single label selector" do
      labeled = { "metadata" => { "namespace" => "d", "name" => "x", "labels" => { "app" => "cron" } } }
      store.add(added, labeled)

      expect(store.list(label_selector: "app=cron").map { |o| o.dig("metadata", "name") }).to eq(["x"])
    end

    it "filters by multiple comma-separated labels" do
      match = { "metadata" => { "namespace" => "d", "name" => "m", "labels" => { "app" => "cron", "tier" => "web" } } }
      partial = { "metadata" => { "namespace" => "d", "name" => "p", "labels" => { "app" => "cron" } } }
      store.add(added, match)
      store.add(added, partial)

      expect(store.list(label_selector: "app=cron,tier=web").map { |o| o.dig("metadata", "name") }).to eq(["m"])
    end

    it "returns an empty list when nothing matches the selector" do
      expect(store.list(label_selector: "app=missing")).to eq([])
    end
  end

  describe "#replace" do
    it "replaces the contents and returns the old and new maps" do
      store.add(added, item("a", "1"))
      store.add(added, item("b", "2"))

      old, new = store.replace([item("b", "3"), item("c", "4")])

      expect(old.keys).to match_array(%w[default/a default/b])
      expect(new.keys).to match_array(%w[default/b default/c])
      expect(store.get("default", "a")).to be_nil
      expect(store.get("default", "b").dig("metadata", "resourceVersion")).to eq("3")
      expect(store.get("default", "c")).to be_a(Hash)
    end

    it "accepts an empty list, emptying the store" do
      store.add(added, item("a", "1"))

      _old, new = store.replace([])

      expect(new).to be_empty
      expect(store.list).to be_empty
    end
  end
end
