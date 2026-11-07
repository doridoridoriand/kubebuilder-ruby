# Hello World Controller (kind E2E サンプル)

このディレクトリは、`kruby-controller` が**実クラスタ (kind) に対して実際に動く**ことを
検証するための最小・完全な controller サンプルです。単一のプロセスで次のすべてを
一通り実行します:

- `SharedCache` の **List/Watch (informer)**
- **reconcile ループ** (Manager + Controller + WorkQueue)
- キャッシュからの読み取り (`cache.get`)
- **status サブリソースへの書き込み** (`StatusUpdater`)
- **graceful shutdown** (SIGTERM)

`examples/` は gem に同梱されません (`gemspec` の `files` は `lib`, `exe` 等に限定)。
リポジトリ内の検証用サンプルです。

## 前提

- Docker / [kind](https://kind.sigs.k8s.io/)
- kubectl
- Ruby (gemspec 要件: >= 3.3.0)

## 手順

```sh
# 1) kind クラスタを作る
kind create cluster --name kruby-smoke
export KUBECONFIG="$(kind get kubeconfig --name kruby-smoke)"

# 2) CRD をインストール (crd.yaml は本サンプルの HelloResource クラスから
#    KrubyController::Generator::CrdGenerator が生成した出力)
kubectl apply -f crd.yaml
kubectl wait --for=condition=Established crd/helloresources.smoke.example.com --timeout=60s

# 3) operator を起動 (foreground。leader_elect=false で単一副本・lease なし)
bundle exec ruby examples/hello-world/hello_world.rb
```

別ターミナルで CR を作成すると reconcile が観測できます:

```sh
kubectl apply -f - <<'YAML'
apiVersion: smoke.example.com/v1
kind: HelloResource
metadata:
  name: one
  namespace: default
spec:
  message: world
YAML

kubectl get helloresource one -n default -o yaml
```

## 期待される挙動 (実測: kind v0.22.0 / kindest/node:v1.29.2)

**起動** (operator ログ):

```
I, [...] INFO -- kruby-controller: HelloResource operator starting (leader_elect=false)
I, [...] INFO -- kruby-controller: Starting manager...
I, [...] INFO -- kruby-controller: Controller helloresource worker 1 started
```

**CR 作成** → informer が観測し reconcile → status が設定される:

```
spec:
  message: world
status:
  greeting: hello, world
  observed_count: 1          # 幂等のため 1 で安定 (無限ループしない)
```

**spec を更新** (`message: hello-world`) → MODIFIED が観測され再 reconcile:

```
status:
  greeting: hello, hello-world
  observed_count: 2
```

**SIGTERM** → 論理シャットダウン (controller drain / cache 停止) の後、約 11s で
プロセスが確実に退出する:

```
I, [...] INFO -- kruby-controller: Stopping manager...
W, [...] WARN -- kruby-controller: Informer smoke.example.com/v1, Kind=HelloResource: a worker thread did not exit within 10s; proceeding with the stopped worker disabled
# → プロセスが ~11s で終了 (exit! により常駐 watch ワーカーを OS レベルで退出)
```

## 実測で判明した 2 つの注意点

### 1. reconcile は幂等であること

reconcile が status を**無条件に**書き込むと、その status パッチ自体が informer に
MODIFIED として観測され、再 enqueue → 再 reconcile の**無限ループ**になる (実測で
約 300 回/秒の書き込みを確認)。本サンプルは **desired state が現在値と異なる場合のみ
書き込む** (幂等) ことでループを断ち切っている。実 controller でも、この guard か
「generation 変更時のみ reconcile」する predicate (issue #34) のいずれかが必要。

### 2. 起動スクリプトは `Manager#start` の後に `exit!` を呼ぶこと

Typhoeus の watch 読み取りは中断 API を持たない (§9.9 参照)。停止後も watch 接続が
開いたままなら、そのワーカー (non-daemon) が通常のスクリプト末尾の exit をブロックし、
**プロセスがハング**する。`hello_world.rb` は `manager.start` が返却した後に `exit!(0)`
を呼び、論理シャットダウン完了後に常駐ワーカーを OS レベルで確実に退出させている。
新規 operator を書くときはこのパターンに従うこと。

## クリーンアップ

```sh
kind delete cluster --name kruby-smoke
```
