# Kruby Controller Framework — 設計書 (Design Document)

| 項目 | 内容 |
|---|---|
| 名称 | **Kruby Controller Framework** (gem 名: `kruby-controller`) |
| 文書番号 | KRC-DES-001 |
| 仕様書参照 | [specification.md](./specification.md) |
| バージョン | Draft 0.3 |
| 日付 | 2026-10-31 |

**変更履歴**

| 版 | 日付 | 変更 |
|---|---|---|
| 0.1 | 2026-06-10 | 初版 |
| 0.3 | 2026-10-31 | 本家 v4.16.0 との再評価。実装状況・安全性の矛盾を修正し、追加要件と追跡先を対応表に整理。 |
| 0.2 | 2026-10-30 | kubebuilder 差分分析に基づく増補: F-11〜F-24 (Phase 5〜9) の設計追記 (§2.12〜§2.19)、実施順序の明記、未確定事項 (§11)、対応表 / kruby 依存 / エラーハンドリング / テスト戦略の更新。レビュー対応: events.k8s.io/v1 のフィールド名訂正 (regarding / note / reportingController / eventTime)、predicate 互換契約の明示化 (arity 判定の廃止)、定期 resync をキャッシュ全件の合成再配信に変更、merge-patch への resourceVersion 保持。再レビュー対応: handler の新形式判定を `method(:handle).parameters` に変更 (2 引数互換を維持)、`/readyz` をスタンバイ Ready 既定に変更 (`ready_gate: :leader` は Recreate 戦略前提)、merge-patch への限定 (json-patch は operations 別契約で将来対応)、webhook 例外 (HTTP 5xx) と明示拒否 (`allowed: false`) の分離、定期 resync を predicate 適用前配信に変更、events v1 必須フィールドの明記 |

---

## 1. アーキテクチャ概要

### 1.1 コンポーネント図

```
┌─────────────────────────────────────────────────────────┐
│                      Manager                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐ │
│  │ Shared Cache │  │  Leader      │  │  Signal        │ │
│  │ (Informer)   │  │  Election    │  │  Handler       │ │
│  └──────┬───────┘  └──────────────┘  └────────────────┘ │
│         │                                                │
│  ┌──────┴───────┐                                        │
│  │  Controller   │◄── User Reconciler                     │
│  │  (Reconcile   │    reconcile(request) → Result        │
│  │   Loop)       │                                        │
│  │  ┌─────────┐  │                                        │
│  │  │ Work    │  │                                        │
│  │  │ Queue   │  │                                        │
│  │  └─────────┘  │                                        │
│  └───────────────┘                                        │
│         │                                                  │
│  ┌──────┴───────┐                                          │
│  │ Event Handler│ ◄── Informer delta (Create/Update/Delete)│
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────┘
         │
         │ kruby (Kubernetes API Client)
         ▼
┌─────────────────────────────────────────────────────────┐
│              Kubernetes API Server                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │   LIST   │ │  WATCH   │ │  GET     │ │   PATCH   │  │
│  └──────────┘ └──────────┘ └──────────┘ └───────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 1.2 データフロー (Reconcile)

```
User applies CronTask → K8s API Server
                        │
Informer Watch ────────►│  (ADDED / MODIFIED / DELETED)
                        │
                        ▼
            ┌─────────────────┐
            │  Shared Cache   │  ← ローカルメモリに格納
            │  (delta push)   │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Event Handler   │  ← delta → reconcile request 変換
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │   Work Queue    │  ← 重複排除 + FIFO
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │  Reconcile Loop │  ← reconcile(request) 呼び出し
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ User Reconciler │  ← ビジネスロジック
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │    Result       │  ← retry_after / ok / requeue
            └─────────────────┘
```

---

### 1.3 追加コンポーネント (0.2 / Phase 5〜9)

kubebuilder 差分分析 (0.2) で追加するコンポーネント。既存コンポーネントの設計 (§2.1〜§2.11) は不変。

| コンポーネント | Phase | 役割 | 詳細 |
|---|---|---|---|
| `Client::ControllerClient` | 5 | Reconciler へ注入する統合 read/write クライアント | §2.12 |
| `Event::Predicates` | 6 | old/new 付きイベント predicate | §2.14 |
| `Recorder::EventRecorder` | 7 | Kubernetes Events 送出 | §2.15 |
| `Probe::Server` | 7 | /healthz, /readyz | §2.16 |
| `Metrics::Registry` | 7 | /metrics 出力 | §2.17 |
| `Webhook::Server` | 9 | AdmissionReview v1 受信 | §2.19 |

---

## 2. モジュール設計

### 2.1 全体構成 (Directory Layout)

```
kruby-controller/
├── lib/
│   ├── kruby-controller.rb            # entry point
│   └── kruby_controller/
│       ├── version.rb                 # VERSION
│       ├── manager.rb                 # Manager
│       ├── controller.rb              # Controller
│       ├── reconciler.rb              # Reconciler (abstract)
│       ├── request.rb                 # Request (namespace + name)
│       ├── result.rb                  # Result (ok, retry_after, requeue)
│       ├── cache/
│       │   ├── cache.rb               # SharedCache interface
│       │   ├── informer.rb            # Informer (List + Watch)
│       │   └── store.rb               # Thread-safe in-memory store
│       ├── queue/
│       │   └── work_queue.rb          # Deduplicating FIFO queue
│       ├── handler/
│       │   ├── enqueued_object.rb     # EnqueueRequestForObject
│       │   └── enqueued_owner.rb      # EnqueueRequestForOwner
│       ├── election/
│       │   └── leader_elector.rb      # Lease-based leader election
│       ├── builder/
│       │   ├── controller_builder.rb  # Fluent builder for Controller
│       │   └── manager_builder.rb     # Fluent builder for Manager
│       ├── finalizer/
│       │   └── finalizer_manager.rb   # add/remove/has finalizer
│       ├── owner/
│       │   └── owner_reference.rb     # set_owner_reference
│       ├── status/
│       │   └── status_updater.rb      # update_status helper
│       ├── generator/
│       │   ├── crd_generator.rb       # Ruby class → CRD YAML
│       │   └── schema_builder.rb      # OpenAPI v3 schema builder
│       ├── cli/
│       │   ├── init_command.rb        # `init` command
│       │   └── create_api_command.rb  # `create api` command
│       ├── logger.rb                  # Unified logger
│       ├── client/                    # [Phase 5]
│       │   └── controller_client.rb   # ControllerClient (cache read + API write)
│       ├── event/                     # [Phase 6]
│       │   ├── events.rb              # Create/Update/Delete/Generic
│       │   └── predicates.rb          # 事前定義 predicate
│       ├── recorder/                  # [Phase 7]
│       │   └── event_recorder.rb      # events.k8s.io/v1 Event 送出
│       ├── probe/                     # [Phase 7]
│       │   └── server.rb              # /healthz, /readyz
│       ├── metrics/                   # [Phase 7]
│       │   └── registry.rb            # /metrics (Prometheus text format)
│       └── webhook/                   # [Phase 9]
│           └── server.rb              # AdmissionReview v1 受信
├── exe/
│   └── kruby-controller               # CLI entry point
├── spec/
│   └── ...
└── kruby-controller.gemspec
```

---

### 2.2 Manager 設計

**役割**: フレームワークのエントリポイント。shared cache、leader election、コントローラー登録・起動、シグナル処理を一元管理。

#### API Surface

```ruby
class KrubyController::Manager
  # 初期化
  def initialize(
    kube_config: nil,                    # String | nil (nil=in-cluster)
    namespace: nil,                      # String | nil (nil=全namespace)
    leader_elect: true,                  # Boolean
    lease_name: "kruby-controller-lock", # String
    lease_namespace: "kube-system",       # String
    lease_duration: 15,                  # seconds
    renew_deadline: 10,                  # seconds
    retry_period: 2,                     # seconds
    logger: nil                          # Logger | nil
  )

  # コントローラー登録
  def add(controller_or_reconciler_class, **options)
    # options:
    #   for: "CronTask"                  # GVK/Kind
    #   group: "example.com"
    #   version: "v1"
    #   namespaced: true
    #   watches: [...]                   # 追加 watch 対象
    #   max_concurrent: 1                # 同時 reconcile 数
    #   reconciler_instance: object      # 既存インスタンスを使用
  end

  # fluent builder 経由の登録
  def for(kind)
    KrubyController::Builder::ControllerBuilder.new(self, kind)
  end

  # 起動 (blocking)
  def start

  # graceful shutdown
  def stop(timeout: 30)

  # 公開メソッド
  def cache                    # → SharedCache
  def leader?                  # → Boolean
  def stopped?                 # → Boolean
  def stop_channel             # → Channel (for external stop)
end
```

#### 内部アーキテクチャ

以下は修正後の起動・停止契約であり、現行コードの実装完了を示さない (#52 / #53)。

1. signal を安全に受け取る停止経路と補助サーバーを初期化し、controller の informer / handler を登録する。
2. leader election 有効時は standby として待機し、リーダー取得後に cache を開始する。無効時は直ちに cache を開始する。
3. 全 informer の初回同期完了を待つ。同期失敗・timeout・停止・リーダー喪失時は worker を開始しない。
4. 同期後に reconcile worker を開始する。同期中に queue に入った初回イベントを保持する。
5. いずれのモードでも `start` は停止まで待機する。停止処理は trap 内で mutex を直接操作せず、期限内に各コンポーネントを停止する。

readiness の standby / 昇格中の扱いは §2.16 を参照。失敗時の再起動・継続方針、期限超過時の挙動は #37 / #52 / #53 の検証時に確定する。

---

### 2.3 Shared Cache / Informer 設計

**役割**: Kubernetes リソースのローカルキャッシュを維持。List → Watch で初期化、watch event でインクリメンタル更新。

#### 2.3.1 SharedCache (Interface)

```ruby
class KrubyController::Cache::SharedCache
  # リソース種別を登録し、Informer を作成
  def register(gvk:, group:, version:, kind:, namespaced: true)
    # → Informer を返す
  end

  # 単一オブジェクト取得
  def get(gvk, namespace, name)
    # → kruby model object | nil
  end

  # リスト取得
  def list(gvk, namespace: nil, label_selector: nil, field_selector: nil)
    # → Array[kruby model]
  end

  # Informer が sync 完了するのを待機
  def wait_for_sync(timeout: 30)
    # → Boolean (成功したかどうか)
  end

  # カスタムインデックス登録
  def index_field(gvk, field_name, extract_func)
    # label_selector 以外のインデックスを作成
  end

  # インデックス付き検索
  def get_by_field(gvk, field_name, field_value, namespace: nil)
    # → Array[kruby model]
  end
end
```

#### 2.3.2 Informer (内部実装)

```ruby
class KrubyController::Cache::Informer
  # GVK → REST API path の変換
  REST_MAPPING = {
    # Namespaced: /apis/<group>/<version>/namespaces/<ns>/<plural>
    # Cluster-scoped: /apis/<group>/<version>/<plural>
  }

  def initialize(gvk:, cache_store:, api_client:, event_handlers: [])
    @gvk = gvk
    @store = cache_store  # ThreadSafeStore
    @api_client = api_client  # kruby ApiClient / CustomObjectsApi
    @handlers = event_handlers
    @resource_version = nil
    @running = false
  end

  # List → Watch を背景スレッドで実行
  def start
    @running = true
    @list_thread = Thread.new { populate }
    @watch_thread = Thread.new { watch_loop }
  end

  # 初回リスト取得 (#45: continue トークンを追跡し全ページ収集してから
  # 1 スナップショットとして atomic に反映。途中失敗は部分反映しない)
  def populate
    items, rv = fetch_all_pages   # 410 (continue 期限切れ) は先頭ページからやり直し
    items.each do |item|
      @store.add(Delta::ADDED, item)
    end
    @resource_version = rv   # RV が無い応答はプロトコル違反として失敗させる
    @synced = true
  end

  # Watch ループ (切断再試行付き)
  def watch_loop
    loop while @running do
      stream = WatchStream.new(@api_client)   # kruby の Watch ではなく自前ストリーム
      watch_path = rest_path_for(@gvk, action: :watch, rv: @resource_version)

      stream.connect(watch_path) do |event|
        case event['type']
        when 'ADDED', 'MODIFIED', 'DELETED'
          rv = event['object'].dig('metadata', 'resourceVersion')
          @resource_version = rv unless rv.nil? || rv.empty?   # RV を nil で壊さない
          @store.add(event_type(event), event['object'])
          @handlers.each { |h| h.handle(event_type(event), event['object']) }
        when 'BOOKMARK'
          rv = event['object'].dig('metadata', 'resourceVersion')
          @resource_version = rv unless rv.nil? || rv.empty?   # 有効な RV のみ更新
        when 'ERROR'
          raise WatchStream::Gone if event.dig('object', 'code') == 410   # 即 relist
          raise WatchStream::Error.new(code: event.dig('object', 'code')) # バックオフ後に relist
        else
          logger.warn("unclassified watch event: #{event['type'].inspect}")  # RV を壊さず無視
        end
      end
    rescue WatchStream::Gone
      relist   # 410 は新規 LIST から再開 (バックオフなし)
    rescue StandardError => e
      sleep [backoff_interval, e.retry_after].compact.max   # Retry-After を尊重
      relist
    end
  end

  def stop
    @running = false
    @list_thread&.join
    @watch_thread&.join
  end
end
```

#### 2.3.3 ThreadSafeStore

```ruby
class KrubyController::Cache::ThreadSafeStore
  # スレッドセーフなハッシュストア
  # namespace/name → object のインデックス
  # label → object[] のインデックス (オプション)

  def add(delta_type, obj)
    key = namespace_name_key(obj)
    @mutex.synchronize do
      case delta_type
      when Delta::ADDED, Delta::MODIFIED
        @store[key] = obj
        @label_index.rebuild_for(obj) if @label_index
      when Delta::DELETED
        @store.delete(key)
        @label_index&.remove(obj)
      end
    end
  end

  def get(namespace, name)
    @mutex.synchronize { @store[namespace_name_key(namespace, name)] }
  end

  def list(label_selector: nil, field_selector: nil)
    @mutex.synchronize do
      results = @store.values
      results = apply_label_selector(results, label_selector) if label_selector
      results = apply_field_selector(results, field_selector) if field_selector
      results
    end
  end
end
```

---

### 2.4 Controller 設計

**役割**: Reconcile Loop を実行。WorkQueue からリクエストを取り出し、Reconciler に.delegate。

```ruby
class KrubyController::Controller
  attr_reader :name, :reconciler

  def initialize(
    reconciler:,           # KrubyController::Reconciler のインスタンス
    cache:,                # SharedCache
    for_gvk:,              # GVK (watch 対象のプライマリリソース)
    max_concurrent: 1,     # 同時 reconcile スレッド数
    name: nil              # コントローラー名 (デフォルト: kind_lower-cased)
  )

  def start
    # 1. Informer から delta を WorkQueue にエンキュー
    informer = @cache.register(for_gvk)
    informer.add_handler(EnqueueRequestForObject.new(queue: @queue))

    # 2. max_concurrent 数のワーカーを起動
    @workers = (1..@max_concurrent).map do
      Thread.new { worker_loop }
    end
  end

  def worker_loop
    loop do
      request = @queue.get  # blocking
      begin
        result = @reconciler.reconcile(request)
        handle_result(result)
      rescue => e
        @logger.error("Reconcile error: #{e}")
        handle_error(e)
      ensure
        @queue.done(request)
      end
    end
  end

  def handle_result(result)
    case result
    when Result::Ok
      # nothing
    when Result::RetryAfter
      @queue.add_after(request, result.after)
    when Result::Requeue
      @queue.add(request)
    end
  end

  def stop
    @running = false
    @workers.each(&:join)
  end
end
```

---

### 2.5 Reconciler / Request / Result 設計

#### 2.5.1 Request

```ruby
class KrubyController::Request
  attr_reader :namespaced_name

  def initialize(namespace:, name:)
    @namespace = namespace
    @name = name
    @namespaced_name = NamespacedName.new(namespace, name)
  end

  def namespace; @namespace; end
  def name; @name; end

  def ==(other); namespaced_name == other.namespaced_name; end
  def hash; namespaced_name.hash; end
  def inspect; "#<Request #{namespaced_name}>"; end
end

# Value object
struct_namespaced_name = Struct.new(:namespace, :name) do
  def to_s; "#{namespace}/#{name}"; end
  def hash; [namespace, name].hash; end
  def ==(other); namespace == other.namespace && name == other.name; end
end
```

#### 2.5.2 Result

```ruby
module KrubyController::Result
  class Base
    attr_reader :error
    def initialize(error: nil); @error = error; end
  end

  class Ok < Base
    def self.ok(error: nil); new(error:); end
  end

  class RetryAfter < Base
    attr_reader :after
    def initialize(after:, error: nil); @after = after; super(error:); end
    def self.retry_after(seconds, error: nil); new(after: seconds, error:); end
  end

  class Requeue < Base
    def self.requeue(error: nil); new(error:); end
  end

  # convenience
  def self.ok(error: nil); Ok.ok(error:); end
  def self.retry_after(sec, error: nil); RetryAfter.retry_after(sec, error:); end
  def self.requeue(error: nil); Requeue.requeue(error:); end
end
```

#### 2.5.3 Reconciler (Abstract)

```ruby
class KrubyController::Reconciler
  # サブクラスで override する
  def reconcile(request)
    raise NotImplementedError, "Subclass must implement reconcile(request)"
  end

  # ヘルパー (mix-in 相当)
  def logger
    @logger || Logger.new($stdout)
  end

  def logger=(l)
    @logger = l
  end

  # inject by Manager
  def cache=(c)
    @cache = c
  end

  def api_client=(c)
    @api_client = c
  end

  def client=(c)
    @client = c
  end
end
```

---

### 2.6 Work Queue 設計

**役割**: 重複排除付き FIFO キュー。reconcile リクエストをバッファリング。

```ruby
class KrubyController::Queue::WorkQueue
  def initialize
    @queue = Queue.new       # Ruby's thread-safe Queue
    @known = Set.new         # 重複排除用
    @mutex = Mutex.new
  end

  def add(request)
    key = request.namespaced_name.to_s
    @mutex.synchronize do
      return if @known.include?(key)  # 重複排除
      @known.add(key)
      @queue << request
    end
  end

  def add_after(request, seconds)
    # 遅延再試行は共有スケジューラ (キューあたりスレッド1本) が期限順に発火する。
    # リクエストごとのスレッドは生成しない (障害時のスレッド数は O(1))。
    scheduler.schedule(request, delay: seconds)
  end

  def get  # blocking
    @queue.pop
  end

  def done(request)
    key = request.namespaced_name.to_s
    @mutex.synchronize do
      @known.delete(key)  # 再エンキュー可能に
    end
  end

  def len
    @queue.length
  end

  def shutdown
    # 実装依存: Queue#close 相当
  end
end
```

---

### 2.7 Event Handler 設計

```ruby
# デフォルト: オブジェクト自身をエンキュー
class KrubyController::Handler::EnqueueRequestForObject
  def initialize(queue:)
    @queue = queue
  end

  def handle(delta_type, obj)
    ns = obj['metadata']['namespace'] || ''
    name = obj['metadata']['name']
    @queue.add(KrubyController::Request.new(namespace: ns, name: name))
  end
end

# Owner Reference 経由で親をエンキュー
class KrubyController::Handler::EnqueueRequestForOwner
  def initialize(queue:, owner_gvk:)
    @queue = queue
    @owner_gvk = owner_gvk
  end

  def handle(delta_type, obj)
    owners = obj['metadata']['ownerReferences'] || []
    owners.each do |owner|
      next unless owner_matches?(owner, @owner_gvk)
      @queue.add(KrubyController::Request.new(
        namespace: obj['metadata']['namespace'],
        name: owner['name']
      ))
    end
  end
end
```

---

### 2.8 Leader Election 設計

**役割**: Kubernetes Lease API (coordination.k8s.io/v1) によるリーダー選出。

```ruby
class KrubyController::Election::LeaderElector
  def initialize(
    client:,                 # CoordinationV1Api
    lease_name:,
    lease_namespace:,
    lease_duration:,         # default 15s
    renew_deadline:,         # default 10s
    retry_period:,           # default 2s
    identity:,               # Pod name or hostname
    on_started_leading:,     # → コントローラー起動
    on_stopped_leading:,     # → コントローラー停止
  )

  def run
    loop while @running do
      if try_acquire_lease
        @on_started_leading.call
        renewal_loop
      else
        sleep @retry_period
      end
    end
  end

  def try_acquire_lease
    lease = get_or_create_lease
    if lease_can_be_acquired?(lease)
      update_lease(lease, identity: @identity, duration: @lease_duration)
      true
    else
      false
    end
  end

  def renewal_loop
    while @running && @is_leader
      remaining = time_until_expiry
      if remaining < @renew_deadline
        update_lease(lease, identity: @identity, duration: @lease_duration)
      end
      sleep [@retry_period, remaining / 3].min
    end
    @on_stopped_leading.call if @is_leader
  end
end
```

---

### 2.9 CRD Generator 設計

**役割**: Ruby クラスの属性定義から CRD YAML (OpenAPI v3 schema) を生成。

#### 2.9.1 Attribute DSL

```ruby
# 利用者が CRD のスキーマを定義
class CronTask
  include KrubyController::CRD

  self.group = "stable.example.com"
  self.version = "v1"
  self.kind = "CronTask"
  self.namespaced = true

  # Spec
  attribute :schedule,    type: :string, required: true,
              description: "Cron 表現"
  attribute :image,       type: :string, required: true,
              description: "コンテナーイメージ"
  attribute :replicas,    type: :integer, default: 1,
              description: "レプリカ数"
  attribute :enabled,     type: :boolean, default: true

  # Status
  status_attribute :last_schedule, type: :string,
                     description: "直前のスケジュール時刻"
  status_attribute :active_job,    type: :string,
                     description: "現在実行中の Job 名"

  # Enum / 列挙
  attribute :priority, type: :string,
              enum: ["low", "medium", "high"],
              default: "medium"

  # Nested object
  attribute :notification, type: :object, properties: {
    channel: { type: :string },
    webhook_url: { type: :string },
  }

  # Array of strings
  attribute :labels, type: :array, items: { type: :string }
end
```

#### 2.9.2 CRD Generator

```ruby
class KrubyController::Generator::CrdGenerator
  def initialize(klass)
    @klass = klass
  end

  def generate
    {
      apiVersion: "apiextensions.k8s.io/v1",
      kind: "CustomResourceDefinition",
      metadata: {
        name: "#{plural}.#{group}"
      },
      spec: {
        group: group,
        names: names_spec,
        scope: @klass.namespaced? ? "Namespaced" : "Cluster",
        versions: [version_spec],
      }
    }
  end

  def version_spec
    {
      name: version,
      served: true,
      storage: true,
      subresources: subresources_spec,
      schema: {
        open_api_v3_schema: {
          type: "object",
          properties: {
            spec: spec_schema,
            status: status_schema,
          }
        }
      }
    }
  end

  def spec_schema
    build_schema_from_attributes(@klass.spec_attributes)
  end

  def status_schema
    build_schema_from_attributes(@klass.status_attributes)
  end

  def build_schema_from_attributes(attrs)
    {
      type: "object",
      properties: attrs.transform_values { |a| attribute_to_schema(a) },
      required: attrs.select { |_k, v| v.required? }.keys,
    }
  end

  def attribute_to_schema(attr)
    schema = { type: kruby_type_to_openapi(attr.type) }
    schema[:description] = attr.description if attr.description
    schema[:default] = attr.default unless attr.default.nil?
    schema[:enum] = attr.enum if attr.enum
    schema[:properties] = build_schema_from_attributes(attr.properties) if attr.properties
    schema[:items] = attribute_to_schema(attr.items) if attr.items
    schema
  end

  TYPE_MAP = {
    string: "string",
    integer: "integer",
    float: "number",
    boolean: "boolean",
    object: "object",
    array: "array",
  }.freeze
end
```

#### 2.9.3 出力例

```yaml
# config/crd/bases/stable.example.com_crontasks.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: crontasks.stable.example.com
spec:
  group: stable.example.com
  names:
    plural: crontasks
    singular: crontask
    kind: CronTask
    shortNames:
      - ct
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                  description: Cron 表現
                image:
                  type: string
                  description: コンテナーイメージ
                replicas:
                  type: integer
                  default: 1
                  description: レプリカ数
                enabled:
                  type: boolean
                  default: true
                priority:
                  type: string
                  enum:
                    - low
                    - medium
                    - high
                  default: medium
                notification:
                  type: object
                  properties:
                    channel:
                      type: string
                    webhook_url:
                      type: string
                labels:
                  type: array
                  items:
                    type: string
              required:
                - schedule
                - image
            status:
              type: object
              properties:
                last_schedule:
                  type: string
                  description: 直前のスケジュール時刻
                active_job:
                  type: string
                  description: 現在実行中の Job 名
```

---

### 2.10 CLI 設計

#### 2.10.1 CLI エントリポイント

```
exe/kruby-controller
```

```ruby
#!/usr/bin/env ruby
require "kruby-controller"

ARGV.shift case ARGV.first
when "init"
  KrubyController::CLI::InitCommand.new(ARGV).run
when "create"
  case ARGV.shift
  when "api"
    KrubyController::CLI::CreateApiCommand.new(ARGV).run
  else
    puts "Unknown create subcommand: #{ARGV.first}"
  end
else
  puts "Usage: kruby-controller {init|create api}"
end
```

#### 2.10.2 `init` コマンド

```
kruby-controller init \
  --domain example.com \
  --repo my.example.com/my-controller \
  --license apache2
```

**出力**:

```
my-controller/
├── Gemfile
├── Rakefile
├── .kruby-controller.yml
├── bin/
│   └── manager                # ruby bin/manager
├── config/
│   ├── crd/
│   │   └── bases/
│   ├── rbac/
│   │   └── role.yaml
│   └── default.yaml
├── cmd/
│   └── manager.rb
├── pkg/
│   ├── crds/                  # CRD クラス定義
│   ├── reconcilers/           # Reconciler 実装
│   └── controller_suite_test.rb
└── docs/
```

**生成ファイルの中身 (一部)**:

```ruby
# cmd/manager.rb
require "kruby-controller"
require_relative "../pkg/crds/cron_task"
require_relative "../pkg/reconcilers/cron_task_reconciler"

manager = KrubyController::Manager.new(
  kube_config: ENV["KUBECONFIG"],
  leader_elect: true,
)

manager.add(CronTaskReconciler, for: CronTask)
manager.start
```

```yaml
# .kruby-controller.yml
domain: example.com
repo: my.example.com/my-controller
license: apache2
```

#### 2.10.3 `create api` コマンド

```
kruby-controller create api \
  --group stable \
  --version v1 \
  --kind CronTask \
  --namespaced \
  --resource \
  --controller \
  --make
```

**出力**:

1. `pkg/crds/cron_task.rb` — CRD クラス定義
2. `pkg/reconcilers/cron_task_reconciler.rb` — Reconciler スケルトン
3. `config/crd/bases/stable.example.com_crontasks.yaml` — CRD YAML
4. `config/rbac/cron_task_role.yaml` — RBAC スケルトン
5. `cmd/manager.rb` の `manager.add(...)` を追記

---

### 2.11 ヘルパーモジュール

#### 2.11.1 Finalizer Manager

```ruby
class KrubyController::Finalizer::FinalizerManager
  def initialize(client:, gvk:)
    @client = client  # CustomObjectsApi or typed client
    @gvk = gvk
  end

  def add_finalizer(obj, finalizer)
    return if (obj['metadata']['finalizers'] || []).include?(finalizer)
    merged = deep_merge(obj, {
      metadata: {
        finalizers: (obj['metadata']['finalizers'] || []) + [finalizer]
      }
    })
    @client.update(merged)
  end

  def remove_finalizer(obj, finalizer)
    finalizers = (obj['metadata']['finalizers'] || []) - [finalizer]
    merged = deep_merge(obj, { metadata: { finalizers: } })
    @client.update(merged)
  end

  def has_finalizer?(obj, finalizer)
    (obj['metadata']['finalizers'] || []).include?(finalizer)
  end

  def deleting?(obj)
    obj['metadata']['deletionTimestamp'] && !obj['metadata']['deletionTimestamp'].empty?
  end
end
```

#### 2.11.2 Owner Reference

```ruby
module KrubyController::Owner::OwnerReference
  def self.set_owner(object, owner, controller: false, block_owner_deletion: false)
    ref = {
      apiVersion: owner['apiVersion'],
      kind: owner['kind'],
      name: owner['metadata']['name'],
      uid: owner['metadata']['uid'],
    }
    ref['controller'] = controller if controller
    ref['blockOwnerDeletion'] = block_owner_deletion if block_owner_deletion

    object['metadata']['ownerReferences'] ||= []
    object['metadata']['ownerReferences'] << ref
    object
  end
end
```

#### 2.11.3 Status Updater

```ruby
class KrubyController::Status::StatusUpdater
  def initialize(client:, gvk:)
    @client = client
    @gvk = gvk
  end

  # status だけを PATCH (spec は触らない)
  def update_status(obj, status_patch)
    patched = deep_merge(obj, { status: status_patch })
    @client.patch_status(patched)  # /status subresource
  end

  # 既存 status とマージ
  def merge_status(obj, status_update)
    current = obj['status'] || {}
    merged = deep_merge(current, status_update)
    update_status(obj, merged)
  end
end
```

**0.2 追記**: Phase 5 (F-11/F-13) 以降は、`client:` に §2.12 の `ControllerClient` を渡すことで `update` / `patch_status` に resourceVersion による競合検知を導入できる。再試行は §2.12.3 に従い変更を再計算する。`KubernetesObjectClient` は後方互換のため残存するが、新規コードでの利用は非推奨とする。

---

### 2.12 ControllerClient + Reconciler への依存注入 (F-11 / F-12 / F-13)

kubebuilder の `client.Client` 相当。Reconciler が cache 読みと API 書き込みを単一の注入オブジェクトで行えるようにする。

#### 2.12.1 ControllerClient (Interface)

```ruby
class KrubyController::Client::ControllerClient
  def initialize(cache:, api_client:, gvk:)  # gvk: 注入元コントローラーの primary GVK

  # --- read (cache-backed) ---
  # 当該 GVK が SharedCache に watch 登録済み → キャッシュから返す
  # 未登録 → kruby ApiClient で直接 GET / LIST (JSON Hash を返す)
  def get(gvk, namespace, name)
  def list(gvk, namespace: nil, label_selector: nil)

  # --- write (ApiClient#build_request で直接構築) ---
  def create(obj)                 # POST collection path
  def update(obj)                 # PUT object path。409 → ConflictError (F-13)
  def patch(obj)                  # PATCH merge-patch+json。ボディに metadata.resourceVersion を含める (競合検知)。json-patch は Phase 5 対象外 (§2.12.3 参照)
  def delete(obj)                 # DELETE object path
  def patch_status(obj, status_patch = nil)  # PATCH {object_path}/status (merge-patch)
end
```

- `update` / `patch_status` は既存 `KubernetesObjectClient` と同一の契約 (`#update(obj)`, `#patch_status(obj)`) を持つため、`FinalizerManager` / `StatusUpdater` にそのまま渡せる (§2.11)。
- `patch_status(obj, status_patch)` に第 2 引数を渡した場合は obj に status を deep-merge してから PATCH する。
- リソースパス構築 (`/apis/<group>/<version>[namespaces/<ns>]/<resource>`) は `KubernetesObjectClient` の実装を流用する。

#### 2.12.2 注入経路 (F-12)

```
Manager#add
  └─ Controller.new(..., client: Client::ControllerClient.new(
         cache: @cache, api_client: api_client, gvk: resolved_gvk))
       └─ Controller#initialize
            @reconciler.client     = client      # F-11
            @reconciler.api_client = api_client  # 下位互換 (既存 attr_accessor)
            @reconciler.cache      = cache       # 下位互換
            @reconciler.logger     = logger
```

- 後方互換: 既存 Reconciler (api_client を手動構築していたもの) も attr_accessor 契約が維持されるため動作に影響しない。
- api_client は SharedCache と同じ `Kubernetes::ApiClient` インスタンスを流用し、接続設定を二重化しない。
- recorder は Phase 7 (F-14) 実装後に `@reconciler.recorder = manager.recorder_for(name)` で追加注入する。

#### 2.12.3 競合検知 (F-13)

- PUT は取得時の `metadata.resourceVersion` を使い、競合時は `ConflictError` として返す。無条件の古いオブジェクト再送や resourceVersion の付け替えを行わない。
- merge patch / status patch の競合検知を要求する場合は `metadata.resourceVersion` を含め、409 を返す。JSON Patch は operations と `test` の契約を別途定義する。
- 自動リトライを提供する場合、API サーバーから再取得した最新オブジェクトに対し、呼び出し元の変更処理を毎回再実行する明示的なブロック API とし、回数・バックオフ・削除時の挙動を定義する。副作用はブロック外に置く。異なるフィールドの保持と同一フィールド競合を実 API で検証する。

### 2.13 キャッシュ拡張: Resync / Server-side Selector / Field Index (F-16 / F-18 / issue #16)

#### 2.13.1 定期 Resync (F-16)

- Informer に timer スレッドを追加し、`resync_period` 秒ごとに **ストア内の全オブジェクトを合成 delta として handler に再配信する** (client-go の resync 相当)。§2.3.2 の relist が発行するのは「差分だけのイベント」(resourceVersion が変わっていないオブジェクトにはイベントが飛ばない) のため、relist 差分を流用した定期同期では外部状態のドリフトを修復できない。resync は API List を伴わないローカル処理とし、全オブジェクトを無条件に再配信する。
- 既定値: 10h (controller-runtime SyncPeriod 相当)。`Manager.new(resync_period:)` → SharedCache → Informer へ伝播。`0` / `nil` で無効。
- 合成 Update は old/new に同じスナップショットを指定し、通常の predicate を通す。GenerationChanged 等で拒否される場合、外部状態の定期確認には `retry_after` を使う。これは controller-runtime の SyncPeriod の意味論に合わせる。
- watch 切断時の relist (新鮮な List + 差分配信) は従来どおり維持する。relist は watch スレッド上で `watch_once` が終了した後にのみ実行されるため、watch 中の delta と relist snapshot の競合 (古い List でストア / resourceVersion を巻き戻す) は発生しない。Phase 6 実装でも relist を timer スレッドから直接呼ばないこと。
- 負荷特性は §9.5 参照。

#### 2.13.2 Server-side Selector (F-18)

- `register(gvk:, label_selector:, field_selector:)` を追加し、List / Watch URL に `labelSelector` / `fieldSelector` を URL エンコードして付与する。
- watch 切断時の relist も同一条件で再取得するため、ストアは同期後に選択集合に収束する。合致から非合致への変更は削除イベントとして扱い、非合致中の変更・削除は観測できない。接続断・処理遅延中の即時整合性は保証しない。定期 resync (§2.13.1) は既存ストアの再配信であり、再取得は行わない。
- 既存 `SharedCache#list` のクライアント側フィルタは残置 (後方互換) し、サーバー側フィルタを第一に使う。

#### 2.13.3 Field Index (issue #16, §2.3.1 で既に定義)

- Store に `field_index[name][value] → Set(key)` を追加し、ADDED / MODIFIED / DELETED の適用時に増分更新する。
- `index_field(gvk, field_name, extract_func)` の登録時点で全オブジェクトを一括索引化する (登録前のオブジェクトも含む)。
- `get_by_field(gvk, field_name, field_value, namespace:)` → 索引から取得。

### 2.14 Predicate 拡張 (F-17)

kubebuilder の `predicate.UpdateEvent` (ObjectOld / ObjectNew) 相当。

```ruby
# イベント値オブジェクト (Phase 6)
KrubyController::Event::Create.new(object:)
KrubyController::Event::Update.new(object_old:, object_new:)
KrubyController::Event::Delete.new(object:)
KrubyController::Event::Generic.new(object:)

# 事前定義 predicate (EventPredicate インスタンス)
KrubyController::Event::Predicates.generation_changed  # old.generation != new.generation
KrubyController::Event::Predicates.always

# イベント型 predicate は明示的に包む
manager.for(CronTask).with_predicate(KrubyController::Predicate.event { |event| event.generation_changed? })

# 従来形 (obj 受け取り) はそのまま
manager.for(CronTask).with_predicate(->(obj) { obj.dig("metadata", "labels", "team") == "infra" })
```

- 互換契約: predicate の種別は `arity` ではなく **包む型** (`Predicate::EventPredicate` か素の proc か) で判定する。`EventPredicate` と事前定義 predicate には `Event::*` を渡し、素の proc / lambda には従来どおり生 Hash を渡す。(初版に書いた「arity 1 で従来形と判定」は、イベント型 lambda も arity 1 になるため破綻する — 0.2 レビューで廃止)
- old の供給と handler 互換: Informer は delta 適用前の値を保持しており、配信時に old_obj を渡せる。ただし既存 handler (`EnqueuedObject` / `EnqueuedOwner` / ユーザー定義) の `handle` は固定 2 引数メソッドで、`old_obj:` をそのまま渡すと `ArgumentError (given 3, expected 2)` となり、Informer の例外処理でイベントが破棄される。そこで配信の判定は `handler.method(:handle).parameters` に `old_obj` キーワードが存在するかで行う:
  - 新形式 (`def handle(type, obj, old_obj: nil)` — `old_obj` キーワードあり) → old_obj を渡す。組み込み handler (`EnqueuedObject` / `EnqueuedOwner` / `Predicated`) はこの署名に更新する。
  - 従来形式 (2 引数) → 従来どおり `handle(type, obj)` で呼ぶ。既存の 2 引数カスタム handler は無変更で動作する。
  (predicate と異なり handler は 2 引数か keyword かで署名が分かれるため、`parameters` 判定で両形式を確実に識別できる。初版に書いた「余分な引数は無視される」は Ruby メソッドには当てはまらない — 0.2 レビューで修正)
- `Predicated` は old_obj を受け取った場合に old / new から `Event::Update` を構築する。`Predicated` から下位 handler への配信も同じ判定 (`parameters` による新旧判定) に従う。

### 2.15 EventRecorder (F-14)

kubebuilder の `record.EventRecorder` / `mgr.GetEventRecorderFor` 相当。

```ruby
class KrubyController::Recorder::EventRecorder
  def initialize(client:, component:)   # client: ApiClient (events.k8s.io/v1)

  # type: :normal | :warning
  def event(object, type:, reason:, message:)
  def eventf(object, type:, reason:, format:, *args)
end

# Manager からコントローラー単位で取得
recorder = manager.recorder_for("cron-task")
```

| 項目 | 設計 |
|---|---|
| API | `POST /apis/events.k8s.io/v1/namespaces/<ns>/events` (events.k8s.io/v1 Event) |
| v1 スキーマ準拠 | ペイロードは v1 フィールド名を使用: `regarding` / `note` / `reportingController` / `reportingInstance` / `eventTime`。`action` / `reason` / `reportingController` / `reportingInstance` は新規 v1 Event で必須 (常に設定する)。core/v1 由来の deprecated フィールド (`involvedObject` / `source` / `firstTimestamp` / `lastTimestamp` / `count`) は使用しない — 新規 v1 Event では不許可 (`deprecatedFirstTimestamp` 等への互換設定が必要な場合のみ使用可) |
| 非同期 | 送信は専用ワーカースレッド + 有界キュー (既定 256)。溢れた場合は捨てて warn ログ (reconcile を失敗させない) |
| 重複抑止 | `(regarding.uid, reason, note)` をキーに同一イベントを series (count, lastObservedTime) の増分 PATCH で集約 |
| DSL の引数名 | `event(object, type:, reason:, message:)` の `message:` は payload の `note` に写像する |
| 失敗 | ログのみ。reconcile のエラーにはしない (§5) |
| RBAC | `events` の create / patch / update を scaffold (§2.18) に追加 |

### 2.16 Health Probe (F-15)

| 項目 | 設計 |
|---|---|
| エンドポイント | `GET /healthz` (プロセス生存: 常時 200) / `GET /readyz` — 既定は初期化済みかつ (スタンバイ、またはリーダーで全 informer synced) なら 200。昇格時は同期完了まで 503。`ready_gate: :leader` オプションで「リーダー取得済みかつ cache 同期済みの場合のみ 200」に変更できる |
| readyz の意味論 | キャッシュはリーダー取得後に開始する現行方式を維持し、待機中は同期済みを要求しない。失敗・停止中は 503。スタンバイ Ready を既定にする。リーダーのみ Ready にすると、RollingUpdate の単一レプリカ構成では「新 Pod がリース待ちで Ready にならない ↔ Kubernetes が新 Pod の Ready を待って旧 Pod を終了しない」のデッドロックでロールアウトが停止する。リーダーのみ Ready を使う場合は Deployment を Recreate 戦略にする必要がある |
| 実装 | 依存追加なしの軽量 HTTP サーバー (TCPServer + accept スレッド、GET のみ)。WEBrick は Ruby 3.0+ で bundled gem 化しており、依存追加を避ける (§9.6) |
| 設定 | `Manager.new(health_bind_address: "0.0.0.0:8081")` / `nil` で無効 |
| 起動 | Manager#start で非ブロック起動、stop 時に確実に閉じる (NFR-10) |
| bind 失敗 | Manager 起動失敗 (設定エラーとして表面化) |
| scaffold | §2.18 の Deployment に liveness (`/healthz`) / readiness (`/readyz`) を追加。既定は RollingUpdate + スタンバイ Ready 形。リーダーのみ Ready を選んだ場合は Recreate 戦略への変更を scaffold 注記で促す |

### 2.17 Metrics (F-23, 旧 O-03)

| 項目 | 設計 |
|---|---|
| エンドポイント | `GET /metrics` — `metrics_bind_address` (既定 nil = 無効) |
| 指標 | `controller_reconcile_total{controller,result}` (ok / error / requeue / retry)、`controller_reconcile_duration_seconds` (histogram)、`workqueue_depth{controller}`、`workqueue_queue_duration_seconds` (histogram)、`leader_elected` (gauge) |
| 実装方式 | Q1: `prometheus_client` gem を依存追加するか、テキスト形式を自前実装するか (依存最小方針と天秤)。Phase 7 設計時に決定 |
| 基盤 | Probe (§2.16) とはアクセス制御を分離する。ネットワーク公開時は TLS + 認証・認可を必須とし、未保護の有効化は明示的な選択とする。詳細は [差分評価](./parity-review.md) |

### 2.18 Scaffolding 完全化 + CRD DSL 拡張 (F-19 / F-20 / F-24)

#### 2.18.1 Makefile / Dockerfile / Kustomize / CI (F-20)

`init` が追加生成するファイル:

| ファイル | 内容 |
|---|---|
| `Makefile` | `install` (CRD apply), `uninstall`, `run` (ローカル実行), `manifests` (CRD YAML 再生成), `build`, `docker-build`, `docker-push`, `deploy`, `undeploy`, `test` |
| `Dockerfile` | `ruby:3.3-slim` ベース、`bundle install`、`CMD ["bin/manager"]`。buildx で linux/amd64 + linux/arm64 |
| `.dockerignore` | spec/, docs/, .git など |
| `config/kustomization.yaml` ほか | Kustomize 構成 (`config/{crd,rbac,manager,default}`) |
| `config/samples/<group>_<plural>_sample.yaml` | `create api` がサンプルを生成 |
| `.github/workflows/ruby.yml` | rubocop + rspec の CI |

`create api` も Kustomize 構成への CRD / RBAC 追記に対応する。RBAC は使用 API の推測ではなく明示的宣言から Role / ClusterRole を生成することを別途追跡する ([差分評価](./parity-review.md))。

#### 2.18.2 CRD DSL 検証制約 (F-19, issue #15 残部)

```ruby
attribute :replicas, type: :integer,
  minimum: 1, maximum: 100, nullable: false
attribute :name, type: :string,
  pattern: "^[a-z0-9-]+$", min_length: 1, max_length: 63

# additionalPrinterColumns
printer_column :age, json_path: ".metadata.creationTimestamp", type: :date
printer_column :priority, json_path: ".spec.priority", type: :string
```

- 複数形化 / shortNames は既に実装済み。残課題は additionalPrinterColumns と上記制約の出力 (issue #15)。
- 複数 version CRD (served / storage の切替) は F-22 と一体で対応する (Phase 9)。

#### 2.18.3 Typed Resource Accessor (F-24, O-04 の簡易版)

- CRD DSL から `define_method` で spec / status パスの読み取りアクセサを生成する (`cron_task.spec.schedule` 等)。内部データは Hash のまま保持する。
- 型生成の完全互換は対象外。ただしキャッシュ内の可変 Hash の参照共有は危険なため、読み出し側に独立したスナップショットを返す。schema 定義と実データの乖離チェックは別途検討する。

### 2.19 Webhook (F-21 / F-22, 旧 O-01 / O-02)

#### 2.19.1 Validating / Mutating (F-21)

```ruby
class CronTask
  include KrubyController::CRD

  # Validating
  validate :schedule_format do |obj, errors|
    errors.add(:schedule, "invalid cron") unless valid_cron?(obj)
  end

  # Mutating (defaulting)
  mutate :defaults do |obj|
    obj["spec"]["replicas"] ||= 1
  end
end
```

| 項目 | 設計 |
|---|---|
| サーバー | `Webhook::Server` (§2.16 と同基盤 + TLS)。`AdmissionReview` (admission.k8s.io/v1) 受信 → `AdmissionResponse` 応答 |
| TLS | cert-manager 前提 (scaffold に Certificate 生成 + annotation)。dev は self-signed (Q2) |
| failurePolicy | webhook 登録時に指定 (既定 Fail / Ignore) |
| CLI | `kruby-controller create webhook` — ValidatingWebhookConfiguration 等の manifest 生成 |
| 例外時 | validate / mutate の例外 → HTTP 5xx 応答 (failurePolicy に従う: Fail → deny / Ignore → allow)。一方、明示的な検証 NG は AdmissionResponse `allowed: false` + `status` (message) で応答し、failurePolicy の影響を受けない。両者を混同すると `failurePolicy: Ignore` 下でも例外が「明示的拒否」として処理停止を招くため区別する (§5) |

#### 2.19.2 Conversion (F-22)

- CRD DSL に複数 version 宣言 (`self.versions = [:v1, :v1beta1]`) と変換フックを追加。
- `apiextensions.k8s.io/v1` の `conversion.webhook` に応答する。サーバー基盤は F-21 と共用。
- 単一 version 運用では不要なため、F-21 実装後に着手する。

---

## 3. Controller Builder (Fluent API)

kubebuilder の `controller.For()` / `.Owns()` / `.Watches()` 相当。

```ruby
# Manager#for は Builder を返す
manager.for(CronTask).
  owns(V1Job).
  owns(V1Pod).
  watches(V1ConfigMap,
    predicate: kruby_predicate { |obj| obj['metadata']['labels']['managed-by'] == 'cron' },
    handler: EnqueueRequestForObject.new(queue:)).
  with_max_concurrent_reconciles(3).
  complete_with(CronTaskReconciler.new)
```

### Builder API

```ruby
class KrubyController::Builder::ControllerBuilder
  def initialize(manager, for_gvk)
    @manager = manager
    @for_gvk = for_gvk
    @owns = []
    @watches = []
    @predicate = nil
    @max_concurrent = 1
  end

  def for(gvk)
    @for_gvk = gvk
    self
  end

  def owns(gvk)
    @owns << gvk
    self
  end

  def watches(gvk, predicate: nil, handler: nil)
    @watches << { gvk:, predicate:, handler: }
    self
  end

  def with_max_concurrent_reconciles(n)
    @max_concurrent = n
    self
  end

  def with_predicate(predicate)
    @predicate = predicate
    self
  end

  def complete_with(reconciler_instance)
    controller = KrubyController::Controller.new(
      reconciler: reconciler_instance,
      cache: @manager.cache,
      for_gvk: @for_gvk,
      owns: @owns,
      watches: @watches,
      predicate: @predicate,
      max_concurrent: @max_concurrent,
    )
    @manager.add(controller)
  end
end
```

---

## 4. スレッドモデル

Ruby の GIL により、CPU バウンドの並列処理は限定的だが、I/O バウンド (Kubernetes API 呼び出し、Watch 接続) はスレッド間で並行可能。

```
Main Thread
  ├─ Manager.start (blocking, signal handler)
  │
  ├─ [SharedCache]
  │   └─ Per-GVK Informer Threads (1+ per resource type)
  │       ├─ List thread (初回のみ)
  │       └─ Watch thread (永続)
  │
  ├─ [LeaderElection]
  │   └─ Election thread (lease renewal loop)
  │
  └─ [Per-Controller]
      └─ Worker threads (max_concurrent per controller)
          └─ reconcile(request) ← I/O waiting
  └─ [Phase 6] Informer resync timer thread
  └─ [Phase 7] EventRecorder worker thread (bounded queue)
  └─ [Phase 7] Probe / Metrics server accept thread
```

**スレッドセーフ要件**:

| コンポーネント | 保護対象 | 方法 |
|---|---|---|
| SharedCache / Store | `@store` ハッシュ | `Mutex` |
| WorkQueue | `@queue`, `@known` | `Mutex` + `Queue` (built-in thread-safe) |
| LeaderElector | `@is_leader` | `Mutex` |

---

## 5. エラーハンドリング

| シナリオ | 対応 |
|---|---|
| reconcile で例外 | ログ出力 + `Result.retry_after(5)` で再試行 (指数バックオフ, max 5min) |
| Watch 切断 | バックオフ後に relist し、List の resourceVersion から Watch 再開。ERROR / BOOKMARK は #45 |
| List 失敗 (初回 sync) | 最大 4 回試行後 Manager startup 失敗 |
| API 404 (リソース削除済み) | reconcile で `Result.ok` (no-op) |
| API 429 (throttled) | `retry_after` で待機 |
| API 409 (conflict) | 呼び出し元へ返す。再試行は最新状態から意図を再計算する明示的ブロックで行う (§2.12.3) |
| Leader election 失敗 | リード候補外 → reconcile 一時停止 → 再取得時再開 |
| ControllerClient update で 409 | `ConflictError` を返す。未処理なら Controller の指数バックオフに合流 |
| EventRecorder 送信失敗 | ログのみ (reconcile に影響させない) |
| Probe / Metrics の bind 失敗 | Manager 起動失敗 (設定エラーとして表面化) |
| Webhook validate 例外 | HTTP 5xx 応答 → failurePolicy に従う (Fail → deny / Ignore → 許可)。明示的な検証 NG (`allowed: false` + status) は failurePolicy をバイパスする — 両者を混同しない |

---

## 6. 開発フェーズ

### Phase 1: Core (MUST)

| # | タスク | 成果物 |
|---|---|---|
| 1 | gemspec + 骨格作成 | `kruby-controller.gemspec`, ディレクトリ構造 |
| 2 | Request, Result, Reconciler | `request.rb`, `result.rb`, `reconciler.rb` |
| 3 | WorkQueue | `work_queue.rb` + テスト |
| 4 | SharedCache + Informer + Store | `cache/` 配下 + テスト |
| 5 | Event Handler | `handler/` 配下 + テスト |
| 6 | Controller (Reconcile Loop) | `controller.rb` + テスト |
| 7 | Manager | `manager.rb` + 統合テスト |
| 8 | Leader Election | `leader_elector.rb` + テスト |

### Phase 2: Helpers (SHOULD)

| # | タスク | 成果物 |
|---|---|---|
| 9 | Finalizer Manager | `finalizer_manager.rb` |
| 10 | OwnerReference | `owner_reference.rb` |
| 11 | Status Updater | `status_updater.rb` |
| 12 | CRD Generator | `crd_generator.rb` + テスト |
| 13 | Controller Builder | `controller_builder.rb` |

### Phase 3: CLI (MUST)

| # | タスク | 成果物 |
|---|---|---|
| 14 | CLI entry point | `exe/kruby-controller` |
| 15 | `init` コマンド + テンプレート | `init_command.rb`, テンプレートファイル |
| 16 | `create api` コマンド + テンプレート | `create_api_command.rb`, テンプレートファイル |

### Phase 4: Hello World + 検証

| # | タスク | 成果物 |
|---|---|---|
| 17 | CronTask Hello World サンプル | `examples/hello-world/` |
| 18 | 統合テスト (kind) | `specs/integration/` |
| 19 | ドキュメント | `README.md`, `docs/` |

### Phase 5: Client 統合 (MUST)

| # | タスク | 成果物 |
|---|---|---|
| 20 | ControllerClient (cache read + API write) | `client/controller_client.rb` + テスト |
| 21 | Reconciler への依存注入 | `controller.rb`, `manager.rb` |
| 22 | 409 競合リトライ + helpers の ControllerClient 移行 | `status/`, `finalizer/` |

### Phase 6: キャッシュ・イベント拡張 (SHOULD)

| # | タスク | 成果物 |
|---|---|---|
| 23 | 定期 resync | `cache/informer.rb` |
| 24 | Server-side selector | `cache/` |
| 25 | Field index | `cache/store.rb`, `cache/cache.rb` (issue #16) |
| 26 | Predicate old/new + 事前定義 | `event/`, `handler/` |

### Phase 7: 運用機能 (SHOULD)

| # | タスク | 成果物 |
|---|---|---|
| 27 | EventRecorder | `recorder/event_recorder.rb` |
| 28 | Health Probe | `probe/server.rb` |
| 29 | Metrics | `metrics/registry.rb` (方式は Q1) |

### Phase 8: Scaffold + CRD 拡張 (SHOULD)

| # | タスク | 成果物 |
|---|---|---|
| 30 | Makefile / Dockerfile / Kustomize / CI | `cli/templates/` |
| 31 | DSL 検証制約 + printer columns | `crd.rb`, `generator/crd_generator.rb` (issue #15 残部) |
| 32 | Typed accessor | `crd.rb` |

### Phase 9: Webhook (SHOULD)

| # | タスク | 成果物 |
|---|---|---|
| 33 | Validating / Mutating webhook | `webhook/` |
| 34 | Conversion webhook | `webhook/`, `generator/crd_generator.rb` |

**実施順序 (推奨)**: Phase 4 (issue #17) は現行 API でも着手可能だが、Phase 5 の client 注入後のほうが hello-world が最小構成になる。推奨順序: **Phase 5 → Phase 4 → Phase 6 → 7 → 8 → 9**。各 Phase は独立 PR (ユーザーマージゲート) で進め、Phase 4 の kind E2E は実測エビデンスを残す。

---

## 7. kruby 依存の詳細

本フレームワークが kruby に依存する箇所:

| フレームワーク側 | kruby 側 | 用途 |
|---|---|---|
| `Manager#initialize(kube_config:)` | `Kubernetes::Configuration`, `Kubernetes::KubeConfig` | 認証設定 |
| `Informer#populate` | `Kubernetes::ApiClient#build_request` | 初回 List |
| `Informer#watch_loop` | `Kubernetes::Watch` | Watch 接続 |
| `CRD Generator` | `Kubernetes::ApiExtensionsV1Api` | CRD apply |
| `LeaderElector` | `Kubernetes::CoordinationV1Api` | Lease API |
| `StatusUpdater` | `KubernetesObjectClient` / `ApiClient#build_request` | Status PATCH |
| `Reconciler` | 各種 `Kubernetes::*Api` | API 操作 |
| `ControllerClient` (F-11) | `Kubernetes::ApiClient#build_request` | PUT / PATCH / POST / DELETE を直接構築 (kruby CustomObjectsApi には PUT update / merge-patch が無いため) |
| `EventRecorder` (F-14) | `Kubernetes::ApiClient#build_request` | events.k8s.io/v1 の送出 |
| `Webhook::Server` (F-21) | 受信側のみ (admission.k8s.io) | TLS は OpenSSL 標準ライブラリ |

**重要な依存**: kruby の `Kubernetes::Watch` はストリーミング HTTP 接続を提供。これが Informer の基盤。

**移収事項 (T1)**: kruby 側へ PUT update / merge-patch / json-patch の上位 API (現状 `KubernetesObjectClient` が ApiClient 直接で担っている領域) を提供するかの判断は Phase 5 完了後に行う。当面は本 gem 内で `ApiClient#build_request` を直接利用する。

---

## 8. 既存 kubebuilder との対応表

以下は概念の対応であり同等性・実装完了を示さない。評価時点、差分、受け入れ基準、Issue は [差分評価](./parity-review.md) を正とする。

| kubebuilder / controller-runtime | Kruby Controller Framework | 備考 |
|---|---|---|
| `ctrl.NewManager` | `KrubyController::Manager.new` | |
| `ctrl.Options` | Manager 初期化オプション | |
| `controller.Reconcile` | `Reconciler#reconcile` | |
| `reconcile.Result` | `KrubyController::Result` | |
| `client.Client` | `Client::ControllerClient` (Phase 5, F-11) | 現状は SharedCache (read) + kruby ApiClient (write) の手動構成 |
| `cache.Cache` | `KrubyController::Cache::SharedCache` | |
| `handler.EnqueueRequestForObject` | `Handler::EnqueueRequestForObject` | |
| `handler.EnqueueRequestForOwner` | `Handler::EnqueueRequestForOwner` | |
| `predicate.Resource` | `predicate: proc { |obj| ... }` | |
| `controller.For()` | `Builder#for()` / `.owns()` | |
| `manager.Elected` | `Manager#leader?` / leader election callback | |
| `scaffolds/init` | `kruby-controller init` | |
| `scaffolds/api` | `kruby-controller create api` | |
| `crd.Upgrade` | CRD Generator | Ruby DSL → YAML |
| `mgr.GetEventRecorderFor` / `record.EventRecorder` | `Recorder::EventRecorder` (Phase 7, F-14) | events.k8s.io/v1 |
| `healthz` / `readyz` handler | `Probe::Server` (Phase 7, F-15) | |
| `metrics` (promhttp) | `Metrics::Registry` (Phase 7, F-23) | 実装方式は Q1 |
| `cache.AddIndex` / `GetIndexer` | `SharedCache#index_field` / `get_by_field` (§2.3.1) | 未実装 (issue #16, Phase 6) |
| `predicate.*` (UpdateEvent) | `Event::*` + `Event::Predicates` (Phase 6, F-17) | |
| `SyncPeriod` | Informer 定期 resync (Phase 6, F-16) | 既定 10h |
| `webhook.Server` / `builder.WebhookManagedBy` | `Webhook::Server` + DSL (Phase 9, F-21/F-22) | |
| `make manifests` (controller-gen) | CRD Generator + scaffold (Phase 8, F-19/F-20) | Go marker の代わりに DSL |
| `envtest` | kind E2E + fake K8s API (Phase 4) | |

---

## 9. 技術的課題と検討

### 9.1 Ruby GIL と並列 reconcile

**課題**: Ruby の GIL はスレッド間の CPU 並列を制限する。ただし reconcile は主に I/O (Kubernetes API 呼び出し) なので、GIL 解放中の I/O 待ち時間で他のスレッドが実行される。

**判断**: 現状ではスレッドベースで十分。GVL を完全に解放する必要がある場合は `ruby-concurrent` や Ractor (Ruby 3.0+) を検討。

### 9.2 Watch 接続の信頼性

**課題**: kruby の `Watch#connect` はブロック型。接続切断時の再試行ロジックを Informer 側で実装する必要がある。

**対応**: Informer は watch ループを try/rescue + sleep/backoff でラップ。resourceVersion を保持し、直地点から再開。

**#45 追記 (2026-11-03)**: kruby の `Watch` は 410 Gone を内部で自動再接続する (`current_resource_version = nil` で "now" から watch) — これは古い RV と再接続の間のイベントを**無音で欠損**させる。そのため Informer は kruby の Watch を使わず、自前の `WatchStream` (ApiClient 直構築・on_body ストリーミング・自動再接続なし・idle タイムアウト無効) で watch する。ERROR イベントも含めて全イベントを Informer に渡し、分類 (ADDED/MODIFIED/DELETED → store+handler、BOOKMARK → RV のみ、ERROR 410 → 即 relist、その他 ERROR → バックオフ後に relist) は Informer 側が行う。
- 不正データイベント (null、または RV 以外の metadata のみ) はログして無視し、RV を unkeyable なオブジェクトに更新しない (watch が盲目にならない)。
- ストリーム内 ERROR (429/5xx) は `details.retryAfterSeconds` をバックオフに反映 (200 の watch レスポンスには HTTP の Retry-After ヘッダがないため)。
- HTTP 410 レスポンス (ストリーム内 ERROR イベントと同一形態) は即 relist 経路。200 レスポンス後の本転送失敗は clean close ではなくエラーとして surface。Retry-After は delta-seconds と HTTP-date の両形式をサポート。

### 9.3 CRD Generator の完全性

**課題**: kubebuilder の CRD 生成は Go type reflection + controller-gen (Markers) に依存。Ruby 側で同等の表現力をどう実現するか。

**対応**: DSL (`attribute :name, type: :string, ...`) で属性を宣言。Go type annotations 相当の機能は `mark` API で追加予定。

```ruby
attribute :template, type: :object,
  marks: {
    x_preserve_unknown_fields: true,  # PodSpec 相当
  }
```

### 9.4 Gem 化 vs Monorepo

**判断**: 独立 gem (`kruby-controller`) としてリリース。kruby 本体には依存しない（`kruby ~> 1.36` 依存宣言のみ）。これは kruby が API client に集中し、controller フレームワークは別の lifecycle で発展するため。

### 9.5 定期 resync の負荷 (F-16)

**課題**: 定期 resync はストア内の全オブジェクトを再配信するため、イベント処理負荷は GVK 数 × オブジェクト数に比例する。ただし API List は発生しない (ローカルストアの再配信であり、§2.3.2 の relist とは異なる)。
**対応**: 既定値は 10h とし、`resync_period: nil` で無効化できる。大規模キャッシュでは resync_period の引き上げを推奨する。

### 9.6 Ruby での HTTP サーバー (Probe / Metrics / Webhook) (F-15 / F-23 / F-21)

**課題**: probe / metrics / webhook には組み込み HTTP サーバーが必要。WEBrick は Ruby 3.0+ で bundled gem 化しており、依存最小方針と衝突する。
**対応**: GET 応答のみの probe / metrics は `TCPServer` 自前実装 (~100 行) で対応する。Webhook は HTTPS 必須のため、OpenSSL 標準ライブラリ + 自前実装または WEBrick 依存の採用を Phase 9 設計時 (Q2) に決定する。

### 9.7 Webhook の TLS 証明書 (F-21)

**課題**: admission webhook は kube-apiserver から HTTPS で到達可能である必要がある。本番は cert-manager による証明書発行と CA injection が定石。
**対応**: scaffold に cert-manager 用 manifest を生成する。開発時は self-signed 証明書 + kind での検証手順を README に記載する (Q2)。

### 9.8 GVL と補助サーバー

**課題**: probe / metrics / webhook サーバーの accept スレッド、recorder のワーカースレッド、resync の timer スレッドは GVL を共有する。ただしいずれも主に I/O 待ちで、reconcile の I/O 待ち時間と並行実行される (§9.1 と同様)。
**対応**: 影響小と判断。webhook の validate ロジックが CPU 重い場合はユーザー側で Thread 分離を検討する。

---

## 10. テスト戦略

| レベル | 対象 | 方法 |
|---|---|---|
| Unit | Reconciler, Result, Request, WorkQueue, Store | RSpec, WebMock |
| Integration | Informer, SharedCache, Controller | fake K8s API (testserver 相当) |
| E2E | Manager, Leader Election, 全コントローラー | kind クラスター + kruby E2E 既存インフラ |
| Generator | CRD Generator | RSpec (出力 YAML の妥当性検証) |
| CLI | `init`, `create api` | RSpec (テンプレート生成検証) |
| ControllerClient (F-11) | read (cache miss → API)、write verbs、409 リトライ | RSpec, WebMock (fake K8s API) |
| EventRecorder (F-14) | events API POST/PATCH、dedupe、非同期ワーカー | RSpec (fake events API) |
| Health Probe / Metrics (F-15 / F-23) | HTTP 応答と ready 条件 | RSpec (実ソケット) |
| Webhook (F-21 / F-22) | AdmissionReview v1 の受信・応答 | RSpec + kind E2E (Phase 9) |
| Scaffold (F-20) | 生成物の構文・Makefile ターゲット | RSpec (テンプレート生成検証) + `make deploy` 実測 (kind) |

---

## 11. 未確定事項

| Q# | 事項 | 現状の扱い | 要決定 |
|---|---|---|---|
| Q1 | metrics 実装方式 (`prometheus_client` gem 追加 vs テキスト形式自前) | 自前実装 (依存最小) を既定案に | Phase 7 設計時 |
| Q2 | Webhook TLS 証明書 (cert-manager 前提 vs 自前生成) と HTTPS サーバー実装 | cert-manager 前提 + 自前サーバーを既定案に | Phase 9 設計時 |
| Q3 | Typed accessor (F-24) の適用範囲 (spec/status の 1 階層か、ネスト object も含むか) | spec/status の DSL 宣言済みパスのみを既定案に | Phase 8 設計時 |
| Q4 | Phase 4 (hello-world) の実施タイミング | Phase 5 完了後 (client 注入後が最小構成) を推奨 | Phase 5 完了時 |
| Q5 | Kustomize の採用範囲 (フル Kustomize vs フラット manifest 拡張) | フル Kustomize を既定案に | Phase 8 設計時 |
| Q6 | 移収: kruby へ PUT update / merge-patch の上位 API を提供するか (T1) | 本 gem 内で `ApiClient#build_request` 直接利用 | Phase 5 完了後 |
