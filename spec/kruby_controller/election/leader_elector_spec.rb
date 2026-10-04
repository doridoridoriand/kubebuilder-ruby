# frozen_string_literal: true

require "time"

RSpec.describe KrubyController::Election::LeaderElector do
  let(:client) do
    double(
      "CoordinationV1Api",
      read_namespaced_lease: nil,
      create_namespaced_lease: nil,
      replace_namespaced_lease: nil,
      delete_namespaced_lease: nil
    )
  end

  let(:elector) do
    described_class.new(
      client:,
      lease_name: "test-lock",
      lease_namespace: "kube-system",
      lease_duration: 15,
      renew_deadline: 10,
      retry_period: 0.1,
      identity: "me"
    )
  end

  before do
    @lease = nil
    allow(client).to receive(:read_namespaced_lease) do
      raise Kubernetes::ApiError.new(code: 404, message: "Not Found") unless @lease

      @lease
    end
    allow(client).to receive(:create_namespaced_lease) do |_namespace, body|
      @lease = body
      body
    end
    allow(client).to receive(:replace_namespaced_lease) do |_name, _namespace, body|
      @lease = body
      body
    end
    allow(client).to receive(:delete_namespaced_lease)
  end

  def build_lease(holder: nil, renewed_at: Time.now.utc)
    spec = { leaseDurationSeconds: 15 }
    spec[:holderIdentity] = holder if holder
    spec[:renewTime] = renewed_at.utc.iso8601 if renewed_at
    Kubernetes::V1Lease.build_from_hash(
      metadata: { name: "test-lock", namespace: "kube-system", resourceVersion: "1" },
      spec:
    )
  end

  def wait_until(timeout: 3)
    deadline = Time.now + timeout
    loop do
      return true if yield

      sleep 0.05
      raise "timed out waiting for condition" if Time.now > deadline
    end
  end

  describe "acquire" do
    it "creates and acquires an unheld lease" do
      started = false
      elector.run { started = true }

      wait_until { elector.leader }
      expect(started).to be true
      expect(@lease.spec.holder_identity).to eq("me")

      elector.stop
    end

    it "does not acquire a fresh lease held by another candidate" do
      @lease = build_lease(holder: "other")
      started = false
      elector.run { started = true }
      sleep 0.3

      expect(elector.leader).to be false
      expect(started).to be false

      elector.stop
    end

    it "acquires a stale lease from a dead holder" do
      @lease = build_lease(holder: "other", renewed_at: Time.now - 30)

      elector.run {}
      wait_until { elector.leader }
      expect(@lease.spec.holder_identity).to eq("me")

      elector.stop
    end
  end

  describe "release" do
    it "clears the holder of the lease it holds when stopped" do
      elector.run {}
      wait_until { elector.leader }

      elector.stop

      expect(@lease.spec.holder_identity).to be_nil
      expect(client).not_to have_received(:delete_namespaced_lease)
    end

    it "does not touch a lease it does not hold" do
      @lease = build_lease(holder: "other")
      elector.run {}
      sleep 0.2

      elector.stop

      expect(@lease.spec.holder_identity).to eq("other")
      expect(client).not_to have_received(:delete_namespaced_lease)
    end
  end

  describe "standby takeover" do
    it "becomes leader once the current holder's lease goes stale" do
      @lease = build_lease(holder: "other", renewed_at: Time.now)
      elector.run {}
      sleep 0.2
      expect(elector.leader).to be false

      @lease = build_lease(holder: "other", renewed_at: Time.now - 30)
      wait_until { elector.leader }
      expect(@lease.spec.holder_identity).to eq("me")

      elector.stop
    end
  end

  describe "renew deadline" do
    it "steps down when renewals keep failing beyond renew_deadline" do
      elector = described_class.new(
        client:,
        lease_name: "test-lock",
        lease_namespace: "kube-system",
        lease_duration: 15,
        renew_deadline: 0.5,
        retry_period: 0.1,
        identity: "me",
        on_stopped_leading: -> { @stopped = true }
      )
      @stopped = false

      elector.run {}
      wait_until { elector.leader }

      allow(client).to receive(:read_namespaced_lease)
        .and_raise(Kubernetes::ApiError.new(code: 500, message: "boom"))

      wait_until { @stopped }
      expect(elector.leader).to be false

      elector.stop
    end
  end

  describe "leadership loss" do
    it "stops leading and calls on_stopped_leading when the lease is taken over" do
      elector = described_class.new(
        client:,
        lease_name: "test-lock",
        lease_namespace: "kube-system",
        lease_duration: 15,
        renew_deadline: 10,
        retry_period: 0.1,
        identity: "me",
        on_stopped_leading: -> { @stopped = true }
      )
      @stopped = false

      elector.run {}

      wait_until { elector.leader }
      @lease = build_lease(holder: "other", renewed_at: Time.now)
      wait_until { @stopped }
      expect(elector.leader).to be false

      elector.stop
    end
  end

  describe "leading block failure" do
    it "records the error, invokes on_leading_error, releases the lease, and stops electing" do
      @error_called = false
      elector = described_class.new(
        client:,
        lease_name: "test-lock",
        lease_namespace: "kube-system",
        lease_duration: 15,
        renew_deadline: 10,
        retry_period: 0.1,
        identity: "me",
        on_leading_error: -> { @error_called = true }
      )

      elector.run { raise StandardError, "cache sync timed out" }

      wait_until { elector.leading_error }

      expect(elector.leading_error.message).to include("cache sync timed out")
      expect(@error_called).to be true
      expect(elector.leader).to be false

      elector.stop
      expect(@lease.spec.holder_identity).to be_nil # released on the way out
    end
  end
end
