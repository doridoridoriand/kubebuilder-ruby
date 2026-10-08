# frozen_string_literal: true

BuilderSpecCronTaskGVK = KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask",
                                                  resource: "crontasks")
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

class BuilderSpecBlockingReconciler < KrubyController::Reconciler
  def initialize
    @count = 0
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @first_reconcile_started = false
    @release_first_reconcile = false
  end

  def reconcile(_request)
    first_reconcile = @mutex.synchronize do
      @count += 1
      @first_reconcile_started = true if @count == 1
      @condition.broadcast
      @count == 1
    end

    return KrubyController::Result.ok unless first_reconcile

    @mutex.synchronize do
      @condition.wait(@mutex) until @release_first_reconcile
    end
    KrubyController::Result.ok
  end

  def wait_until_first_reconcile_starts(timeout: 2)
    wait_until(timeout) { @first_reconcile_started }
  end

  def wait_until_count(count, timeout: 2)
    wait_until(timeout) { @count >= count }
  end

  def release_first_reconcile
    @mutex.synchronize do
      @release_first_reconcile = true
      @condition.broadcast
    end
  end

  private

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @mutex.synchronize do
      until yield
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if remaining <= 0

        @condition.wait(@mutex, remaining)
      end
      true
    end
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
        h.handle(KrubyController::Cache::Delta::ADDED,
                 { "metadata" => { "namespace" => "default", "name" => "cron-a" } })
      end

      expect(wait_until_reconciled(["default/cron-a"])).to include("default/cron-a")
    end
  end

  describe "owns:" do
    let(:controller) do
      described_class.new(reconciler: reconciler, cache: cache, for_gvk: BuilderSpecCronTaskGVK,
                          owns: [BuilderSpecJobGVK])
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

    it "reconciles the parent again when a child changes while the parent is in flight" do
      blocking = BuilderSpecBlockingReconciler.new
      blocking_controller = described_class.new(
        reconciler: blocking,
        cache: cache,
        for_gvk: BuilderSpecCronTaskGVK,
        owns: [BuilderSpecJobGVK]
      )
      blocking_controller.start
      begin
        job = {
          "metadata" => {
            "namespace" => "default",
            "name" => "job-3",
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

        # The first reconcile explicitly blocks, establishing that the
        # second event is received while its parent is in flight.
        expect(blocking.wait_until_first_reconcile_starts).to be(true)
        handlers_for(BuilderSpecJobGVK).each { |h| h.handle(KrubyController::Cache::Delta::MODIFIED, job) }
        blocking.release_first_reconcile

        expect(blocking.wait_until_count(2)).to be(true)
      ensure
        blocking.release_first_reconcile
        blocking_controller.stop
      end
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
                 { "metadata" => { "namespace" => "default", "name" => "keep",
                                   "labels" => { "managed-by" => "cron" } } })
        h.handle(KrubyController::Cache::Delta::ADDED,
                 { "metadata" => { "namespace" => "default", "name" => "drop",
                                   "labels" => { "managed-by" => "other" } } })
      end

      reconciled = wait_until_reconciled(["default/keep"])
      expect(reconciled).to include("default/keep")
      sleep 0.2
      expect(reconciler.reconciled_names).not_to include("default/drop")
    end
  end

  describe "reconcile error backoff" do
    let(:limiter) { KrubyController::Queue::ExponentialBackoffRateLimiter.new(base: 0.05, max: 0.5) }

    def enqueue_failure(name)
      handlers_for(BuilderSpecCronTaskGVK).each do |h|
        h.handle(KrubyController::Cache::Delta::ADDED, { "metadata" => { "namespace" => "default", "name" => name } })
      end
    end

    def poll_until(timeout: 3)
      deadline = Time.now + timeout
      sleep 0.01 until deadline <= Time.now || yield
    end

    it "requeues a raising reconcile with growing exponential backoff" do
      failing = Class.new(KrubyController::Reconciler) do
        def initialize
          super
          @attempts = []
          @mutex = Mutex.new
        end

        def reconcile(_request)
          @mutex.synchronize { @attempts << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          raise "boom"
        end

        def attempts
          @mutex.synchronize { @attempts.dup }
        end
      end.new
      controller = described_class.new(
        reconciler: failing, cache: cache, for_gvk: BuilderSpecCronTaskGVK, rate_limiter: limiter
      )
      controller.start
      begin
        enqueue_failure("fail-1")
        poll_until { failing.attempts.size >= 3 && limiter.failures("default/fail-1") >= 3 }

        t0, t1, t2 = failing.attempts
        expect(t1 - t0).to be >= 0.04 # first backoff: base (50ms)
        expect(t2 - t1).to be >= 0.09 # second backoff: 2 * base (100ms)
        expect(limiter.failures("default/fail-1")).to be >= 3
      ensure
        controller.stop
      end
    end

    it "resets the backoff counter after a successful reconcile" do
      seen = 0
      flaky = Class.new(KrubyController::Reconciler) do
        define_method(:reconcile) do |_request|
          seen += 1
          raise "boom" if seen < 3

          KrubyController::Result.ok
        end
      end.new
      controller = described_class.new(
        reconciler: flaky, cache: cache, for_gvk: BuilderSpecCronTaskGVK, rate_limiter: limiter
      )
      controller.start
      begin
        enqueue_failure("flaky-1")
        poll_until { seen >= 3 && limiter.failures("default/flaky-1").zero? }

        expect(seen).to eq(3)
        expect(limiter.failures("default/flaky-1")).to eq(0)
      ensure
        controller.stop
      end
    end

    it "treats a result carrying an error as a failure (rate-limited requeue)" do
      r = Class.new(KrubyController::Reconciler) do
        def reconcile(_request)
          KrubyController::Result.requeue(error: StandardError.new("transient"))
        end
      end.new
      controller = described_class.new(reconciler: r, cache: cache, for_gvk: BuilderSpecCronTaskGVK,
                                       rate_limiter: limiter)
      controller.start
      begin
        enqueue_failure("err-1")
        poll_until { limiter.failures("default/err-1") >= 2 }

        expect(limiter.failures("default/err-1")).to be >= 2
      ensure
        controller.stop
      end
    end

    it "requeues a plain Requeue immediately without touching the backoff counter" do
      seen = 0
      r = Class.new(KrubyController::Reconciler) do
        define_method(:reconcile) do |_request|
          seen += 1
          seen < 3 ? KrubyController::Result.requeue : KrubyController::Result.ok
        end
      end.new
      controller = described_class.new(reconciler: r, cache: cache, for_gvk: BuilderSpecCronTaskGVK,
                                       rate_limiter: limiter)
      controller.start
      begin
        enqueue_failure("rq-1")
        poll_until { seen >= 3 }

        expect(seen).to eq(3)
        expect(limiter.failures("default/rq-1")).to eq(0)
      ensure
        controller.stop
      end
    end

    describe "#handle_result (forget on successful requeue)" do
      let(:hr_controller) do
        described_class.new(reconciler: reconciler, cache: cache, for_gvk: BuilderSpecCronTaskGVK,
                            rate_limiter: limiter)
      end
      let(:request) { KrubyController::Request.new(namespace: "default", name: "hr") }
      let(:key) { "default/hr" }

      it "resets the failure streak on an error-free RetryAfter" do
        2.times { limiter.backoff(key) }
        expect(limiter.failures(key)).to eq(2)

        hr_controller.send(:handle_result, KrubyController::Result.retry_after(1), request, key)

        expect(limiter.failures(key)).to eq(0)
      end

      it "resets the failure streak on an error-free Requeue" do
        2.times { limiter.backoff(key) }

        hr_controller.send(:handle_result, KrubyController::Result.requeue, request, key)

        expect(limiter.failures(key)).to eq(0)
      end

      it "rate-limits a RetryAfter that carries an error" do
        2.times { limiter.backoff(key) }

        hr_controller.send(
          :handle_result,
          KrubyController::Result.retry_after(1, error: StandardError.new("boom")), request, key
        )

        expect(limiter.failures(key)).to eq(3)
      end
    end

    describe "#clear_failure_on_shutdown?" do
      let(:c) do
        described_class.new(reconciler: reconciler, cache: cache, for_gvk: BuilderSpecCronTaskGVK,
                            rate_limiter: limiter)
      end

      it "clears the history for a clean Ok" do
        expect(c.send(:clear_failure_on_shutdown?, false, KrubyController::Result.ok)).to be(true)
      end

      it "clears the history for an error-free RetryAfter / Requeue" do
        expect(c.send(:clear_failure_on_shutdown?, false, KrubyController::Result.retry_after(1))).to be(true)
        expect(c.send(:clear_failure_on_shutdown?, false, KrubyController::Result.requeue)).to be(true)
      end

      it "does NOT clear when the reconcile raised" do
        expect(c.send(:clear_failure_on_shutdown?, true, KrubyController::Result.ok)).to be(false)
      end

      it "does NOT clear when the result carries an error" do
        requeue_err = KrubyController::Result.requeue(error: StandardError.new("x"))
        retry_err = KrubyController::Result.retry_after(1, error: StandardError.new("x"))

        expect(c.send(:clear_failure_on_shutdown?, false, requeue_err)).to be(false)
        expect(c.send(:clear_failure_on_shutdown?, false, retry_err)).to be(false)
      end
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
                 .watches(BuilderSpecConfigMapGVK, predicate: ->(_o) { true })
                 .with_max_concurrent_reconciles(3)
                 .with_predicate(->(_o) { true })
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
                   .watches(configmap_class, predicate: ->(_o) { true })
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
