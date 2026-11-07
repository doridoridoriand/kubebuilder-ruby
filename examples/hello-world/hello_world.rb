# frozen_string_literal: true

# A minimal but complete hello-world controller that exercises the framework
# end-to-end against a real cluster:
#
#   * SharedCache List/Watch (informer) for HelloResource
#   * the reconcile loop (Manager + Controller + WorkQueue)
#   * a cache read (cache.get)
#   * a status subresource write (StatusUpdater)
#
# Run it (with the CRD already installed) using a kubeconfig in $KUBECONFIG:
#
#   bundle exec ruby examples/hello-world/hello_world.rb
#
# It starts, syncs the cache, and blocks until SIGTERM/SIGINT. Create a CR to
# watch it reconcile:
#
#   kubectl create helloresources -n default -o yaml <<'YAML' | kubectl apply -f -
#   apiVersion: smoke.example.com/v1
#   kind: HelloResource
#   metadata:
#     name: one
#   spec:
#     message: world
#   YAML
#
#   kubectl get helloresource -n default one -o yaml   # status.greeting is set
#
# leader_elect: false keeps the smoke test single-replica and lease-free; a
# production operator sets leader_elect: true (the default).

require "kruby-controller"
require "kubernetes"

# Flush logs line-by-line so the operator's log is visible live (Ruby buffers
# $stdout when it points at a file/pipe).
STDOUT.sync = true

class HelloResource
  include KrubyController::CRD

  self.group = "smoke.example.com"
  self.version = "v1"
  self.kind = "HelloResource"
  self.namespaced = true
  self.plural = "helloresources"

  attribute :message, type: :string, required: true, description: "Name to greet"
  status_attribute :greeting, type: :string, description: "Set by the controller"
  status_attribute :observed_count, type: :integer, description: "Number of reconciles"
end

HELLO_GVK = KrubyController::GVK.new(
  group: HelloResource.group,
  version: HelloResource.version,
  kind: HelloResource.kind,
  resource: HelloResource.plural
)

class HelloReconciler < KrubyController::Reconciler
  def initialize(client)
    @status = KrubyController::Status::StatusUpdater.new(client: client, gvk: HELLO_GVK)
  end

  # Idempotent reconcile: only write status when it differs from the desired
  # value. Without this guard the status patch would itself be observed by the
  # List/Watch informer as a MODIFIED event, which re-enqueues the object and
  # re-runs reconcile forever (~300 writes/s in the smoke test). A real
  # controller either guards writes this way or installs a "generation
  # changed" predicate (see issue #34) so status-only updates do not
  # re-trigger reconciliation.
  def reconcile(request)
    obj = cache.get(HELLO_GVK, request.namespace, request.name)
    return KrubyController::Result.ok unless obj

    desired = "hello, #{obj.dig("spec", "message")}"
    return KrubyController::Result.ok if obj.dig("status", "greeting") == desired

    count = (obj.dig("status", "observed_count") || 0) + 1
    @status.update_status(obj, { "greeting" => desired, "observed_count" => count })
    logger.info("reconciled #{request.namespace}/#{request.name}: greeting=#{desired} count=#{count}")
    KrubyController::Result.ok
  end
end

kube_config = ENV.fetch("KUBECONFIG") { raise "KUBECONFIG must be set (point it at your kind cluster)" }
config = Kubernetes::KubeConfig.new(kube_config).configure(Kubernetes::Configuration.new)
api_client = Kubernetes::ApiClient.new(config)
client = KrubyController::KubernetesObjectClient.new(api_client: api_client, gvk: HELLO_GVK)

KrubyController.logger.info("HelloResource operator starting (leader_elect=false)")
manager = KrubyController::Manager.new(kube_config: kube_config, leader_elect: false)
manager.add(HelloReconciler.new(client), for: HelloResource)
manager.start

# Force-terminate the process once the manager has cleanly stopped.
#
# #start returns after the full logical shutdown (controllers drained, cache
# stopped, lease released). A single worker, however, can be parked in the
# Typhoeus watch read, which exposes no cancellation API (Typhoeus::Request has
# no #cancel; Thread#kill cannot interrupt the underlying libcurl read, and
# Ruby 3.4 removed Thread#daemon). Such a worker is a non-daemon thread that
# would block the ordinary end-of-script exit, hanging the process after it
# has already stopped. exit! terminates it at the OS level without re-running
# any cleanup that #stop already performed. See docs/design/design.md §9.9.
exit!(0)
