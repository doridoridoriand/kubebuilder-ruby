# Kruby Controller Framework

[![Ruby](https://img.shields.io/badge/ruby-3.3+-brightgreen.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![CI](https://github.com/doridoridoriand/kubebuilder-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/doridoridoriand/kubebuilder-ruby/actions/workflows/ci.yml)

**The Kubernetes controller pattern, in Ruby.** A framework for building custom controllers on top of kruby (the Kubernetes Ruby client).

A Ruby port of the kubebuilder / controller-runtime concepts.

## Overview

A framework for writing controllers for Kubernetes custom resources (CRDs) in Ruby.

The following is a minimal example of registering a reconciler and reading from the cache. Before running it, install the target CRD and grant RBAC for List / Watch and Lease. Handling resource creation and status updates is omitted for brevity.

```ruby
require "kruby-controller"

class CronTask
  include KrubyController::CRD
  self.group = "stable.example.com"
  self.version = "v1"
  self.kind = "CronTask"
  self.plural = "crontasks"
end

CRON_TASK_GVK = KrubyController::GVK.new(
  group: CronTask.group, version: CronTask.version,
  kind: CronTask.kind, resource: CronTask.plural
)

class CronTaskReconciler < KrubyController::Reconciler
  def reconcile(request)
    obj = cache.get(CRON_TASK_GVK, request.namespace, request.name)
    return KrubyController::Result.ok unless obj

    logger.info("Reconciling #{request.namespace}/#{request.name}")
    KrubyController::Result.ok
  end
end

manager = KrubyController::Manager.new(kube_config: ENV["KUBECONFIG"])
manager.add(CronTaskReconciler, for: CronTask)
manager.start
```

## Features

| Feature | Status |
|---|---|
| Manager / reconcile loop / shared cache / leader election | Basic implementation. Reliability aspects (sync ordering, shutdown paths) still need hardening |
| Event handlers / owner references / finalizers / status | Basic implementation |
| CRD generator / CLI `init` and `create api` | Basic implementation. Some schemas and deploy assets are not yet covered |
| Integrated client / event recording / probes / metrics | Not implemented |
| Webhooks / multi-version conversion | Not implemented |

The presence of an implementation does not imply production readiness or feature parity with Kubebuilder. See the [parity review](docs/design/parity-review.md) for details and remaining gaps.

## Helpers (Finalizer / Status)

`FinalizerManager` / `StatusUpdater` require a client that provides `update` (a PUT of the whole object) and `patch_status` (a PATCH on the `/status` subresource). kruby's `CustomObjectsApi` has neither, so pass the framework's `KrubyController::KubernetesObjectClient` as the client:

```ruby
config = Kubernetes::Configuration.default_config
api_client = Kubernetes::ApiClient.new(config)
gvk = KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
client = KrubyController::KubernetesObjectClient.new(api_client: api_client, gvk: gvk)

finalizers = KrubyController::Finalizer::FinalizerManager.new(client: client, gvk: gvk)
status = KrubyController::Status::StatusUpdater.new(client: client, gvk: gvk)

# inside reconcile
finalizers.add_finalizer(obj, "crontask.example.com/finalizer")
status.update_status(obj, { "phase" => "Running" })
```

## Requirements

- Ruby 3.3+
- kruby ~> 1.36
- Kubernetes 1.31+

## Installation

Install the gem:

```sh
gem install kruby-controller
```

or add it to your Gemfile:

```ruby
gem "kruby-controller", "~> 0.1.0"
```

## Example

A complete, runnable example operator lives in [examples/hello-world/](examples/hello-world/) — a CRD class plus an idempotent reconciler, verified end-to-end against a real kind cluster.

## Development

```bash
bundle install
bundle exec rake
```

## Documentation

- [Specification](docs/design/specification.md)
- [Design document](docs/design/design.md)
- [Parity review vs. upstream Kubebuilder](docs/design/parity-review.md)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
