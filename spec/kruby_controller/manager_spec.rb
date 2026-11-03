# frozen_string_literal: true

require "timeout"

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

# Records each reconcile with the cache-sync state and leadership state at
# that moment, so the manager specs can assert that no reconcile ran against
# a partially synced cache or without the lease.
class SyncGateSpecReconciler < KrubyController::Reconciler
  attr_accessor :watched_informer, :manager

  def initialize
    @mutex = Mutex.new
    @reconciled = []
  end

  def reconcile(request)
    @mutex.synchronize do
      @reconciled << {
        name: request.namespaced_name.to_s,
        other_synced: watched_informer&.synced,
        leader: manager&.leader?
      }
    end
    KrubyController::Result.ok
  end

  def reconciled
    @mutex.synchronize { @reconciled.dup }
  end
end

# Records the first reconcile entry and then blocks, so the manager specs
# can prove stop returns within its drain budget while a reconcile is
# unresponsive.
class BlockingSyncSpecReconciler < KrubyController::Reconciler
  def initialize
    @mutex = Mutex.new
    @entered = false
  end

  def reconcile(_request)
    @mutex.synchronize { @entered = true }
    sleep 3
    KrubyController::Result.ok
  end

  def entered?
    @mutex.synchronize { @entered }
  end
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

      allow(manager.cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
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

    it "stops components and raises when the cache times out without syncing (no leader election)" do
      manager = described_class.new(leader_elect: false)
      expect(manager.cache).to receive(:wait_for_sync).and_return(false)
      expect(manager.cache).to receive(:stop)

      expect { manager.start }.to raise_error(KrubyController::Error, /did not sync/)
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

    it "propagates exhausted List retries through leader election and releases the lease" do
      manager = described_class.new(leader_elect: true, retry_period: 0.01)
      lease = Kubernetes::V1Lease.build_from_hash(
        metadata: { name: "test-lock", namespace: "kube-system" },
        spec: { leaseDurationSeconds: 15 }
      )
      client = double("coordination client", read_namespaced_lease: lease, replace_namespaced_lease: lease)
      allow(manager).to receive(:coordination_client).and_return(client)
      allow(manager).to receive(:setup_signal_handlers)
      allow(manager.cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
      informer = manager.cache.register(gvk: KrubyController::GVK.new(group: "g", version: "v1", kind: "Widget"))
      error = KrubyController::Error.new("List failed (HTTP 403)")
      allow(informer).to receive(:fetch_list).and_raise(error)
      allow(informer).to receive(:interruptible_sleep)

      expect { Timeout.timeout(3) { manager.start } }.to raise_error(KrubyController::Error) do |raised|
        expect(raised).to be(error)
      end

      expect(informer).to have_received(:fetch_list).exactly(4).times
      expect(informer.synced).to be false
      expect(manager.leader?).to be false
      expect(lease.spec.holder_identity).to be_nil
      elector = manager.instance_variable_get(:@leader_elector)
      expect(elector.instance_variable_get(:@thread).alive?).to be false
    ensure
      manager&.stop
    end

    it "propagates a cache sync timeout through leader election and stops controllers" do
      manager = described_class.new(leader_elect: true, retry_period: 0.01)
      lease = Kubernetes::V1Lease.build_from_hash(metadata: {}, spec: { leaseDurationSeconds: 15 })
      client = double("coordination client", read_namespaced_lease: lease, replace_namespaced_lease: lease)
      allow(manager).to receive(:coordination_client).and_return(client)
      allow(manager).to receive(:setup_signal_handlers)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller
      allow(manager.cache).to receive(:wait_for_sync).and_return(false)

      expect { Timeout.timeout(3) { manager.start } }.to raise_error(KrubyController::Error, /did not sync/)

      # Workers must never start against a cache that did not sync (FR-03):
      # only registration happens before the sync wait.
      expect(controller).to have_received(:register).once
      expect(controller).not_to have_received(:start)
      expect(controller).to have_received(:stop).at_least(:once)
      expect(manager.leader?).to be false
      expect(lease.spec.holder_identity).to be_nil
    ensure
      manager&.stop
    end
  end

  describe "worker start after cache sync (#52)" do
    let(:crontask_gvk) do
      KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
    end
    let(:widget_gvk) do
      KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "Widget", resource: "widgets")
    end

    it "starts workers only after every informer is synced (FR-03)" do
      manager = described_class.new(leader_elect: false)
      allow(manager.cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      allow(fake_watch).to receive(:connect).and_raise(KrubyController::Error, "test watch closed")

      informer_crontask = manager.cache.register(gvk: crontask_gvk)
      informer_widget = manager.cache.register(gvk: widget_gvk)
      allow(informer_crontask).to receive(:fetch_list).and_return(
        { "items" => [{ "metadata" => { "namespace" => "default", "name" => "cron-1" } }],
          "metadata" => { "resourceVersion" => "1" } }
      )
      gate = ::Queue.new
      widget_list_started = { value: false }
      allow(informer_widget).to receive(:fetch_list) do
        widget_list_started[:value] = true
        gate.pop
        { "items" => [{ "metadata" => { "namespace" => "default", "name" => "w-1" } }],
          "metadata" => { "resourceVersion" => "2" } }
      end

      reconciler = SyncGateSpecReconciler.new
      reconciler.watched_informer = informer_widget
      manager.add(reconciler, for: crontask_gvk)
      manager.add(reconciler, for: widget_gvk)

      runner = Thread.new { manager.start }
      deadline = Time.now + 5
      sleep 0.05 until widget_list_started[:value] || Time.now >= deadline
      expect(widget_list_started[:value]).to be(true)

      # While the widget informer is still listing its initial state, no
      # reconcile may run, even though the cron-task informer already synced.
      sleep 0.4
      expect(reconciler.reconciled).to be_empty

      gate << :go
      deadline = Time.now + 5
      sleep 0.05 until reconciler.reconciled.size >= 2 || Time.now >= deadline

      # After the sync completes, the initial objects are processed and every
      # reconcile observed a fully synced cache.
      expect(reconciler.reconciled.map { |r| r[:name] }).to contain_exactly("default/cron-1", "default/w-1")
      expect(reconciler.reconciled.map { |r| r[:other_synced] }).to all(be(true))
      expect(informer_crontask.synced).to be(true)
      expect(informer_widget.synced).to be(true)
    ensure
      manager&.stop
    end

    it "does not start workers when a stop is requested during the sync wait" do
      manager = described_class.new(leader_elect: false)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller
      expect(manager.cache).to receive(:wait_for_sync) do
        deadline = Time.now + 5
        sleep 0.02 while !manager.instance_variable_get(:@stopped) && Time.now < deadline
        false
      end

      done = ::Queue.new
      Thread.new { manager.start; done << :done }
      sleep 0.2 # let the startup thread reach the sync wait
      manager.stop
      Timeout.timeout(3) { done.pop }

      expect(controller).not_to have_received(:start)
      expect(controller).to have_received(:stop).at_least(:once)
    end

    it "registers and starts nothing when the manager is already stopped" do
      manager = described_class.new(leader_elect: false)
      allow(manager.cache).to receive(:start)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller
      manager.instance_variable_set(:@stopped, true)

      expect { manager.start }.not_to raise_error

      expect(controller).not_to have_received(:register)
      expect(manager.cache).not_to have_received(:start)
    end

    it "does not start workers when leadership is lost during the sync wait" do
      manager = described_class.new(leader_elect: true)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller
      allow(manager.cache).to receive(:wait_for_sync).and_return(true)
      # The elector flags the loss (leader? -> false) before its
      # on_stopped_leading cleanup runs; the sync wait itself may still
      # complete successfully.
      allow(manager).to receive(:leader?).and_return(false)

      expect { manager.send(:start_and_sync) }.not_to raise_error

      expect(controller).to have_received(:register).once
      expect(controller).not_to have_received(:start)
      expect(controller).to have_received(:stop).at_least(:once)
    end

    it "starts workers when leadership is still held after the sync wait" do
      manager = described_class.new(leader_elect: true)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller
      allow(manager.cache).to receive(:wait_for_sync).and_return(true)
      allow(manager).to receive(:leader?).and_return(true)

      expect { manager.send(:start_and_sync) }.not_to raise_error

      expect(controller).to have_received(:register).once
      expect(controller).to have_received(:start).once
    end

    it "buffers resync events emitted during the reacquisition sync wait" do
      manager = described_class.new(leader_elect: true, retry_period: 0.01)
      lease = Kubernetes::V1Lease.build_from_hash(
        metadata: { name: "test-lock", namespace: "kube-system" },
        spec: { leaseDurationSeconds: 15 }
      )
      client = double("coordination client", read_namespaced_lease: lease, replace_namespaced_lease: lease)
      allow(manager).to receive(:coordination_client).and_return(client)
      allow(manager).to receive(:setup_signal_handlers)
      allow(manager.cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
      # A parked watch thread cannot be interrupted; keep the bounded join
      # from inflating the spec when the informer is stopped between
      # leadership generations.
      stub_const("KrubyController::Cache::Informer::STOP_JOIN_TIMEOUT", 0.05)
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      # Park the watch in connect so no relist races the lifecycle handover;
      # events flow only through the initial List of each generation.
      allow(fake_watch).to receive(:connect) { sleep }

      informer = manager.cache.register(gvk: crontask_gvk)
      current = { "items" => [{ "metadata" => { "namespace" => "default", "name" => "cron-1" } }],
                  "metadata" => { "resourceVersion" => "1" } }
      allow(informer).to receive(:fetch_list) { current }

      reconciler = SyncGateSpecReconciler.new
      reconciler.watched_informer = informer
      reconciler.manager = manager
      manager.add(reconciler, for: crontask_gvk)

      runner = Thread.new { manager.start }
      deadline = Time.now + 5
      sleep 0.05 until reconciler.reconciled.any? { |r| r[:name] == "default/cron-1" } || Time.now >= deadline
      expect(reconciler.reconciled.map { |r| r[:name] }).to eq(["default/cron-1"])

      # Simulate a leadership takeover: another identity holds the lease.
      lease.spec.holder_identity = "other-pod"
      deadline = Time.now + 5
      sleep 0.05 until !manager.leader? || Time.now >= deadline
      expect(manager.leader?).to be(false)
      expect(reconciler.reconciled.map { |r| r[:name] }).to eq(["default/cron-1"])

      # Leadership is reacquired. The resync observes an object created while
      # this instance was leaderless; its diff is emitted while workers are
      # still down, so the queue must accept it (register reopens the
      # lifecycle-closed queue before the cache restarts).
      lease.spec.holder_identity = nil
      current = { "items" => [
        { "metadata" => { "namespace" => "default", "name" => "cron-1" } },
        { "metadata" => { "namespace" => "default", "name" => "cron-2" } }
      ], "metadata" => { "resourceVersion" => "2" } }
      deadline = Time.now + 5
      sleep 0.05 until reconciler.reconciled.any? { |r| r[:name] == "default/cron-2" } || Time.now >= deadline

      expect(reconciler.reconciled.map { |r| r[:name] }).to contain_exactly("default/cron-1", "default/cron-2")
      expect(reconciler.reconciled.map { |r| r[:other_synced] }).to all(be(true))
      expect(reconciler.reconciled.map { |r| r[:leader] }).to all(be(true))
      expect(informer.synced).to be(true)
    ensure
      manager&.stop
    end
  end

  describe "graceful start and stop (#53)" do
    let(:crontask_gvk) do
      KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
    end

    it "blocks in start until stop is requested (no leader election)" do
      manager = described_class.new(leader_elect: false)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller

      runner = Thread.new { manager.start }
      sleep 0.3 # startup completes immediately with no informers; start must keep blocking
      expect(runner.alive?).to be(true)

      manager.stop
      Timeout.timeout(2) { runner.join }

      expect(controller).to have_received(:stop).at_least(:once)
    end

    it "records a signal in the trap without acquiring Mutexes" do
      previous = {}
      %w[TERM INT].each { |sig| previous[sig] = Signal.trap(sig, "DEFAULT") }
      manager = described_class.new(leader_elect: false)
      manager.send(:setup_signal_handlers)

      Process.kill("TERM", Process.pid)
      sleep 0.2

      expect(manager.instance_variable_get(:@stop_requested_by_signal)).to be(true)
    ensure
      %w[TERM INT].each { |sig| Signal.trap(sig, previous[sig] || "DEFAULT") }
    end

    it "returns from stop within the drain budget while a reconcile is unresponsive" do
      manager = described_class.new(leader_elect: false, stop_timeout: 1)
      allow(manager.cache).to receive(:api_client).and_return(instance_double(Kubernetes::ApiClient))
      fake_watch = instance_double(Kubernetes::Watch)
      allow(Kubernetes::Watch).to receive(:new).and_return(fake_watch)
      allow(fake_watch).to receive(:connect).and_raise(KrubyController::Error, "test watch closed")

      informer = manager.cache.register(gvk: crontask_gvk)
      allow(informer).to receive(:fetch_list).and_return(
        { "items" => [{ "metadata" => { "namespace" => "default", "name" => "cron-1" } }],
          "metadata" => { "resourceVersion" => "1" } }
      )

      reconciler = BlockingSyncSpecReconciler.new
      manager.add(reconciler, for: crontask_gvk)

      runner = Thread.new { manager.start }
      deadline = Time.now + 5
      sleep 0.05 until reconciler.entered? || Time.now >= deadline
      expect(reconciler.entered?).to be(true)

      t0 = Time.now
      manager.stop
      elapsed = Time.now - t0

      # stop_timeout 1s is the whole reconcile-drain budget; the stop must
      # return long before the 3s reconcile completes.
      expect(elapsed).to be < 2.0
      Timeout.timeout(2) { runner.join }
    ensure
      manager&.stop
    end

    it "is idempotent when stop is called repeatedly" do
      manager = described_class.new(leader_elect: false)
      controller = instance_double(KrubyController::Controller, register: nil, start: nil, stop: nil)
      manager.instance_variable_get(:@controllers) << controller

      manager.stop
      expect { manager.stop }.not_to raise_error

      expect(controller).to have_received(:stop).once
    end
  end
end
