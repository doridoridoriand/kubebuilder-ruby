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
      if @lease
        @lease
      else
        raise Kubernetes::ApiError.new(code: 404, message: "Not Found")
      end
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
    it "deletes the lease it holds when stopped" do
      elector.run {}
      wait_until { elector.leader }

      elector.stop

      expect(client).to have_received(:delete_namespaced_lease).with("test-lock", "kube-system")
    end

    it "does not delete a lease it does not hold" do
      @lease = build_lease(holder: "other")
      elector.run {}
      sleep 0.2

      elector.stop

      expect(client).not_to have_received(:delete_namespaced_lease)
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
end
