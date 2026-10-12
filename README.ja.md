# codexwait

[English](./README.md) | **日本語**

`codexwait` は、Codex CLIの利用制限（レート制限）が解除されるのを待ち、既存のCodexセッションを再開するための小さなラッパーツールです。

Codexの出力が利用制限／レート制限エラーと思われる場合に**のみ**再試行を行います。その他のエラーが発生した場合は、すぐに停止します。

## 動作要件

- Codex CLIがインストールされ、認証済みであること（`PATH` 上に `codex` が存在すること）。
- 再開対象となる既存のCodexセッションがあること。
- macOS または Linux。`--keep-awake` は、利用可能な場合にmacOSの `caffeinate` を使用します。

Nix経由でインストールした場合、`codexwait` が使用する `jq` やその他のヘルパーユーティリティは自動的に含まれます。

## 使い方

```sh
# 直近のセッションを新しい順に表示
codexwait list

# さらに多くのセッションを表示
codexwait list --limit 20

# 完全なUUIDを指定
codexwait 01a1302e-0872-79b2-98c2-93f4299c6339

# 一意に識別できるUUIDプレフィックス（前方一致）を指定
codexwait 01a1302e-0872

# 直近のセッションを指定（安全のため作業ディレクトリの明示が必要）
codexwait --last --cwd /path/to/project

# 15分ごとに再試行
codexwait --interval 900 01a1302e-0872

# 記録されている作業ディレクトリを上書き指定
codexwait --cwd /path/to/project 01a1302e-0872

# 待機中にMacのスリープを防止
codexwait --keep-awake 01a1302e-0872
```

デフォルトでは、再試行は600秒（10分）ごとに行われます。

## セッション一覧の表示

`codexwait list` は `$CODEX_HOME/sessions` をスキャンし、直近のセッションをロールアウトファイルの更新日時順（おおむね最終使用日時順）で出力します。現在見つかっているセッションの中で一意となる短いプレフィックスと、Codexによって記録された作成時の作業ディレクトリが表示されます。

```text
Recent Codex sessions:

  SESSION                  DIRECTORY
  01a1302e-087             ~/src/macos-programmable-shell
  01a1302e-08a             ~/src/codexwait
```

セッションの保存形式はCodex内部のフォーマットであるため、Codexがロールアウトのレイアウトを変更した場合、一覧表示機能のアップデートが必要になる場合があります。

## UUIDプレフィックス

Codexはセッションのロールアウトファイルを `$CODEX_HOME/sessions`（通常は `~/.codex/sessions`）の下に保存します。`codexwait` はロールアウトのファイル名をスキャンし、一意に特定できる8文字以上のUUIDプレフィックスを完全なセッションUUIDへと拡張します。

複数のCodexセッションUUIDで先頭の文字列が重複することがあるため、`01a1302e` のような短いプレフィックスでは曖昧になる場合があります。その場合、`codexwait` は推測を行わず停止し、一致する各セッションに対して区別可能な最短のプレフィックスを提案として表示します。

```text
codexwait: session prefix '01a1302e' is ambiguous:
  01a1302e-0872-...  (try: 01a1302e-087)
  01a1302e-08a4-...  (try: 01a1302e-08a)
```

このファイルシステムの構造は永続的な公開APIではなくCodexの内部実装の詳細であるため、将来のCodexリリースによっては `codexwait` のアップデートが必要になる可能性があります。

## 作業ディレクトリの安全対策

`codex exec resume` は、スレッドに記録されたディレクトリではなく、呼び出し元の現在のディレクトリからスレッドを再開してしまうことがあります。これは放置型の自動再試行ラッパーとしては危険であり、モデルが間違ったリポジトリで作業を継続してしまう恐れがあります。

UUIDまたはUUIDプレフィックスが明示された場合、`codexwait` はセッションロールアウトから作成時の `session_meta.cwd` を読み取り、そのディレクトリから再開します。最新の `turn_context.cwd` は**意図的に使用しません**。誤ったリポジトリから誤って再開または失敗した場合、それ自体がより新しいターンコンテキストとして追加され、将来の再試行を汚染してしまうためです。Codexを開始する前に、選択されたディレクトリが出力されます。

```text
Resolved session: 01a1302e-0872-79b2-98c2-93f4299c6339
Session cwd: /Users/me/src/project
Current cwd: /Users/me/src/codexwait
Resuming from session cwd.
```

元々記録されていたディレクトリが現在も存在している必要があります。意図的にセッションを別のチェックアウト／ワークツリーに移動した場合は、明示的に上書きしてください。

```sh
codexwait --cwd /new/path/to/project 01a1302e-0872
```

`--last` や名前付きセッションは、現時点では `codexwait` がロールアウトメタデータへ安全にマッピングできないため、`--cwd DIR` の指定が必須となっています。Nixパッケージには `jq` が含まれており、ロールアウトのJSONLメタデータの読み取りに使用されます。`src/codexwait.sh` を直接実行する場合は、`jq` をインストールするか `--cwd DIR` を使用してください。

## 再開用プロンプト

デフォルトのプロンプトは、あえて控えめな内容になっています。

> 前回の作業を再開してください。まず現在の git の状態と既存の生成物を確認してください。完了済みの作業は繰り返さず、未完了の部分から続けてください。

プロンプトを変更したい場合は、以下のように上書きできます。

```sh
codexwait --prompt '未完了のベンチマーク作業を続けてください。' 01a1302e-0872
```

または環境変数 `CODEXWAIT_PROMPT` を使用します。

## 安全な動作仕様

- Codexが正常終了した場合：停止します。
- 利用制限／レート制限と思われるエラーが発生した場合：待機して再試行します。
- UUID/プレフィックスで明示されたセッション：`--cwd` で上書きされない限り、記録された作業ディレクトリから再開します。
- セッションにアクティブな書き込みプロセス（active writer）が既に存在するとCodexが報告した場合：停止し、まず既存のCodexセッションを閉じるよう促します。
- その他のゼロ以外の終了ステータスが発生した場合：すぐに停止します。
- セッションプレフィックスが曖昧な場合：Codexを実行する前に停止し、より長いプレフィックスを提案します。
- `--max-attempts N`：オプションで再試行回数の上限を設定できます。

### 1つのセッションにつき1つの待機プロセス

明示的なセッション指定がある場合、`codexwait` はCodexを呼び出す前にセッションごとの排他ロック（予約ロック）を作成します。同じセッションを対象とする2つ目の `codexwait` は即座に拒否され、ロックを保持しているプロセスのPID、開始時刻、作業ディレクトリを報告します。

ロックは正常終了時、`Ctrl-C`、`SIGINT`、`SIGTERM` の受領時に解除されます。（`kill -9` などで）プロセスがクリーンアップを行わずに強制終了した場合、次に実行された `codexwait` は記録されたPIDを確認し、そのPIDが既に生存していない場合は古いロックを自動的に置き換えます。

`--last` オプションは、Codex自体が `--last` の指すセッションを解決するため、単一の `--last` 用予約を使用します。したがって、明示的セッションの待機プロセスと `--last` の待機プロセスは `codexwait` のロック層で衝突することが保証されません。ただし、Codex自体の「アクティブライター保護機能」が引き続き機能します。

ロックディレクトリは、利用可能であればデフォルトで `$XDG_RUNTIME_DIR/codexwait` が使用され、それ以外の場合は `${TMPDIR:-/tmp}/codexwait-$UID` が使用されます。テストや高度なセットアップでは、`CODEXWAIT_LOCK_DIR` で上書きできます。

Codexのエラーメッセージの文言が変更された場合は、`CODEXWAIT_LIMIT_REGEX` および `CODEXWAIT_ACTIVE_WRITER_REGEX` を使用して制限検知およびアクティブライター検知用の正規表現を上書きできます。

## Nix

### ローカルのクローンから使用する場合

インストールせずに実行：

```sh
nix run . -- list
nix run . -- 01a1302e-0872
```

ユーザープロファイルにインストール：

```sh
nix profile install .
codexwait list
```

### GitHub から直接使用する場合

リポジトリが公開された後、`<owner>` をGitHubの所有者名に置き換えて実行します。

```sh
nix run github:<owner>/codexwait -- list
nix profile install github:<owner>/codexwait
```

### nix-darwin / Home Manager の場合

flakeを input として追加します。

```nix
inputs.codexwait.url = "github:<owner>/codexwait";
```

次に、パッケージを管理している場所へ追加します。

```nix
environment.systemPackages = [
  inputs.codexwait.packages.${pkgs.system}.default
];
```

Home Managerの場合は、同様のパッケージを `home.packages` に追加してください。

Codex CLI自体は意図的に同梱されていません。`codexwait` は、認証済みの `codex` コマンドが既に利用可能であることを前提としています。

## 開発

```sh
bash tests/test.sh
nix flake check
```

## ライセンス

MIT
