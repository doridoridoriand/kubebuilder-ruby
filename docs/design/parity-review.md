# Kubebuilder との機能差分評価

評価日: 2026-10-31。比較基準は [Kubebuilder v4.16.0](https://github.com/kubernetes-sigs/kubebuilder/releases/tag/v4.16.0) の標準 Go/v4 プロジェクト、[Kubebuilder Book](https://book.kubebuilder.io/) および controller-runtime の主要機能。評価対象はこのリポジトリのコード・テスト・仕様書と GitHub の Issue。Go API や生成物のバイナリ互換ではなく、Ruby で Kubernetes コントローラーを開発・運用する際の機能と振る舞いを比較する。以下は代表的な機能領域を対象とした調査であり、本家の全 API・CLI フラグ・alpha plugin の完全な網羅や互換性の実証ではない。

「基本実装」はコードが存在することを示し、本番環境での信頼性・本家同等性の実証を意味しない。「計画」は未実装を含み、Issue の完了で初めて対応済みとみなす。既存の F-ID と Phase は [仕様書](./specification.md) / [設計書](./design.md) に対応する。Issue は `https://github.com/doridoridoriand/kubebuilder-ruby/issues/<番号>`。

| 領域 / 本家の機能 | 現状と残り | 追跡 |
|---|---|---|
| Manager、複数 controller、leader election | 基本実装あり。競合、停止、フェイルオーバーや待機系 rollout の実環境検証は不足 | #17、#37、#51〜#53 |
| List/Watch、cache | 基本実装あり。Watch の ERROR/BOOKMARK、ページ分割、429 と復旧、可変 Hash の分離が不足。現行コードだけで大規模・障害時の同等性は未実証 | #45、#46、#51、#52 |
| Queue / reconcile | queue 重複排除・backoff、遅延再試行は共有スケジューラ (キューあたりスレッド1本) で実装。実環境での大規模・障害時の同等性は未実証 | #51 |
| Client、status、finalizer | cache 読みと書き込みが分離。競合時の安全な再計算、status/finalizer の同時変更は要検証 | #32、#46、#51 |
| Watch / handler / predicate | owns・watches・predicate は基本実装。old/new・server selector・field index は計画段階。非所有 resource から主 resource への任意の複数 request 対応を #34 / #51 で検証 | #16、#33〜#35、#51 |
| CRD schema、status / scale | 単一 version、基本型・required・default・enum は実装。詳細制約は #40、構造化 map/list・CEL・scale は #48 | #15、#40、#48 |
| 複数 version / conversion | 未実装。served/storage、version 別 schema と conversion のほか、storage version 更新時の移行・旧 version 廃止手順が必要 | #42、#48、#51 |
| Admission / conversion webhook | 未実装。AdmissionReview / ConversionReview の UID、patch、バッチと順序、失敗・タイムアウト、TLS/CA、Service と RBAC を実クラスタで検証 | #42、#51 |
| Events、health、metrics | 未実装。metrics は TLS と認証・認可、probe との分離が必要。standby の readiness と cache の起動順序は設計に明記 | #36〜#38、#51 |
| 初期化 / API / manifests / deploy | `init` / `create api` の基本実装あり。Makefile、コンテナ、Kustomize、CI と実 deploy は未完了 | #17、#39、#51 |
| RBAC | 固定ルールの生成はあるが、controller ごとの明示的宣言・スコープ・外部 API は不足 | #39、#49 |
| プロジェクトの更新・拡張 | バージョン付き layout、衝突保護付き再生成・拡張点は未定義。Helm / Grafana 等の optional plugin は互換性を未評価 | #50 |
| テストとサポート | 単体テストはある。envtest の代替となる実 API テスト、CI マトリクス、対応 Kubernetes/Ruby/kruby の実証が不足 | #17、#51 |
| ドキュメント・配布 | README の現状表・利用例を更新。公開済み gem と誤認しないよう配布時期は未確定とする | #43、#44 |

## 採用する振る舞いと重要な制約

- **409 競合:** 失敗した古い全体 PUT や patch に新しい resourceVersion を付けて再送しない。呼び出し側に 409 を返すか、API server から再取得した状態に意図を再計算する明示的ブロックで再試行する。merge patch も同じフィールドの競合を自動解決しない。#32
- **resync:** controller-runtime の SyncPeriod は同一 old/new の合成 Update として predicate を通るため、GenerationChanged 等で捨てられうる。定期的な外部状態確認は `retry_after` で行う。旧 0.2 の predicate バイパス方針は変更する。#33。参考: [controller-runtime cache.Options](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/cache#Options)
- **待機中の readiness:** 現行 Manager は leader 取得後に cache を開始する。デフォルトでは初期化済みの standby を Ready、leader に昇格後は cache sync が完了するまで NotReady とする。停止・初期化失敗は NotReady。leader 限定 readiness は rollout 戦略との組合せを検証する。#37
- **セレクタ:** API server の List/Watch に同じ条件を付け、合致→非合致の遷移を選択集合からの削除として扱う。非合致の間の変更は見えず、再接続中のキャッシュは古くなり得る。#35
- **公開エンドポイント:** 本家の metrics は既定で認証・認可を伴う。metrics と probe はアクセス制御を分離し、外部公開する metrics は TLS と認証・認可を要求する。無保護の有効化は明示設定とする。#38。参考: [Metrics](https://book.kubebuilder.io/reference/metrics.html)

## 優先順位と依存

1. **整合性と運用上の安全性:** #45〜#47、#52、#53、#32、#37、#38。#46 は #32 / #34 の可変オブジェクト契約の前提。
2. **利用者が生成から配備まで完走できること:** #17、#39、#49、#51。生成する権限や実クラスタでのテストを含める。
3. **API 表現力:** #40、#48、#42。schema / version / conversion と storage migration を一体で設計する。
4. **長期運用と拡張:** #50 と optional plugin 群の個別評価。未評価の機能を完了扱いにしない。

これらは推奨順であり、依存関係のない作業の並行を妨げない。Phase 9 完了時も上記の未完了項目があれば「本家と同等」とは表現しない。対応バージョンは #51 で実測するまで README の最低要件を互換性保証として扱わない。

## 比較に使った一次資料

- [Generating CRDs](https://book.kubebuilder.io/reference/generating-crd.html)、[CRD validation markers](https://book.kubebuilder.io/reference/markers/crd-validation.html)、[RBAC markers](https://book.kubebuilder.io/reference/markers/rbac)
- [Watching resources](https://book.kubebuilder.io/reference/watching-resources.html)、[Plugins](https://book.kubebuilder.io/plugins/plugins)、[Metrics](https://book.kubebuilder.io/reference/metrics.html)
- [Kubernetes API concepts: list / watch / resourceVersion](https://kubernetes.io/docs/reference/using-api/api-concepts/)
