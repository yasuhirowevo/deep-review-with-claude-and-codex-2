# Deep Review 2

Claude Code CLI と Codex CLI を独立したレビュアーとして利用し、同じ固定入力に対するコードレビューを行うスキルです。

重要度と「今回の変更でどう扱うか」を分けて判断し、レビュー範囲を必要以上に広げず、人が対応方針を判断しやすいレポートを生成します。

> このリポジトリは共有用スナップショットです。継続的な更新や最新版との一致は保証されません。

## リポジトリ構成

```text
.
├── README.md
├── LICENSE
└── skills/
    └── deep-review-with-claude-and-codex-2/
        ├── SKILL.md
        ├── CONSTITUTION.md
        ├── agents/
        ├── references/
        ├── scripts/
        └── tests/
```

`skills/`以下が、そのままインストールできるスキル本体です。

## 主な特徴

- PRまたはコミット済みブランチのBASE・HEADを固定
- safe diff、HEAD snapshot、project guidance、toolingを固定して検証
- ClaudeとCodexへ同一の入力と品質基準を提供
- 片方の失敗や入力不整合を「指摘なし」として扱わない
- 重要度と、対象PRでの取扱いを分離
- 既存判断と新しい根拠を照合し、不要な再提起を抑制
- 人向け要約と機械的に照合できる監査証跡を生成

インストール対象は
[`skills/deep-review-with-claude-and-codex-2/`](skills/deep-review-with-claude-and-codex-2/)
ディレクトリです。詳細な設計方針は
[`CONSTITUTION.md`](skills/deep-review-with-claude-and-codex-2/CONSTITUTION.md)、実行契約は
[`SKILL.md`](skills/deep-review-with-claude-and-codex-2/SKILL.md)を参照してください。

## 必要なもの

- Git
- GitHub CLI（PRをレビューする場合）
- Node.js
- jq
- 認証済みの Claude Code CLI
- 認証済みの Codex CLI

## インストール

リポジトリをcloneし、内側のスキルディレクトリを利用するホストのskillsディレクトリへコピーします。

Claude Codeの例:

```bash
git clone <repository-url> \
  deep-review-with-claude-and-codex-2-snapshot
cp -R deep-review-with-claude-and-codex-2-snapshot/skills/deep-review-with-claude-and-codex-2 \
  "$HOME/.claude/skills/"
```

Codexの例:

```bash
git clone <repository-url> \
  deep-review-with-claude-and-codex-2-snapshot
cp -R deep-review-with-claude-and-codex-2-snapshot/skills/deep-review-with-claude-and-codex-2 \
  "$HOME/.agents/skills/"
```

## レビュアー設定

既定では、次の設定ファイルを使用します。

```text
$HOME/.config/deep-review-with-claude-and-codex/reviewer.env
```

4項目すべてに、利用環境で有効な値を設定してください。

```dotenv
CLAUDE_REVIEW_MODEL=<claude-model>
CLAUDE_REVIEW_EFFORT=<effort>
CODEX_REVIEW_MODEL=<codex-model>
CODEX_REVIEW_REASONING_EFFORT=<effort>
```

モデル名と推論設定はCLIの対応状況に依存します。設定ファイルへAPIキーやトークンを書く必要はありません。

### 実行ホストの設定

利用するホストについて、初回実行前に次も設定してください。

- **Claude Code**: このスキルの収束工程では最大40分の実行枠を使うため、`BASH_MAX_TIMEOUT_MS`を`2400000`以上に設定します。スキルは工程ごとに必要なtimeoutを指定し、設定が不足している場合は停止します。
- **Codex**: インストール先の`scripts/launch-run-reviewer.sh`を`bash`で起動する固定コマンドだけをallow ruleへ登録します。パスには実際の絶対パスを使い、任意のshellや一時ディレクトリ全体を許可しないでください。設定形式は[CodexのRulesドキュメント](https://learn.chatgpt.com/docs/agent-configuration/rules)を参照してください。

必要な設定と実行権限の範囲は、同梱の[ホストアダプター](skills/deep-review-with-claude-and-codex-2/references/host-adapters.md)に記載しています。個人の設定ファイルはこのリポジトリには含めません。

## 使用例

### Claude Code

PRをレビュー:

```text
/deep-review-with-claude-and-codex-2 123
```

コミット済みブランチをレビュー:

```text
/deep-review-with-claude-and-codex-2 --branch feature/example --base main
```

### Codex

PRをレビュー:

```text
$deep-review-with-claude-and-codex-2 123
```

コミット済みブランチをレビュー:

```text
$deep-review-with-claude-and-codex-2 --branch feature/example --base main
```

レビュー対象のdiffとsnapshotは、外部のClaude Code CLIおよびCodex CLIへ送信されます。機密情報を含むリポジトリでは、所属組織のルールと各サービスの利用条件を確認してから実行してください。

## メンテナンス用テスト

テストには、インストール先のClaude Code設定とCodex権限ルールを検査する統合テストが含まれます。
両ホストを設定した環境で、インストールしたスキルのディレクトリから実行してください。

```bash
bash scripts/test-regression.sh
```

macOSでは、書き込み失敗を模擬する`/dev/full`のテスト1件がOSの権限制約により失敗することがあります。

## License

[MIT License](LICENSE)
