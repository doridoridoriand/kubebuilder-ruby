# frozen_string_literal: true

RSpec.describe KrubyController::Handler::EnqueuedOwner do
  let(:queue) { KrubyController::Queue::WorkQueue.new }
  let(:parent_gvk) { KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask") }
  let(:handler) { described_class.new(queue: queue, owner_gvk: parent_gvk) }
  let(:job) do
    {
      "metadata" => {
        "namespace" => "default",
        "name" => "job-1",
        "ownerReferences" => [
          {
            "apiVersion" => "stable.example.com/v1",
            "kind" => "CronTask",
            "name" => "cron-a",
            "uid" => "uid-a",
            "controller" => true,
            "blockOwnerDeletion" => true
          }
        ]
      }
    }
  end

  def queued
    1.upto(queue.len).map { queue.get }
  end

  it "enqueues the controller owner on any delta type" do
    handler.handle(KrubyController::Cache::Delta::MODIFIED, job)

    expect(queued).to eq([KrubyController::Request.new(namespace: "default", name: "cron-a")])
  end

  it "ignores ownerReferences without controller: true" do
    job["metadata"]["ownerReferences"][0] = job["metadata"]["ownerReferences"][0].except("controller")
    handler.handle(KrubyController::Cache::Delta::ADDED, job)
    expect(queued).to be_empty

    job["metadata"]["ownerReferences"][0]["controller"] = false
    handler.handle(KrubyController::Cache::Delta::MODIFIED, job)
    expect(queued).to be_empty
  end

  it "requires the apiVersion to match, not just the kind" do
    other_group = {
      "apiVersion" => "other.example.com/v1",
      "kind" => "CronTask",
      "name" => "imposter",
      "controller" => true
    }
    job["metadata"]["ownerReferences"] << other_group
    handler.handle(KrubyController::Cache::Delta::ADDED, job)

    expect(queued).to eq([KrubyController::Request.new(namespace: "default", name: "cron-a")])
  end

  it "matches core-group owners by bare version" do
    pod_gvk = KrubyController::GVK.new(group: "", version: "v1", kind: "Pod")
    pod_handler = described_class.new(queue: queue, owner_gvk: pod_gvk)
    core_owner = {
      "apiVersion" => "v1",
      "kind" => "Pod",
      "name" => "pod-a",
      "controller" => true
    }
    obj = { "metadata" => { "namespace" => "default", "name" => "x", "ownerReferences" => [core_owner] } }

    pod_handler.handle(KrubyController::Cache::Delta::ADDED, obj)
    expect(queued).to eq([KrubyController::Request.new(namespace: "default", name: "pod-a")])
  end

  it "handles objects without ownerReferences" do
    handler.handle(KrubyController::Cache::Delta::ADDED, { "metadata" => { "namespace" => "d", "name" => "n" } })
    expect(queued).to be_empty
  end

  context "with a cluster-scoped owner" do
    let(:policy_gvk) { KrubyController::GVK.new(group: "policy.example.com", version: "v1", kind: "Policy", namespaced: false) }
    let(:handler) { described_class.new(queue: queue, owner_gvk: policy_gvk, owner_namespaced: false) }

    it "enqueues the owner under the empty namespace, not the child's" do
      namespaced_child = {
        "metadata" => {
          "namespace" => "default",
          "name" => "child-1",
          "ownerReferences" => [
            {
              "apiVersion" => "policy.example.com/v1",
              "kind" => "Policy",
              "name" => "cluster-pol",
              "controller" => true
            }
          ]
        }
      }

      handler.handle(KrubyController::Cache::Delta::ADDED, namespaced_child)
      expect(queued).to eq([KrubyController::Request.new(namespace: "", name: "cluster-pol")])
    end
  end

  context "with the default (namespaced) owner" do
    it "still copies the child namespace" do
      default_handler = described_class.new(queue: queue, owner_gvk: parent_gvk)
      default_handler.handle(KrubyController::Cache::Delta::ADDED, job)
      expect(queued).to eq([KrubyController::Request.new(namespace: "default", name: "cron-a")])
    end
  end
end
