# frozen_string_literal: true

require "open3"
require "tempfile"

RSpec.describe "Manager lifecycle (subprocess, #53)" do
  # Runs a real Manager in a child process with a faked Kubernetes transport
  # (no cluster in the test environment): the cache lists an empty resource
  # set, watch connections fail and are retried by the informer, and the
  # Lease API is an in-memory object. The child prints STARTED once the
  # manager is up (leader acquired / cache synced), optionally prints
  # RECONCILE_START when its first reconcile begins, and blocks inside
  # Manager#start until it is stopped.
  SUBPROCESS_SCRIPT = <<~RUBY
    require "kruby-controller"

    class KrcFakeResponse
      def success? = true
      def body = '{"items":[],"metadata":{"resourceVersion":"1"}}'
    end
    class KrcFakeRequest
      def initialize(path) = @path = path
      def run
        raise KrubyController::Error, "no watch in subprocess test" if @path.include?("watch=true")
        KrcFakeResponse.new
      end
    end
    class KrcFakeApiClient
      def build_request(_method, path, **_opts) = KrcFakeRequest.new(path)
    end
    class KrcFakeLeaseApi
      def initialize
        @lease = Kubernetes::V1Lease.build_from_hash(
          metadata: { name: "kruby-controller-lock", namespace: "kube-system" },
          spec: { leaseDurationSeconds: 15 }
        )
      end
      def read_namespaced_lease(_name, _ns) = @lease
      def replace_namespaced_lease(_name, _ns, lease) = lease
    end
    module KrubyController
      class Cache::SharedCache
        def api_client = KrcFakeApiClient.new
      end
      class Manager
        def coordination_client = KrcFakeLeaseApi.new
      end
    end

    sleep_s = ENV.fetch("KRC_SUBPROCESS_RECONCILE_SLEEP", "0").to_f
    reconciler = Class.new(KrubyController::Reconciler) do
      define_method(:reconcile) do |_request|
        puts "RECONCILE_START"
        $stdout.flush
        sleep sleep_s
        KrubyController::Result.ok
      end
    end.new

    manager = KrubyController::Manager.new(
      leader_elect: ENV["KRC_SUBPROCESS_MODE"] == "leader",
      stop_timeout: ENV.fetch("KRC_SUBPROCESS_STOP_TIMEOUT", "30").to_f
    )
    manager.add(
      reconciler,
      for: KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
    )

    runner = Thread.new { manager.start }
    deadline = Time.now + 20
    if ENV["KRC_SUBPROCESS_MODE"] == "leader"
      sleep 0.05 until manager.leader? || Time.now >= deadline
      abort("child: leader not acquired in time") unless manager.leader?
    else
      sleep 0.05 until manager.cache.instance_variable_get(:@informers).values.all?(&:synced) || Time.now >= deadline
      unless manager.cache.instance_variable_get(:@informers).values.all?(&:synced)
        abort("child: cache not synced in time")
      end
    end
    puts "STARTED"
    $stdout.flush
    if sleep_s > 0
      controller = manager.instance_variable_get(:@controllers).first
      controller.instance_variable_get(:@queue).add(
        KrubyController::Request.new(namespace: "default", name: "cron-1")
      )
    end
    runner.join
  RUBY

  def spawn_manager_subprocess(env_overrides)
    script = Tempfile.new(["krc-manager", ".rb"])
    script.write(SUBPROCESS_SCRIPT)
    script.close
    stdin, stdout, stderr, wait_thr =
      Open3.popen3(env_overrides, "bundle", "exec", "ruby", "-Ilib", script.path)
    stdin.close
    stdout_buf = +""
    stderr_buf = +""
    stdout_reader = Thread.new { stdout.each_line { |line| stdout_buf << line } }
    stderr_reader = Thread.new { stderr.each_line { |line| stderr_buf << line } }
    [stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader]
  end

  def wait_for_marker(stdout_buf, reader, marker, timeout: 20)
    deadline = Time.now + timeout
    sleep 0.05 while !stdout_buf.include?(marker) && reader.alive? && Time.now < deadline
    stdout_buf.include?(marker)
  end

  def kill_quietly(pid)
    Process.kill("KILL", pid)
    nil
  rescue StandardError
    nil
  end

  # Waits at most `seconds` for the child to exit and returns its
  # Process::Status (nil when it did not exit in time).
  def exit_status_within(wait_thr, seconds)
    return nil unless wait_thr.join(seconds)

    wait_thr.value
  end

  def subprocess_diagnostics(stdout_buf, stderr_buf)
    "child output: #{stdout_buf[-1500..] || stdout_buf}\n--- stderr ---\n#{stderr_buf[-1500..] || stderr_buf}"
  end

  def collect_child(stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader)
    if wait_thr&.alive?
      kill_quietly(wait_thr.pid)
      wait_thr.join
    end
    stdout_reader&.join(2)
    stderr_reader&.join(2)
    script&.unlink
  end

  it "runs until SIGTERM in non-leader mode and exits cleanly, including a repeated signal" do
    stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader =
      spawn_manager_subprocess({ "KRC_SUBPROCESS_MODE" => "noleader", "KRC_SUBPROCESS_RECONCILE_SLEEP" => "0" })

    expect(wait_for_marker(stdout_buf, stdout_reader, "STARTED"))
      .to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)

    Process.kill("TERM", wait_thr.pid)
    sleep 0.3
    begin
      Process.kill("TERM", wait_thr.pid) # repeated stop: the second signal must be harmless
    rescue Errno::ESRCH
      nil
    end

    status = exit_status_within(wait_thr, 10)
    expect(status&.success?).to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)
  ensure
    collect_child(stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader)
  end

  it "runs until SIGTERM in leader-election mode and exits cleanly" do
    stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader =
      spawn_manager_subprocess({ "KRC_SUBPROCESS_MODE" => "leader", "KRC_SUBPROCESS_RECONCILE_SLEEP" => "0" })

    expect(wait_for_marker(stdout_buf, stdout_reader, "STARTED"))
      .to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)

    t0 = Time.now
    Process.kill("TERM", wait_thr.pid)
    status = exit_status_within(wait_thr, 10)
    elapsed = Time.now - t0

    expect(status&.success?).to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)
    # NFR-06: stop within 30s of the signal; the drain here is instant and
    # the elector's own join is bounded by its retry_period (2s default).
    expect(elapsed).to be < 8.0, subprocess_diagnostics(stdout_buf, stderr_buf)
  ensure
    collect_child(stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader)
  end

  it "returns from stop within the drain budget when a reconcile is unresponsive" do
    stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader = spawn_manager_subprocess(
      {
        "KRC_SUBPROCESS_MODE" => "noleader",
        "KRC_SUBPROCESS_RECONCILE_SLEEP" => "10",
        "KRC_SUBPROCESS_STOP_TIMEOUT" => "1"
      }
    )

    expect(wait_for_marker(stdout_buf, stdout_reader, "STARTED"))
      .to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)
    expect(wait_for_marker(stdout_buf, stdout_reader, "RECONCILE_START", timeout: 10))
      .to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)
    sleep 0.2 # let the worker settle inside the 10s reconcile

    t0 = Time.now
    Process.kill("TERM", wait_thr.pid)
    status = exit_status_within(wait_thr, 10)
    elapsed = Time.now - t0

    expect(status&.success?).to be(true), subprocess_diagnostics(stdout_buf, stderr_buf)
    # stop_timeout 1s bounds the drain; the process must exit long before
    # the 10s reconcile completes.
    expect(elapsed).to be < 5.0, subprocess_diagnostics(stdout_buf, stderr_buf)
  ensure
    collect_child(stdout_buf, stderr_buf, wait_thr, script, stdout_reader, stderr_reader)
  end
end
