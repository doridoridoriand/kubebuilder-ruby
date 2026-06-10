# Kruby Controller Framework — 仕様書 (Specification)

| 項目 | 内容 |
|---|---|
| 名称 | **Kruby Controller Framework** (コードネーム: `kruby-controller`) |
| 目的 | kubebuilder 相当のカスタムコントローラー開発フレームワークを Ruby / kruby で提供 |
| バージョン | Draft 0.1 |
| 日付 | 2026-06-10 |
| 著者 | Takahiro Ishida / Hermes |

---

## 1. 概要

### 1.1 背景

Kubernetes でカスタムリソース (CRD) を運用する場合、Go 言語では kubebuilder / controller-runtime が成熟した開発体験を提供している。一方 Ruby エコシステムには同等のフレームワークが存在せず、kruby は API クライアントとして利用可能だが、コントローラーパターン (Reconcile Loop) 周りの支援は不足している。

本仕様書では、kruby を基盤として **kubebuilder 同等のコントローラー開発フレームワーク** を構築する要件を定義する。

### 1.2 目指す開発者体験

```ruby
# my_controller/reconcilers/cron_task_reconciler.rb
class CronTaskReconciler < KrubyController::Reconciler
  def reconcile(request)
    # desired state を取得
    cron_task = get_cron_task(request.namespace, request.name)

    # current state を確認・調整
    job = ensure_job(cron_task)
    update_status(cron_task, job_status: job.status)

    KrubyController::Result.retry_after(30)
  end
end

# my_controller/manager.rb
manager = KrubyController::Manager.new(kube_config:)
manager.add(CronTaskReconciler, for: "CronTask")
manager.start  # blocks
```

**kubebuilder ユーザーは Ruby 版を直感的に理解できる** ことがデザイン目標。

---

## 2. スコープ

### 2.1 含む機能 (In Scope)

| ID | 機能 | 優先度 | 説明 |
|---|---|---|---|
| F-01 | Controller Manager | **MUST** | 複数のコントローラーを管理・起動・共有リソースをオーケストレーション |
| F-02 | Reconcile Loop | **MUST** | kubebuilder 同等の reconcile 抽象 (Request → reconcile → Result) |
| F-03 | Informer / Shared Cache | **MUST** | Watch ベースのローカルキャッシュ、delta 配信、リソースバージョン追跡 |
| F-04 | Watch-based Event Handler | **MUST** | Create/Update/Delete イベントを reconcile queue にエンキュー |
| F-05 | Leader Election | **MUST** | Lease API によるレプリカ間のリーダー選出 |
| F-06 | CRD Generator | **MUST** | Ruby クラス定義 → CRD YAML 変換 |
| F-07 | CLI Scaffolding | **MUST** | `kruby-controller init`, `kruby-controller create api` |
| F-08 | Finalizer Management | **SHOULD** | finalizer の追加・削除・クリーンアップを支援 |
| F-09 | OwnerReference 管理 | **SHOULD** | controllerOf: true / blockOwnerDeletion の自動付与 |
| F-10 | Status Subresource 支援 | **SHOULD** | status の乐观排他更新 (three-way merge 相当) |

### 2.2 含まない機能 (Out of Scope — 将来検討)

| ID | 機能 | 備考 |
|---|---|---|
| O-01 | Validating / Mutating Webhook | 重要だが Phase 2 以降 |
| O-02 | Conversion Webhook | CRD version conversion |
| O-03 | Metrics / Prometheus Integration | controller-runtime の metrics サポート |
| O-04 | Predictive Scaffolding | kubebuilder v4 の Go types から CRD 推論 |
| O-05 | Multi-Cluster 対応 | 将来的に検討 |

---

## 3. 要件

### 3.1 機能的要件

#### FR-01: Controller Manager

| 項目 | 内容 |
|---|---|
| 識別子 | FR-01 |
| 説明 | Manager は kubeconfig を読み込み、shared cache を初期化し、登録されたコントローラーを並行実行する |
| 入力 | kubeconfig path または in-cluster config |
| 出力 | 非同期でコントローラーを実行し、sigterm で優雅に停止 |
| 制約 | Ruby の GIL を考慮し、コントローラーは別スレッドで動作 |

#### FR-02: Reconcile Loop

| 項目 | 内容 |
|---|---|
| 識別子 | FR-02 |
| 説明 | 各コントローラーは独立した reconcile queue を持ち、enqueue されたリソースを順次 reconcile |
| 仕様 | kubebuilder と同様に `reconcile(request)` → `Result` のパターンを採用 |
| Result タイプ | `Result.ok`, `Result.retry_after(seconds)`, `Result.requeue` |
| エラー処理 | reconcile で例外発生時はログ出力 + 指数バックオフで再試行 |

#### FR-03: Shared Cache / Informer

| 項目 | 内容 |
|---|---|
| 識別子 | FR-03 |
| 説明 | リソース種別ごとに List → Watch でローカルキャッシュを構築・維持 |
| 仕様 | `cache.get(GVK, namespace, name)`, `cache.list(GVK, namespace, label_selector:)` |
| 制約 | 初回 cache sync 完了前に reconcile が開始されないこと |
| 再同期 | watch 切断時に resourceVersion から再 List → Watch |

#### FR-04: Event Handler

| 項目 | 内容 |
|---|---|
| 識別子 | FR-04 |
| 説明 | Informer の delta (Create/Update/Delete) を reconcile queue にエンキュー |
| 仕様 | デフォルトはエンキューしたオブジェクト自身の GVK/namespace/name |
| 拡張 | `EnqueueRequestForObject`, `EnqueueRequestForOwner` (owner reference 経由) |

#### FR-05: Leader Election

| 項目 | 内容 |
|---|---|
| 識別子 | FR-05 |
| 説明 | コントローラーを複数レプリカデプロイする場合、1 台だけが reconcile を実行 |
| 仕様 | Kubernetes Lease API (coordination.k8s.io/v1) を使用 |
| 設定 | `leader_elect: true/false` (デフォルト: true), `lease_duration`, `renew_deadline`, `retry_period` |

#### FR-06: CRD Generator

| 項目 | 内容 |
|---|---|
| 識別子 | FR-06 |
| 説明 | Ruby クラスの属性定義から OpenAPI v3 schema を持つ CRD YAML を生成 |
| 入力 | Ruby class + attribute DSL (type, required, enum, default, description) |
| 出力 | `config/crd/bases/<group>_<plural>.yaml` |

#### FR-07: CLI Scaffolding

| 項目 | 内容 |
|---|---|
| 識別子 | FR-07 |
| 説明 | プロジェクト生成・API スケルトン生成 |
| コマンド | `kruby-controller init --domain example.com`, `kruby-controller create api --group <G> --version <V> --kind <K>` |
| 出力 | Gemfile, Rakefile, manager.rb, reconciler スケルトン, CRD YAML |

#### FR-08: Finalizer Management

| 項目 | 内容 |
|---|---|
| 識別子 | FR-08 |
| 説明 | `add_finalizer`, `has_finalizer?`, `remove_finalizer` を抽象化。onDelete 検知を支援 |
| 仕様 | `self.finalize?("my-finalizer")` → true ならリソースが削除マーク済み |

#### FR-09: OwnerReference 管理

| 項目 | 内容 |
|---|---|
| 識別子 | FR-09 |
| 説明 | `set_owner_reference(obj, controller: true)` で ownerReference を自動付与 |
| 仕様 | UID, APIVersion, Kind を自動取得。`blockOwnerDeletion` オプション |

#### FR-10: Status Subresource

| 項目 | 内容 |
|---|---|
| 識別子 | FR-10 |
| 説明 | status 更新時の optimistic concurrency control |
| 仕様 | `update_status(obj)` → spec を触らず status だけを PATCH |

---

## 4. 非機能的要件

| ID | 要件 | 値 |
|---|---|---|
| NFR-01 | Ruby バージョン | 3.3+ (kruby と同じ) |
| NFR-02 | 依存 kruby | `kruby ~> 1.36` |
| NFR-03 | パッケージ形式 | Ruby Gem (gemspec) |
| NFR-04 | CLI 実行環境 | Ruby 3.3+ で `bundle exec kruby-controller` |
| NFR-05 | スレッドセーフ | shared cache はスレッドセーフであること |
| NFR-06 |  graceful shutdown | sigterm 受信後、最大 30 秒以内に停止 |
| NFR-07 | ロギング | `Logger` インターフェース準拠 (デフォルト: stdout)、ログレベル変更可能 |
| NFR-08 | 構成ファイル | `.kruby-controller.yml` (プロジェクト構成) |

---

## 5. 用語集

| 用語 | 定義 |
|---|---|
| CRD | Custom Resource Definition。Kubernetes に新しいリソース種別を登録する仕組み |
| Controller | Kubernetes の control loop を実装するプログラム |
| Reconcile | desired state と current state の差異を解消する処理 |
| Informer | Kubernetes API を Watch してローカルキャッシュを維持するコンポーネント |
| Shared Cache | 複数のコントローラーで共有される informer ベースのキャッシュ |
| GVK | Group/Version/Kind の略。Kubernetes リソースの識別子 |
| GVR | Group/Version/Resource の略。REST API パスでの識別子 |
| Finalizer | リソース削除時に特定の処理を実行するためのメカニズム |
| OwnerReference | リソース間の所有関係を表現する Kubernetes 原語 |

---

## 6. 依存・前提

| 依存 | 詳細 |
|---|---|
| kruby | Kubernetes API クライアント。Watch, ApiClient, Configuration を使用 |
| Kubernetes クラスター | 開発時は kind / minikube。運用時は Cycloud k8s など |
| kubectl | CLI scaffolding で kubectl 構文を理解するために参照 (必須依存ではない) |

---

## 7. 成功基準

| # | 成功基準 |
|---|---|
| 1 | CRD + 1 コントローラーの Hello World が 5 行以内の reconcile コードで動作する |
| 2 | kubebuilder ユーザーがドキュメントを読んで Ruby 版を使い始められる |
| 3 | 複数コントローラーが shared cache を共有して並列実行できる |
| 4 | Leader Election が動作し、レプリカ増減で reconcile 継続する |
| 5 | CRD Generator が Ruby クラス → 有効な CRD YAML を出力する |
| 6 | CLI scaffolding で `init` + `create api` でプロジェクトが立ち上がる |
