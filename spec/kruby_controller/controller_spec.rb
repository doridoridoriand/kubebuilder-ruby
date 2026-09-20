# frozen_string_literal: true

BuilderSpecCronTaskGVK = KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
BuilderSpecJobGVK = KrubyController::GVK.new(group: "batch", version: "v1", kind: "Job", resource: "jobs")
BuilderSpecConfigMapGVK = KrubyController::GVK.new(group: "", version: "v1", kind: "ConfigMap", resource: "configmaps")

class BuilderSpecReconciler < KrubyController::Reconciler
  attr_reader :recorded

  def initialize
    @recorded = []
    @mutex = Mutex.new
  end

  def reconcile(request)
    @mutex.synchronize { @recorded << request }
    KrubyController::Result.ok
  end

  def reconciled_names
    @mutex.synchronize { @recorded.map(&:namespaced_name).map(&:to_s) }
  end
end

RSpec.describe KrubyController::Controller do
  let(:cache) { KrubyController::Cache::SharedCache.new }
  let(:reconciler) { BuilderSpecReconciler.new }
  let(:controller) do
    described_class.new(reconciler: reconciler, cache: cache, for_gvk: BuilderSpecCronTaskGVK)
  end
  let(:queue) { controller.instance_variable_get(:@queue) }

  def handlers_for(gvk)
    cache.register(gvk: gvk).instance_variable_get(:@handlers)
  end

  def wait_until_reconciled(expect_names, timeout: 2)
    deadline = Time.now + timeout
    sleep 0.02 while Time.now < deadline && expect_names.none? { |n| reconciler.reconciled_names.include?(n) }
    reconciler.reconciled_names
  end

  def wait_idle(timeout: 0.3)
    deadline = Time.now + timeout
    sleep 0.02 while Time.now < deadline
    reconciler.reconciled_names
  end

  after { controller.stop }

  describe "#start handler registration" do
    it "registers an EnqueuedObject handler on the for-gvk informer" do
      controller.start

      expect(handlers_for(BuilderSpecCronTaskGVK)).to contain_exactly(a_kind_of(KrubyController::Handler::EnqueuedObject))
    end

    it "reconciles the object itself when it changes" do
      controller.start
      handlers_for(BuilderSpecCronTaskGVK).each do |h|
        h.handle(KrubyController::Cache::Delta::ADDED, { "metadata" => { "namespace" => "default", "name" => "cron-a" } })
      end

      expect(wait_until_reconciled(["default/cron-a"])).to include("default/cron-a")
    end
  end

  describe "owns:" do
    let(:controller) do
      described_class.new(reconciler: reconciler, cache: cache, for_gvk: BuilderSpecCronTaskGVK, owns: [BuilderSpecJobGVK])
    end

    it "registers an EnqueuedOwner handler on each owned gvk informer" do
      controller.start

      expect(handlers_for(BuilderSpecJobGVK)).to contain_exactly(a_kind_of(KrubyController::Handler::EnqueuedOwner))
    end

    it "reconciles the parent cron task when a job it owns changes" do
      controller.start
      job = {
        "metadata" => {
          "namespace" => "default",
          "name" => "job-1",
          "ownerReferences" => [
            {
              "apiVersion" => "stable.example.com/v1",
              "kind" => "CronTask",
              "name" => "cron-a",
              "uid" => "uid-a",
              "controller" => true
            }
          ]
        }
      }
      handlers_for(BuilderSpecJobGVK).each { |h| h.handle(KrubyController::Cache::Delta::MODIFIED, job) }

      expect(wait_until_reconciled(["default/cron-a"])).to include("default/cron-a")
    end

    it "does not reconcile when the ownerReference is not a controller reference" do
      controller.start
      job = {
        "metadata" => {
          "namespace" => "default",
          "name" => "job-2",
          "ownerReferences" => [
            {
              "apiVersion" => "stable.example.com/v1",
              "kind" => "CronTask",
              "name" => "cron-b",
              "uid" => "uid-b",
              "controller" => false
            }
          ]
        }
      }
      handlers_for(BuilderSpecJobGVK).each { |h| h.handle(KrubyController::Cache::Delta::MODIFIED, job) }

      expect(wait_idle).to be_empty
    end
  end

  describe "watches:" do
    let(:controller) do
      described_class.new(
        reconciler: reconciler,
        cache: cache,
        for_gvk: BuilderSpecCronTaskGVK,
        watches: [
          { gvk: BuilderSpecConfigMapGVK, predicate: ->(o) { o.dig("metadata", "labels", "managed-by") == "cron" } }
        ]
      )
    end

    it "reconciles watched objects that pass the predicate" do
      controller.start
      cm = { "metadata" => { "namespace" => "default", "name" => "cm-1", "labels" => { "managed-by" => "cron" } } }
      handlers_for(BuilderSpecConfigMapGVK).each { |h| h.handle(KrubyController::Cache::Delta::ADDED, cm) }

      expect(wait_until_reconciled(["default/cm-1"])).to include("default/cm-1")
    end

    it "does not reconcile watched objects that fail the predicate" do
      controller.start
      cm = { "metadata" => { "namespace" => "default", "name" => "cm-2", "labels" => { "managed-by" => "other" } } }
      handlers_for(BuilderSpecConfigMapGVK).each { |h| h.handle(KrubyController::Cache::Delta::ADDED, cm) }

      expect(wait_idle).to be_empty
    end

    it "supports a custom handler on a watch" do
      captured = []
      custom = Object.new
      custom.define_singleton_method(:handle) { |delta_type, obj| captured << [delta_type, obj] }

      custom_controller = described_class.new(
        reconciler: reconciler,
        cache: cache,
        for_gvk: BuilderSpecCronTaskGVK,
        watches: [{ gvk: BuilderSpecConfigMapGVK, handler: custom }]
      )
      custom_controller.start
      cm = { "metadata" => { "namespace" => "default", "name" => "cm-3" } }
      handlers_for(BuilderSpecConfigMapGVK).each { |h| h.handle(KrubyController::Cache::Delta::DELETED, cm) }
      custom_controller.stop

      expect(captured).to eq([[KrubyController::Cache::Delta::DELETED, cm]])
    end
  end

  describe "predicate: (for-gvk)" do
    let(:controller) do
      described_class.new(
        reconciler: reconciler,
        cache: cache,
        for_gvk: BuilderSpecCronTaskGVK,
        predicate: ->(o) { o.dig("metadata", "labels", "managed-by") == "cron" }
      )
    end

    it "filters events on the for-gvk informer" do
      controller.start
      handlers_for(BuilderSpecCronTaskGVK).each do |h|
        h.handle(KrubyController::Cache::Delta::ADDED,
                 { "metadata" => { "namespace" => "default", "name" => "keep", "labels" => { "managed-by" => "cron" } } })
        h.handle(KrubyController::Cache::Delta::ADDED,
                 { "metadata" => { "namespace" => "default", "name" => "drop", "labels" => { "managed-by" => "other" } } })
      end

      reconciled = wait_until_reconciled(["default/keep"])
      expect(reconciled).to include("default/keep")
      sleep 0.2
      expect(reconciler.reconciled_names).not_to include("default/drop")
    end
  end
end

RSpec.describe KrubyController::Builder::ControllerBuilder do
  let(:manager) { KrubyController::Manager.new }
  let(:reconciler) { BuilderSpecReconciler.new }
  let(:informers) { manager.cache.instance_variable_get(:@informers) }

  it "wires owns / watches / predicate / max_concurrent end to end (fluent API)" do
    controller = manager
      .for(BuilderSpecCronTaskGVK)
      .owns(BuilderSpecJobGVK)
      .watches(BuilderSpecConfigMapGVK, predicate: ->(o) { true })
      .with_max_concurrent_reconciles(3)
      .with_predicate(->(o) { true })
      .complete_with(reconciler)

    expect(controller.for_gvk).to eq(BuilderSpecCronTaskGVK)
    expect(controller.instance_variable_get(:@max_concurrent)).to eq(3)
    expect(controller.instance_variable_get(:@owns)).to eq([BuilderSpecJobGVK])
    expect(controller.instance_variable_get(:@watches).map { |w| w[:gvk] }).to eq([BuilderSpecConfigMapGVK])
    expect(controller.instance_variable_get(:@predicate)).to be_a(Proc)

    controller.start
    expect(informers.keys).to contain_exactly(
      BuilderSpecCronTaskGVK.to_s, BuilderSpecJobGVK.to_s, BuilderSpecConfigMapGVK.to_s
    )
    controller.stop
  end

  context "with CRD classes as secondary targets (documented fluent form)" do
    let(:job_class) do
      Class.new do
        include KrubyController::CRD
        self.group = "batch"
        self.version = "v1"
        self.kind = "Job"
      end
    end
    let(:configmap_class) do
      Class.new do
        include KrubyController::CRD
        self.group = ""
        self.version = "v1"
        self.kind = "ConfigMap"
      end
    end

    it "normalizes owned/watched CRD classes into GVKs before registration" do
      controller = manager
        .for(BuilderSpecCronTaskGVK)
        .owns(job_class)
        .watches(configmap_class, predicate: ->(o) { true })
        .complete_with(reconciler)

      owns = controller.instance_variable_get(:@owns)
      watch_gvks = controller.instance_variable_get(:@watches).map { |w| w[:gvk] }

      expect(owns).to eq([KrubyController::GVK.new(group: "batch", version: "v1", kind: "Job", resource: "jobs")])
      expect(watch_gvks).to eq(
        [KrubyController::GVK.new(group: "", version: "v1", kind: "ConfigMap", resource: "configmaps")]
      )
      owns.each { |gvk| expect(gvk).to respond_to(:resource) }
      watch_gvks.each { |gvk| expect(gvk).to respond_to(:resource) }
    end

    it "registers informers keyed by the normalized GVKs" do
      controller = manager
        .for(BuilderSpecCronTaskGVK)
        .owns(job_class)
        .complete_with(reconciler)

      controller.start
      expect(informers.keys).to contain_exactly(BuilderSpecCronTaskGVK.to_s, "batch/v1, Kind=Job")
      controller.stop
    end
  end
end
