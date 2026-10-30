# Kruby Controller Framework — 仕様書 (Specification)

| 項目 | 内容 |
|---|---|
| 名称 | **Kruby Controller Framework** (コードネーム: `kruby-controller`) |
| 目的 | kubebuilder 相当のカスタムコントローラー開発フレームワークを Ruby / kruby で提供 |
| 文書番号 | KRC-SPEC-001 |
| バージョン | Draft 0.2 |
| 日付 | 2026-10-30 |
| 著者 | Takahiro Ishida / Hermes |

**変更履歴**

| 版 | 日付 | 変更 |
|---|---|---|
| 0.1 | 2026-06-10 | 初版 |
| 0.2 | 2026-10-30 | kubebuilder 差分分析に基づく増補: F-11〜F-24 追加 (Phase 5〜9)、O-01〜O-03 の In Scope 昇格、実装状況の明記、NFR・成功基準の追加。レビュー対応: EventRecorder を events.k8s.io/v1 スキーマ準拠に訂正、predicate の互換契約を明示化、定期 resync をキャッシュ全件の合成再配信に変更、merge-patch への resourceVersion 保持。再レビュー対応: `/readyz` をスタンバイ Ready 既定に変更 (`ready_gate: :leader` は Recreate 戦略前提)、merge-patch への限定、webhook 例外と明示拒否の分離、定期 resync を predicate 適用前配信に変更 |

---

## 1. 概要

### 1.1 背景

Kubernetes でカスタムリソース (CRD) を運用する場合、Go 言語では kubebuilder / controller-runtime が成熟した開発体験を提供している。一方 Ruby エコシステムには同等のフレームワークが存在せず、kruby は API クライアントとして利用可能だが、コントローラーパターン (Reconcile Loop) 周りの支援は不足している。

本仕様書では、kruby を基盤として **kubebuilder 同等のコントローラー開発フレームワーク** を構築する要件を定義する。

### 1.2 目指す開発者体験

(0.2 注記: 以下は Phase 5 (F-11 / F-12) 完了後の目指す形。現行の実装では `reconciler.cache` と手動構築の kruby API クライアントを利用する)

```ruby
# my_controller/reconcilers/cron_task_reconciler.rb
class CronTaskReconciler < KrubyController::Reconciler
  def reconcile(request)
    # cache 読み (F-11: 注入された ControllerClient)
    cron_task = client.get(CronTask, request.namespace, request.name)
    return KrubyController::Result.ok if cron_task.nil?

    # current state を確認・調整 (API 書き込み)
    job = ensure_job(cron_task)   # client.create(job) / client.patch(job)

    # status 更新 (/status subresource へ merge-patch、競合は F-13 で処理)
    client.patch_status(cron_task, "jobStatus" => job.status)

    KrubyController::Result.retry_after(30)
  end
end

# my_controller/manager.rb
manager = KrubyController::Manager.new(kube_config:)
manager.add(CronTaskReconciler, for: "CronTask")  # F-12: client / recorder / logger を注入
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
| F-10 | Status Subresource 支援 | **SHOULD** | status の楽観的排他制御による更新 (three-way merge 相当) |
| F-11 | ControllerClient | **MUST** | cache 読み + API 書き込みを単一の注入オブジェクトに統合 (Phase 5) |
| F-12 | 依存の自動注入 | **MUST** | Reconciler へ client / cache / api_client / logger / recorder を Manager が注入 (Phase 5) |
| F-13 | 競合検知つき書き込み | **SHOULD** | resourceVersion による楽観的排他制御、409 (conflict) の再取得リトライ (Phase 5) |
| F-14 | EventRecorder | **SHOULD** | events.k8s.io/v1 の Kubernetes Events 送出 (Phase 7) |
| F-15 | Health Probe | **SHOULD** | `/healthz` (生存) / `/readyz` (cache sync、オプションでリーダー状態) エンドポイント (Phase 7) |
| F-16 | 定期 Resync | **SHOULD** | watch 切断に依らない定期的な再同期 (既定 10h, Phase 6) |
| F-17 | Predicate 拡張 | **SHOULD** | old/new 付き Update イベント、事前定義 predicate (GenerationChanged 等) (Phase 6) |
| F-18 | Server-side Selector | **SHOULD** | List/Watch に labelSelector / fieldSelector を渡す (Phase 6) |
| F-19 | CRD DSL 検証制約 | **SHOULD** | minimum/maximum/minLength/maxLength/pattern/format + additionalPrinterColumns (Phase 8) |
| F-20 | Scaffold 完全化 | **SHOULD** | Makefile / Dockerfile / Kustomize 構成 / config/samples / GitHub Actions CI (Phase 8) |
| F-21 | Validating / Mutating Webhook | **SHOULD** | AdmissionReview v1 受信・応答、`create webhook` コマンド (Phase 9) |
| F-22 | Conversion Webhook | **SHOULD** | CRD version conversion (複数 version 宣言 + webhook 応答) (Phase 9) |
| F-23 | Metrics | **SHOULD** | Prometheus 互換 `/metrics` (workqueue / reconcile 指標) (Phase 7) |
| F-24 | Typed Resource Accessor | **SHOULD** | CRD DSL からの spec/status アクセサ生成 (O-04 の簡易版) (Phase 8) |

### 2.2 含まない機能 (Out of Scope — 将来検討)

| ID | 機能 | 備考 |
|---|---|---|
| O-04 | Predictive Scaffolding (kubebuilder v4 の Go types から CRD 推論の完全実装) | F-24 は簡易版のみ。完全な型生成・deepcopy 相当は将来検討 |
| O-05 | Multi-Cluster 対応 | 将来的に検討 |

(0.2 注記: O-01 Validating/Mutating Webhook、O-02 Conversion Webhook、O-03 Metrics は F-21 / F-22 / F-23 として In Scope に昇格した。判断根拠は設計書 §2.17 / §2.19 および設計書 §11 の未確定事項を参照)

### 2.3 実装状況

| F-ID | 状態 | 備考 |
|---|---|---|
| F-01 〜 F-05 | 実装済み | Phase 1〜3 (PR #18〜#29 含む)。#24〜#29 で信頼性強化済み |
| F-06 | 実装済み (一部未対応) | additionalPrinterColumns は未対応 → F-19 (Phase 8)、issue #15 |
| F-07 | 実装済み | PR #28。Makefile/Dockerfile 等の拡張は F-20 (Phase 8) |
| F-08 〜 F-09 | 実装済み | PR #22 |
| F-10 | 実装済み (一部未対応) | merge-patch のみ。楽観的排他制御 (three-way) は F-13 (Phase 5) |
| F-11 〜 F-24 | 未実装 | Phase 5 〜 9 |

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

#### FR-11: ControllerClient

| 項目 | 内容 |
|---|---|
| 識別子 | FR-11 |
| 説明 | cache 読みと API 書き込みを統合した Reconciler 用クライアント (kubebuilder の `client.Client` 相当) |
| 仕様 | `get` / `list` は当該 GVK が watch 登録済みなら SharedCache、未登録なら直接 API。`create` / `update` / `patch` / `delete` / `patch_status` は kruby `ApiClient` で直接構築 |
| 制約 | スレッドセーフ。外部依存の追加はしない (`ApiClient#build_request` 利用) |

#### FR-12: 依存の自動注入

| 項目 | 内容 |
|---|---|
| 識別子 | FR-12 |
| 説明 | Manager が Reconciler に client / cache / api_client / logger (recorder は F-14 実装後) を自動注入 |
| 仕様 | Controller 生成時に GVK 単位の ControllerClient を構築し、既存の attr_accessor (`client=` / `cache=` / `api_client=`) 経由で設定 |
| 制約 | 後方互換 — 仕様書 0.1 の利用コードが壊れないこと。手動構築した値は注入で上書きされる |

#### FR-13: 競合検知つき書き込み

| 項目 | 内容 |
|---|---|
| 識別子 | FR-13 |
| 説明 | update / patch_status における optimistic concurrency control (F-10 の強化) |
| 仕様 | `update` は resourceVersion を保持して PUT。409 (conflict) → サーバーから再取得 → 最大 5 回再適用。上限超過は `KrubyController::ConflictError` を raise (Controller の指数バックオフに合流)。`patch` / `patch_status` も merge-patch ボディに `metadata.resourceVersion` を含めて競合検知する |
| 制約 | 全体 PUT の再適用は同時更新を握り潰しうるため、頻繁に同時更新されるフィールドは patch (merge) を推奨 (merge-patch は対象フィールドのみ更新し、RV による競合検知が効く) |

#### FR-14: EventRecorder

| 項目 | 内容 |
|---|---|
| 識別子 | FR-14 |
| 説明 | Kubernetes Events (events.k8s.io/v1) の送出 |
| 仕様 | `event(obj, type:, reason:, message:)` / `eventf(...)`。ペイロードは events.k8s.io/v1 スキーマに準拠 (`regarding` / `note` / `reportingController` / `eventTime`、deprecated な core/v1 フィールドは不使用)。送信は非同期 (有界キュー)、同一 (regarding.uid, reason, note) は series (count, lastObservedTime) 増分 |
| 制約 | 送信失敗はログのみ (reconcile を失敗させない)。RBAC (`events` create/patch) を scaffold に追加 |

#### FR-15: Health Probe

| 項目 | 内容 |
|---|---|
| 識別子 | FR-15 |
| 説明 | liveness / readiness 用 HTTP エンドポイント |
| 仕様 | `/healthz` は常時 200 (プロセス生存)。`/readyz` は既定「全 informer synced」で 200 (リーダー非取得のスタンバイも Ready — RollingUpdate と両立)。`ready_gate: :leader` で「リーダー取得済みのみ 200」に変更可 (その場合は Deployment を Recreate 戦略にする必要がある) |
| 設定 | `Manager.new(health_bind_address: "0.0.0.0:8081", ready_gate: :default | :leader)`。nil で無効 |

#### FR-16: 定期 Resync

| 項目 | 内容 |
|---|---|
| 識別子 | FR-16 |
| 説明 | watch 切断に依らない定期的な再同期 (controller-runtime SyncPeriod 相当) |
| 仕様 | Informer が `resync_period` (既定 10h, 0/nil で無効) ごとに、キャッシュ済みの全オブジェクトを合成 delta として handler に再配信する (API List なし。resourceVersion 変化の有無に依らず再配信)。合成 delta は predicate 適用前に配信する。watch 切断時の relist (新鮮な List + 差分配信) は従来どおり |
| 制約 | 配信負荷はオブジェクト数に比例する (API 負荷ではない)。大規模キャッシュでは resync_period の引き上げを推奨 |

#### FR-17: Predicate 拡張

| 項目 | 内容 |
|---|---|
| 識別子 | FR-17 |
| 説明 | イベント型つき predicate (Create / Update / Delete / Generic)。Update は old/new を保持 |
| 仕様 | イベント型 predicate は `KrubyController::Predicate.event { |event| ... }` で明示的に包む。事前定義 predicate (`Event::Predicates.generation_changed` 等) を提供 |
| 制約 | 後方互換 — 素の proc / lambda (obj 受け取り) は従来どおり生 Hash を受け取る。種別判定は arity ではなく包む型 (`Predicate::EventPredicate` かどうか) で行う |

#### FR-18: Server-side Selector

| 項目 | 内容 |
|---|---|
| 識別子 | FR-18 |
| 説明 | Informer の List/Watch に labelSelector / fieldSelector を渡す |
| 仕様 | `register(gvk:, label_selector:, field_selector:)` → List/Watch URL に付与。watch 切断時の relist も同一条件 (定期 resync は既存ストアの再配信であり再取得は行わない) |
| 制約 | ストアは「セレクタに合致する集合」を保持。合致しないオブジェクトの削除は通知されない (kubebuilder 同様のトレードオフ) |

#### FR-19: CRD DSL 検証制約

| 項目 | 内容 |
|---|---|
| 識別子 | FR-19 |
| 説明 | attribute DSL に OpenAPI v3 の検証制約と printer columns を追加 |
| 仕様 | `minimum` / `maximum` / `minLength` / `maxLength` / `pattern` / `format` / `nullable`、`printer_column :name, json_path:, type:` |
| 制約 | issue #15 残部 (複数形化 / shortNames は実装済み) |

#### FR-20: Scaffold 完全化

| 項目 | 内容 |
|---|---|
| 識別子 | FR-20 |
| 説明 | init / create api が kubebuilder 相当のビルド・デプロイ資産を生成 |
| 仕様 | Makefile (install/run/manifests/build/docker-build/docker-push/deploy/undeploy/test)、Dockerfile、Kustomize 構成 (config/{crd,rbac,manager,default})、config/samples、.github/workflows CI、.dockerignore |
| 制約 | RBAC の使用 API からの自動生成 (marker 相当) は簡易対応にとどめる (O-04) |

#### FR-21: Validating / Mutating Webhook

| 項目 | 内容 |
|---|---|
| 識別子 | FR-21 |
| 説明 | admission webhook の受信・応答 (旧 O-01 昇格) |
| 仕様 | DSL で validate / mutate 登録、`AdmissionReview` (admission.k8s.io/v1) 受信 → `AdmissionResponse` 応答、TLS、`kruby-controller create webhook` コマンド。明示的な検証 NG は `allowed: false` + status、ハンドラ例外は HTTP 5xx で応答し failurePolicy に委ねる |
| 制約 | failurePolicy (Fail 既定 / Ignore)。TLS 取得方式は未確定 (設計書 Q2) |

#### FR-22: Conversion Webhook

| 項目 | 内容 |
|---|---|
| 識別子 | FR-22 |
| 説明 | CRD version conversion webhook (旧 O-02 昇格) |
| 仕様 | CRD DSL に複数 version 宣言、`conversion.webhook` への応答 |
| 制約 | F-21 のサーバー基盤を共用。F-21 実装後に着手 |

#### FR-23: Metrics

| 項目 | 内容 |
|---|---|
| 識別子 | FR-23 |
| 説明 | Prometheus 互換 `/metrics` エンドポイント (旧 O-03 昇格) |
| 仕様 | `controller_reconcile_total{controller,result}`、`controller_reconcile_duration_seconds`、`workqueue_depth`、`workqueue_queue_duration_seconds`、`leader_elected` |
| 制約 | 実装方式 (gem 追加 vs 自前テキスト出力) は未確定 (設計書 Q1) |

#### FR-24: Typed Resource Accessor

| 項目 | 内容 |
|---|---|
| 識別子 | FR-24 |
| 説明 | CRD DSL から型付きアクセサを生成 (O-04 の簡易版) |
| 仕様 | `cron_task.spec.schedule` 等、spec/status の DSL 宣言済みパスに `define_method` で読み取りアクセサを生成 |
| 制約 | 内部データは Hash のまま保持 (読み取りビュー)。完全な型生成は O-04 のまま将来検討 |

---

## 4. 非機能的要件

| ID | 要件 | 値 |
|---|---|---|
| NFR-01 | Ruby バージョン | 3.3+ (kruby と同じ) |
| NFR-02 | 依存 kruby | `kruby ~> 1.36` |
| NFR-03 | パッケージ形式 | Ruby Gem (gemspec) |
| NFR-04 | CLI 実行環境 | Ruby 3.3+ で `bundle exec kruby-controller` |
| NFR-05 | スレッドセーフ | shared cache はスレッドセーフであること |
| NFR-06 | graceful shutdown | sigterm 受信後、最大 30 秒以内に停止 |
| NFR-07 | ロギング | `Logger` インターフェース準拠 (デフォルト: stdout)、ログレベル変更可能 |
| NFR-08 | 構成ファイル | `.kruby-controller.yml` (プロジェクト構成) |
| NFR-09 | 構造化ロギング | `Logger` 互換のまま JSON 出力オプションとレベル制御 (環境変数 `KRC_LOG_LEVEL` / `KRC_LOG_FORMAT`) を提供 |
| NFR-10 | 補助サーバーの非ブロック起動 | Probe / Metrics (Webhook 含む) の HTTP サーバーは別スレッドで起動し、Manager 停止時に確実に閉じる |

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
| ControllerClient | Reconciler に注入される統合 read/write クライアント (F-11) |
| EventRecorder | Kubernetes Events を送出するヘルパー (F-14) |
| Resync | Informer が watch 状態に依らず定期的に行う再同期 (F-16) |
| AdmissionReview | admission webhook のリクエスト/レスポンス形式 (admission.k8s.io/v1) |
| Probe | liveness / readiness を判定する HTTP エンドポイント (F-15) |

---

## 6. 依存・前提

| 依存 | 詳細 |
|---|---|
| kruby | Kubernetes API クライアント。Watch, ApiClient, Configuration を使用 |
| Kubernetes クラスター | 開発時は kind / minikube。運用時は任意の Kubernetes クラスタ |
| kubectl | CLI scaffolding で kubectl 構文を理解するために参照 (必須依存ではない) |
| events.k8s.io API | F-14 EventRecorder が使用 (ApiClient 経由) |
| admission.k8s.io | F-21 Webhook が受信するレビュー形式 (受信側のみ、クライアント API 不要) |
| cert-manager | F-21 Webhook の TLS 証明書 (本番前提。開発は self-signed、設計書 Q2) |

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
| 7 | 注入された client だけで reconcile が cache 読み + API 書き込みを完結できる (F-11/F-12) |
| 8 | hello-world (CronTask) が kind クラスターで端到端に動作する (Phase 4) |
| 9 | `/healthz` / `/readyz` が Kubernetes の probe として機能する (F-15) |
| 10 | reconcile の実行統計が `/metrics` で取得できる (F-23) |
| 11 | validate / mutate webhook が `AdmissionReview` v1 で応答し、動作する (F-21) |
| 12 | `init` 生成プロジェクトが `make deploy` (kind) まで通る (F-20) |
