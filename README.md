# Kruby Controller Framework

[![Ruby](https://img.shields.io/badge/ruby-3.3+-brightgreen.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

**Kubernetes Controller Pattern を Ruby で。** kruby (Kubernetes Ruby client) を基盤としたカスタムコントローラー開発フレームワーク。

kubebuilder / controller-runtime のコンセプトを Ruby に移植。

## 概要

Kubernetes のカスタムリソース (CRD) 用のコントローラーを Ruby で簡潔に書けるフレームワーク。

次は登録とキャッシュ読み取りの最小例です。事前に対象 CRD のインストールと、List / Watch および Lease への RBAC が必要です。リソース作成や status 更新の処理は省略しています。

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

## 機能

| 機能 | 状態 |
|---|---|
| Manager / reconcile / shared cache / leader election | 基本実装あり。同期順序や停止処理を含む信頼性の検証・修正が必要 |
| Event handler / owner reference / finalizer / status | 基本実装あり |
| CRD Generator / CLI `init`・`create api` | 基本実装あり。一部の schema や deploy 資産は未対応 |
| 統合 client / イベント記録 / probe / metrics | 未実装 |
| Webhook / 複数 version の conversion | 未実装 |

実装の有無は本番での検証や Kubebuilder との機能同等性を意味しません。詳細と残課題は[差分評価](docs/design/parity-review.md)を参照してください。

## ヘルパー (Finalizer / Status)

`FinalizerManager` / `StatusUpdater` は、`update` (オブジェクト全体の PUT) と `patch_status` (`/status` サブリソースの PATCH) を提供する client を必要とします。kruby の `CustomObjectsApi` にはこれらが存在しないため、本フレームワークの `KrubyController::KubernetesObjectClient` を client として渡します:

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

初回リリース・公開先は未確定です ([#43](https://github.com/doridoridoriand/kubebuilder-ruby/issues/43))。開発時はこのリポジトリを取得し、`bundle install` を実行してください。

## 開発

```bash
bundle install
bundle exec rake
```

## ドキュメント

- [仕様書](docs/design/specification.md)
- [設計書](docs/design/design.md)
- [本家との差分評価](docs/design/parity-review.md)

## License

Apache License 2.0 — [LICENSE](LICENSE)
