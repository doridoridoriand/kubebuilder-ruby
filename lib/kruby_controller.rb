# frozen_string_literal: true

require "kruby"
require "logger"

# KrubyController — Kubernetes Controller Framework for Ruby
#
# Provides controller-runtime equivalent functionality built on kruby:
#   - Manager: orchestrates controllers, shared cache, leader election
#   - Controller: reconcile loop with work queue
#   - Reconciler: abstract class for user reconcile logic
#   - SharedCache: informer-based local cache
#   - Event Handler: watches → reconcile queue
#   - Leader Election: Lease API based
#   - CRD Generator: Ruby DSL → CRD YAML
#   - CLI: scaffolding commands
#
# Example:
#   class MyReconciler < KrubyController::Reconciler
#     def reconcile(request)
#       # your logic here
#       KrubyController::Result.ok
#     end
#   end
#
#   manager = KrubyController::Manager.new(kube_config: ENV["KUBECONFIG"])
#   manager.add(MyReconciler, for: "MyResource")
#   manager.start

module KrubyController
  class Error < StandardError; end

  # Core types
  require_relative "kruby_controller/version"
  require_relative "kruby_controller/logger"
  require_relative "kruby_controller/gvk"
  require_relative "kruby_controller/crd"
  require_relative "kruby_controller/request"
  require_relative "kruby_controller/result"
  require_relative "kruby_controller/reconciler"

  # Queue
  require_relative "kruby_controller/queue/rate_limiter"
  require_relative "kruby_controller/queue/work_queue"

  # Cache
  require_relative "kruby_controller/cache/delta"
  require_relative "kruby_controller/cache/store"
  require_relative "kruby_controller/cache/informer"
  require_relative "kruby_controller/cache/cache"

  # Handlers
  require_relative "kruby_controller/handler/enqueued_object"
  require_relative "kruby_controller/handler/enqueued_owner"
  require_relative "kruby_controller/handler/predicated"

  # Controller
  require_relative "kruby_controller/controller"

  # Leader Election
  require_relative "kruby_controller/election/leader_elector"

  # Manager
  require_relative "kruby_controller/manager"

  # Builders
  require_relative "kruby_controller/builder/controller_builder"

  # Helpers
  require_relative "kruby_controller/kubernetes_object_client"
  require_relative "kruby_controller/finalizer/finalizer_manager"
  require_relative "kruby_controller/owner/owner_reference"
  require_relative "kruby_controller/status/status_updater"

  # CRD Generator
  require_relative "kruby_controller/generator/crd_generator"

  # CLI
  require_relative "kruby_controller/cli/init_command"
  require_relative "kruby_controller/cli/create_api_command"

  private_constant :Error unless const_defined?(:Error, false)
end
