# frozen_string_literal: true

class GvkSpecCronTaskReconciler < KrubyController::Reconciler
  def reconcile(_request)
    KrubyController::Result.ok
  end
end

class GvkSpecCronTask
  def self.group = "stable.example.com"
  def self.version = "v1"
  def self.kind = "CronTask"
  def self.namespaced = true
end

RSpec.describe KrubyController::Manager do
  let(:manager) { described_class.new }
  let(:controllers) { manager.instance_variable_get(:@controllers) }

  describe "#add" do
    it "registers a controller for a GVK" do
      gvk = KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget")

      manager.add(GvkSpecCronTaskReconciler, for: gvk)

      expect(controllers.size).to eq(1)
      expect(controllers.first.for_gvk).to eq(gvk)
    end

    it "resolves a CRD class responding to group/version/kind" do
      manager.add(GvkSpecCronTaskReconciler, for: GvkSpecCronTask)

      expect(controllers.first.for_gvk).to eq(
        KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask")
      )
    end

    it "propagates a plural override into the GVK resource" do
      klass = Class.new do
        def self.group = "people.example.com"
        def self.version = "v1"
        def self.kind = "Person"
        def self.namespaced = true
        def self.plural = "people"
      end

      manager.add(GvkSpecCronTaskReconciler, for: klass)

      expect(controllers.first.for_gvk).to eq(
        KrubyController::GVK.new(group: "people.example.com", version: "v1", kind: "Person", resource: "people")
      )
    end

    it "resolves a Kind string with group/version options" do
      manager.add(GvkSpecCronTaskReconciler, for: "CronTask", group: "stable.example.com", version: "v1")

      expect(controllers.first.for_gvk).to eq(
        KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask")
      )
    end

    it "accepts for_gvk and max_concurrent from the builder path" do
      gvk = KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget")

      manager.add(GvkSpecCronTaskReconciler.new, for_gvk: gvk, max_concurrent: 3)

      expect(controllers.first.for_gvk).to eq(gvk)
      expect(controllers.first.instance_variable_get(:@max_concurrent)).to eq(3)
    end

    it "instantiates a reconciler class" do
      manager.add(GvkSpecCronTaskReconciler, for: KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget"))

      expect(controllers.first.reconciler).to be_a(GvkSpecCronTaskReconciler)
    end

    it "raises when a bare Kind cannot be resolved" do
      expect { manager.add(GvkSpecCronTaskReconciler, for: "CronTask") }
        .to raise_error(ArgumentError, /cannot be resolved/)
    end

    it "raises for unsupported for: values" do
      expect { manager.add(GvkSpecCronTaskReconciler, for: 42) }
        .to raise_error(ArgumentError, /must be a KrubyController::GVK/)
    end
  end

  describe "namespace option" do
    it "propagates the namespace to registered informers" do
      manager = described_class.new(namespace: "team-a")
      gvk = KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask")

      informer = manager.cache.register(gvk: gvk)

      expect(informer.instance_variable_get(:@namespace)).to eq("team-a")
    end
  end

  describe "startup failure (cache cannot sync)" do
    it "stops components and raises when the cache cannot sync (no leader election)" do
      manager = described_class.new(leader_elect: false)
      expect(manager.cache).to receive(:wait_for_sync).and_raise(KrubyController::Error.new("list failed 403"))
      expect(manager.cache).to receive(:stop)

      expect { manager.start }.to raise_error(KrubyController::Error, /403/)
    end

    it "records the startup error and signals stop under leader election" do
      manager = described_class.new(leader_elect: true)
      err = KrubyController::Error.new("sync boom")
      allow(manager).to receive(:start_and_sync).and_raise(err)
      manager.instance_variable_set(:@leader_elector, double("elector"))

      expect { manager.send(:start_leading) }.to raise_error(KrubyController::Error, /sync boom/)
      expect(manager.instance_variable_get(:@startup_error)).to be(err)
      # The stop channel was signaled so Manager#start (blocked in receive)
      # unblocks and can fail with the recorded error.
      expect(manager.instance_variable_get(:@stop_channel).receive).to eq(:stopped)
    end
  end
end
