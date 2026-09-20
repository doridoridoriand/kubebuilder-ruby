# Kruby Controller Framework

[![Ruby](https://img.shields.io/badge/ruby-3.3+-brightgreen.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

**Kubernetes Controller Pattern を Ruby で。** kruby (Kubernetes Ruby client) を基盤としたカスタムコントローラー開発フレームワーク。

kubebuilder / controller-runtime のコンセプトを Ruby に移植。

## 概要

Kubernetes のカスタムリソース (CRD) 用のコントローラーを Ruby で簡潔に書けるフレームワーク。

```ruby
class CronTaskReconciler < KrubyController::Reconciler
  def reconcile(request)
    cron_task = get_cron_task(request.namespace, request.name)
    job = ensure_job(cron_task)
    update_status(cron_task, job_status: job.status)
    KrubyController::Result.retry_after(30)
  end
end

manager = KrubyController::Manager.new(kube_config: ENV["KUBECONFIG"])
manager.add(CronTaskReconciler, for: CronTask)
manager.start
```

## 機能

| 機能 | ステータス |
|---|---|
| Controller Manager | 🚧 Phase 1 |
| Reconcile Loop | 🚧 Phase 1 |
| Shared Cache / Informer | 🚧 Phase 1 |
| Event Handler | 🚧 Phase 1 |
| Leader Election | 🚧 Phase 1 |
| CRD Generator | 📅 Phase 2 |
| CLI Scaffolding | 📅 Phase 3 |
| Finalizer / OwnerReference | 📅 Phase 2 |

## ヘルパー (Finalizer / Status)

`FinalizerManager` / `StatusUpdater` は、`update` (オブジェクト全体の PUT) と `patch_status` (`/status` サブレソースの PATCH) を提供する client を必要とします。kruby の `CustomObjectsApi` にはこれらが存在しないため、本フレームワークの `KrubyController::KubernetesObjectClient` を client として渡します:

```ruby
config = Kubernetes::Configuration.default_config
api_client = Kubernetes::ApiClient.new(config)
gvk = KrubyController::GVK.new(group: "stable.example.com", version: "v1", kind: "CronTask", resource: "crontasks")
client = KrubyController::KubernetesObjectClient.new(api_client: api_client, gvk: gvk)

finalizers = KrubyController::Finalizer::FinalizerManager.new(client: client, gvk: gvk)
status = KrubyController::Status::StatusUpdater.new(client: client, gvk: gvk)

# reconcile 内
finalizers.add_finalizer(obj, "crontask.example.com/finalizer")
status.update_status(obj, { "phase" => "Running" })
```

## 要件

- Ruby 3.3+
- kruby ~> 1.36
- Kubernetes 1.31+

## インストール

```bash
gem install kruby-controller
```

または Gemfile:

```ruby
gem "kruby-controller", "~> 0.1"
```

## 開発

```bash
bundle install
bundle exec rake
```

## ドキュメント

- [仕様書](docs/design/specification.md)
- [設計書](docs/design/design.md)

## License

Apache License 2.0 — [LICENSE](LICENSE)
