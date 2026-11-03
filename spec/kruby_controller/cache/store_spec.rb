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

  describe "object ownership (deep copy, #46)" do
    let(:rich) do
      {
        "metadata" => { "namespace" => "default", "name" => "rich", "labels" => { "app" => "cron" } },
        "spec" => { "schedule" => "*/5 * * * *", "steps" => [{ "name" => "one" }, { "name" => "two" }] },
        "status" => { "notes" => "original" }
      }
    end

    it "isolates the ingest side: mutating the input after #add does not reach the store" do
      store.add(added, rich)
      rich["status"]["notes"] = "mutated"
      rich["spec"]["steps"] << { "name" => "three" }
      rich["metadata"]["labels"]["app"] = "changed"

      stored = store.get("default", "rich")
      expect(stored.dig("status", "notes")).to eq("original")
      expect(stored.dig("spec", "steps").size).to eq(2)
      expect(stored.dig("metadata", "labels", "app")).to eq("cron")
    end

    it "isolates the ingest side of #replace: mutating the list items does not reach the store" do
      items = [rich]
      _old, new = store.replace(items)
      items[0]["status"]["notes"] = "mutated"

      expect(store.get("default", "rich").dig("status", "notes")).to eq("original")
      expect(new["default/rich"].dig("status", "notes")).to eq("original")
    end

    it "returns an independent copy from #get: mutating it never rewrites the cache" do
      store.add(added, rich)

      first = store.get("default", "rich")
      first["status"]["notes"] = "caller-mutated"
      first["spec"]["steps"].clear

      expect(store.get("default", "rich").dig("status", "notes")).to eq("original")
      expect(store.get("default", "rich").dig("spec", "steps").size).to eq(2)
    end

    it "gives each #get its own copy" do
      store.add(added, rich)

      a = store.get("default", "rich")
      b = store.get("default", "rich")
      a["spec"]["steps"].clear

      expect(b.dig("spec", "steps").size).to eq(2)
    end

    it "returns independent copies from #list" do
      store.add(added, rich)

      first = store.list.first
      first["status"]["notes"] = "caller-mutated"

      expect(store.list.first.dig("status", "notes")).to eq("original")
    end

    it "survives concurrent readers and writers without cross-mutation" do
      names = 50.times.map { |i| "p-#{i}" }
      names.each { |n| store.add(added, item(n, "1")) }

      errors = []
      writers = 4.times.map do
        Thread.new do
          100.times do |i|
            n = names[i % names.size]
            store.add(modified, item(n, (i % 1000).to_s))
          end
        end
      end
      readers = 4.times.map do
        Thread.new do
          100.times do
            obj = store.get("default", names.sample)
            next unless obj.is_a?(Hash)

            obj["metadata"]["resourceVersion"] = "MUTATED-BY-READER"
            obj["metadata"]["labels"] = {} if obj.dig("metadata", "labels")
            obj.dig("spec", "steps")&.clear
          end
        rescue StandardError => e
          errors << e
        end
      end

      (writers + readers).each(&:join)
      expect(errors).to be_empty

      obj = store.get("default", "p-0")
      expect(obj.dig("metadata", "resourceVersion")).not_to eq("MUTATED-BY-READER")
    end

    it "copy: false returns the store-owned object (mutating it corrupts the cache)" do
      store.add(added, rich)

      raw = store.get("default", "rich", copy: false)
      expect(raw).to equal(store.get("default", "rich", copy: false)) # same object identity

      raw["status"]["notes"] = "corrupting"
      expect(store.get("default", "rich").dig("status", "notes")).to eq("corrupting")
    end

    it "copy: false on #list returns the owned objects without copying" do
      store.add(added, rich)
      store.add(added, obj_b)

      raw = store.list(copy: false)
      expect(store.list(copy: false).map(&:object_id).sort).to eq(raw.map(&:object_id).sort)
    end
  end
end
