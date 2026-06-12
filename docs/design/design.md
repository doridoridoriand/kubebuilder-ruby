# Kruby Controller Framework — 設計書 (Design Document)

| 項目 | 内容 |
|---|---|
| 名称 | **Kruby Controller Framework** (gem 名: `kruby-controller`) |
| 仕様書参照 | [specification.md](./specification.md) |
| バージョン | Draft 0.1 |
| 日付 | 2026-06-10 |

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
│       └── logger.rb                  # Unified logger
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

```ruby
# Manager の内部構造
class Manager
  attr_reader :cache, :stop_channel, :leader_elector

  def initialize(opts)
    @cache = SharedCache.new(kube_config: opts[:kube_config])
    @controllers = []
    @leader_elector = opts[:leader_elect] ?
      LeaderElector.new(**leader_opts) : nil
    @stop_channel = Channel.new
    @running = false
  end

  def add(reconciler_class, **opts)
    controller = Controller.new(
      reconciler: reconciler_class.new,
      cache: @cache,
      **opts
    )
    @controllers << controller
  end

  def start
    @running = true

    # 1. shared cache を起動 (background thread)
    @cache.start

    # 2. cache sync を待機
    @cache.wait_for_sync

    # 3. leader election (もし有効なら)
    start_leader_election if @leader_elector

    # 4. コントローラーをスレッドで起動
    @controllers.each do |ctrl|
      Thread.new { ctrl.start }
    end

    # 5. sigterm/sigint で graceful stop
    trap_sigterm { stop }

    # 6. block until stop
    @stop_channel.receive
  end

  def stop(timeout:)
    @running = false
    @stop_channel.send(:stop)
    @cache.stop
    @controllers.each { |c| c.stop(timeout:) }
    @leader_elector&.release
  end
end
```

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

  # 初回リスト取得
  def populate
    list_path = rest_path_for(@gvk, action: :list)
    resp = @api_client.get(list_path)
    items = parse_list(resp)
    items.each do |item|
      @store.add(Delta::ADDED, item)
    end
    @resource_version = resp['metadata']['resourceVersion']
    @synced = true
  end

  # Watch ループ (切断再試行付き)
  def watch_loop
    loop while @running do
      watch = Kubernetes::Watch.new(@api_client)
      watch_path = rest_path_for(@gvk, action: :watch, rv: @resource_version)

      watch.connect(watch_path) do |event|
        type = event_type(event)  # ADDED / MODIFIED / DELETED
        obj = event['object']
        @resource_version = event['object']['metadata']['resourceVersion']
        @store.add(type, obj)

        # delta を event handlers に配送
        @handlers.each { |h| h.handle(type, obj) }
      end
    rescue => e
      sleep backoff_interval
      retry
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
    Thread.new do
      sleep seconds
      add(request)
    end
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
| Watch 切断 | sleep(背off) 後、直前 resourceVersion から再 connect |
| List 失敗 (初回 sync) | 3 回リトライ → Manager startup 失敗 |
| API 404 (リソース削除済み) | reconcile で `Result.ok` (no-op) |
| API 429 (throttled) | `retry_after` で待機 |
| API 409 (conflict) | 再取得 → 再適用 (update loop) |
| Leader election 失敗 | リード候補外 → reconcile 一時停止 → 再取得時再開 |

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

---

## 7. kruby 依存の詳細

本フレームワークが kruby に依存する箇所:

| フレームワーク側 | kruby 側 | 用途 |
|---|---|---|
| `Manager#initialize(kube_config:)` | `Kubernetes::Configuration`, `Kubernetes::KubeConfig` | 認証設定 |
| `Informer#populate` | `Kubernetes::ApiClient#get` | 初回 List |
| `Informer#watch_loop` | `Kubernetes::Watch` | Watch 接続 |
| `CRD Generator` | `Kubernetes::ApiExtensionsV1Api` | CRD apply |
| `LeaderElector` | `Kubernetes::CoordinationV1Api` | Lease API |
| `StatusUpdater` | `Kubernetes::CustomObjectsApi` (patch_status 相当) | Status PATCH |
| `Reconciler` | 各種 `Kubernetes::*Api` | API 操作 |

**重要な依存**: kruby の `Kubernetes::Watch` はストリーミング HTTP 接続を提供。これが Informer の基盤。

---

## 8. 既存 kubebuilder との対応表

| kubebuilder / controller-runtime | Kruby Controller Framework | 備考 |
|---|---|---|
| `ctrl.NewManager` | `KrubyController::Manager.new` | |
| `ctrl.Options` | Manager 初期化オプション | |
| `controller.Reconcile` | `Reconciler#reconcile` | |
| `reconcile.Result` | `KrubyController::Result` | |
| `client.Client` | SharedCache (read) + kruby ApiClient (write) | |
| `cache.Cache` | `KrubyController::Cache::SharedCache` | |
| `handler.EnqueueRequestForObject` | `Handler::EnqueueRequestForObject` | |
| `handler.EnqueueRequestForOwner` | `Handler::EnqueueRequestForOwner` | |
| `predicate.Resource` | `predicate: proc { |obj| ... }` | |
| `controller.For()` | `Builder#for()` / `.owns()` | |
| `manager.Elected` | `Manager#leader?` / leader election callback | |
| `scaffolds/init` | `kruby-controller init` | |
| `scaffolds/api` | `kruby-controller create api` | |
| `crd.Upgrade` | CRD Generator | Ruby DSL → YAML |

---

## 9. 技術的課題と検討

### 9.1 Ruby GIL と並列 reconcile

**課題**: Ruby の GIL はスレッド間の CPU 並列を制限する。ただし reconcile は主に I/O (Kubernetes API 呼び出し) なので、GIL 解放中の I/O 待ち時間で他のスレッドが実行される。

**判断**: 現状ではスレッドベースで十分。GVL を完全に解放する必要がある場合は `ruby-concurrent` や Ractor (Ruby 3.0+) を検討。

### 9.2 Watch 接続の信頼性

**課題**: kruby の `Watch#connect` はブロック型。接続切断時の再試行ロジックを Informer 側で実装する必要がある。

**対応**: Informer は watch ループを try/rescue + sleep/backoff でラップ。resourceVersion を保持し、直地点から再開。

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

---

## 10. テスト戦略

| レベル | 対象 | 方法 |
|---|---|---|
| Unit | Reconciler, Result, Request, WorkQueue, Store | RSpec, WebMock |
| Integration | Informer, SharedCache, Controller | fake K8s API (testserver 相当) |
| E2E | Manager, Leader Election, 全コントローラー | kind クラスター + kruby E2E 既存インフラ |
| Generator | CRD Generator | RSpec (出力 YAML の妥当性検証) |
| CLI | `init`, `create api` | RSpec (テンプレート生成検証) |
