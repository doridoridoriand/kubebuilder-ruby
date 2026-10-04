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

  describe "#start cache sync failure" do
    let(:manager) { described_class.new(leader_elect: false, sync_timeout: 0.5) }

    # manager.start installs SIGTERM/SIGINT traps; restore defaults after.
    after do
      Signal.trap("TERM", "DEFAULT")
      Signal.trap("INT", "DEFAULT")
    end

    def fake_cache(synced)
      double(
        "cache",
        start: true,
        stop: true,
        wait_for_sync: synced,
        register: double("informer", add_handler: true)
      )
    end

    it "stops components and raises when the cache does not sync in time" do
      cache = fake_cache(false)
      manager.instance_variable_set(:@cache, cache)
      manager.add(GvkSpecCronTaskReconciler, for: KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget"))

      expect { manager.start }.to raise_error(/cache sync timed out/)
      expect(cache).to have_received(:stop)
    end

    it "propagates the sync failure as the start error on the leader path" do
      manager = described_class.new(leader_elect: true, sync_timeout: 0.5)
      manager.instance_variable_set(:@cache, fake_cache(false))
      manager.add(GvkSpecCronTaskReconciler, for: KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget"))

      fake_elector = double("elector", leading_error: nil)
      on_leading_error = nil
      allow(fake_elector).to receive(:run) do |&block|
        begin
          block.call
        rescue StandardError => e
          allow(fake_elector).to receive(:leading_error).and_return(e)
          on_leading_error&.call
        end
        fake_elector
      end
      allow(KrubyController::Election::LeaderElector).to receive(:new) do |opts|
        on_leading_error = opts[:on_leading_error]
        fake_elector
      end

      expect { manager.start }.to raise_error(/cache sync timed out/)
    end
  end
end
