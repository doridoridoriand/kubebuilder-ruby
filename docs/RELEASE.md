# リリース手順 (v0.1.0)

`kruby-controller` を rubygems に公開するための runbook。

**ゲート (実施はユーザー)**: 初回リリースの可否 (issue #43) と公開先
(rubygems.org / GitHub Packages / 非公開) はユーザーの判断。本 runbook は
それ以外の整備手順であり、`gem push` とタグ push はユーザーが実行する。

## 整備 (本 PR で実施済)

- `gemspec` の `files` を dotfile/ディレクトリ非包含に修正 (`.DS_Store` 等が
  混入しないように `FNM_DOTMATCH` 廃止 + ディレクトリ除外)。
- 冗長な `source_code_uri` (homepage と同一) を除去し、`gem build` の警告を解消。
- `.ruby-version` (3.4.4) を追加 (CI とローカルの再現性)。
- `gem build` / `gem spec` が warning なし・executable (`kruby-controller`) 登録
  済み・ファイル 37 件 (dotfile/ディレクトリなし) で検証済み。

## リリース前のチェック

```sh
bundle exec rake            # 全スイート緑 (352 examples)
gem build kruby-controller.gemspec   # warning なし・kruby-controller-0.1.0.gem 生成
gem spec kruby-controller-0.1.0.gem  # 仕様検証
```

## 手順

```sh
# 1) CHANGELOG を最終化: [Unreleased] の各エントリを新しい
#    "## [0.1.0] - <YYYY-MM-DD>" セクションに移動し、空の [Unreleased] を頭に残す。

# 2) version.rb がリリースバージョン (0.1.0) であること
cat lib/kruby_controller/version.rb

# 3) 全スイートを最終確認
bundle exec rake

# 4) gem を build
gem build kruby-controller.gemspec

# 5) アノテイトタグを打って push (main のリリースコミットを指す)
git tag -a v0.1.0 -m "kruby-controller v0.1.0"
git push origin main
git push origin v0.1.0

# 6) rubygems に push (ユーザーが実施。rubygems.org アカウント要)
gem push kruby-controller-0.1.0.gem
```

## 公開後の検証

```sh
gem fetch kruby-controller          # rubygems から取得 (キャッシュ遅延 1-2 分あり)
gem specification kruby-controller --remote version   # 公開バージョン確認
gem install kruby-controller        # インストール smoke
```

- rubygems.org の gem ページ (homepage / changelog リンク) を目視確認。
- CI (`.github/workflows/ci.yml`) が main 上で緑であることを確認。

## 公開先について (要判断)

- **rubygems.org** (推奨): 上記手順通り。gem 名 `kruby-controller` は未占有か
  公開前に `gem search kruby-controller --remote` で再確認。
- **GitHub Packages**: RubyGems は `GEM_HOSTS`/`GEM_HOST` を読まない
  (`RUBYGEMS_HOST` または `--host` が push 先の切り替え)。`~/.gem/credentials`
  に `:github: Bearer <PAT classic>` を登録して
  `gem push --key github --host https://rubygems.pkg.github.com/doridoridoriand
  kruby-controller-0.1.0.gem` で push する。
- **非公開 / 内部のみ**: `gem push` を行わず、内部 registry への push を別途行う。
  rubygems.org 以外を公開先にする場合は gemspec の `metadata["allowed_push_host"]`
  を設定して rubygems.org への誤 push を防止する。
