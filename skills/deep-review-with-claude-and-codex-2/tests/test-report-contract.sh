#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks are literal Markdown fixture content.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -P "$TEST_DIR/.." && pwd -P)"
VALIDATOR="$SKILL_DIR/scripts/validate-review-report.mjs"
T=$(mktemp -d /tmp/deep-review-report-contract.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

pass=0
fail=0
ok() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
ng() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
expect_pass() {
  if node "$VALIDATOR" --report "$1" >/dev/null 2>&1; then ok "$2"; else ng "$2"; fi
}
expect_fail() {
  if node "$VALIDATOR" --report "$1" >/dev/null 2>&1; then ng "$2"; else ok "$2"; fi
}

cat > "$T/valid.md" <<'REPORT'
# Deep Review: PR #42

## 結論

Medium 1件。重要度だけでは対応必須とせず、今回はこのPRでの対応候補とする。

- このPRでの対応候補: `1件`
- ユーザー判断が必要: `0件`
- 追加確認が必要: `0件`
- 別Issue候補: `0件`
- 受容済み・見送り済み: `0件`
- 対応済み: `0件`

### ユーザーへの確認事項

> 該当なし

## レビューの前提と範囲

- レビュー目的: retry処理の重複を防ぐ
- このPRの対象: retry処理
- このPRの非対象: 外部サービス全体の再設計
- プロジェクトの性質・利用者: 公開サービスの利用者
- 現実的な攻撃者・誤操作・障害: 認証済み利用者の通常入力
- データの機密性・完全性: 内部データの完全性
- 防御・検知・復旧: 入力検証と監査ログ
- 不明点・保守的仮定: 外部サービスの再試行仕様は未確認
- 前回からの変更: 比較対象なし

## Claude／Codexクロスチェック

| Finding ID | Claude重要度 | Codex重要度 | 最終重要度 | 今回の取扱い | 訂正理由 |
|---|---|---|---|---|---|
| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |

### 最終重要度件数

| 重要度 | 件数 | 意味 |
|---|---:|---|
| Critical | 0 | 極めて重大 |
| High | 0 | 重大 |
| Medium | 1 | 明確な支障 |
| Low | 0 | 軽微・改善提案 |

### 今回の取扱い件数

| 今回の取扱い | 件数 | 意味 |
|---|---:|---|
| このPRでの対応候補 | 1 | 目的達成との直接関係あり |
| ユーザー判断が必要 | 0 | 仕様・信頼境界・スコープの判断待ち |
| 追加確認が必要 | 0 | 事実・再現性・重要度の確定待ち |
| 別Issue候補 | 0 | 妥当だが当PRの目的外 |
| 受容済み・見送り済み | 0 | 既存判断を維持 |
| 対応済み | 0 | 固定HEADで解消済み |

## Findings

### Critical (0件)

> 該当なし

### High (0件)

> 該当なし

### Medium (1件)

#### M1. [F1] retryで処理が重複する

- 今回の取扱い: `このPRでの対応候補`
- 取扱いの根拠: 変更したretry経路が直接原因
- 目的との関係: retry重複防止という受け入れ条件に直接関係する
- 既存成功記録との照合: 通常成功テストはtimeout後retryを通らないため両立する
- 既存判断との照合: 初出
- 場所: `src/retry.ts:10`
- 成立条件: timeout後に通常のretryを行う
- 影響: 同じ更新が2回反映される
- 問題の根拠: 更新後の応答喪失を未完了として扱う
- コードパス: `handler`から`save`まで
- 確認した防御: idempotency keyがないことを確認
- レビュアー判定: Claude `Medium` / Codex `High` → 最終 `Medium`
- 検出: `両方`
- 修正案: idempotency keyを保存する
- 修正案の裏付け: 既存repositoryが同じkeyを保存できる
- 修正案の影響範囲レビュー:
  - 修正案の評価: `条件付き修正案`
  - 既存呼び出し元への影響: optional引数を追加する
  - テストへの影響: retry testを追加する
  - デグレ確認: 外部サービス仕様が未確認
  - proportionality: 局所変更で収まる
  - 追加検証: sandbox APIで重複拒否を確認する

### Low (0件)

> 該当なし

## 除外・撤回・降格した候補

### Phase 5で除外したfindings

> 該当なし

### Phase 2〜4で棄却・撤回した候補

> 該当なし

## ラウンド別集計

| Round | 視点 | Claude状態 | Codex状態 | Claude新規 | Codex新規 | 重複 | 撤回 | 降格 | 昇格 | 据置 | 最終集合変化 |
|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | ロジック | 成功 | 成功 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | なし |
| 2 | セキュリティ | 成功 | 成功 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | なし |

## 収束判定

- 判定: `収束`
- 安定round: `連続2回`
- 終了条件: 実質新規0件、重要度変更0件、最終集合変化なし
- 未収束の懸念: なし
- 撤回候補: なし

## PRコメント照合結果

- 取得状態: checked

| 情報源 | 取得件数 | 状態・未取得範囲 |
|---|---:|---|
| Issue comments | 0 | 完全取得 |
| Reviews | 0 | 完全取得 |
| Inline comments | 0 | 完全取得 |
| Review threads | 0 | 完全取得 |

- 照合: Phase 4候補 `1`件 → 除外 `0`件（addressed `0` / dismissed-valid `0`）→ 継続 `1`件（dismissed-but-rechallenge `0` / not-judged `1`）→ 最終 `1`件
- 判定内訳: addressed=`0`, dismissed-valid=`0`, dismissed-but-rechallenge=`0`, not-judged=`1`
- 件数集計: Phase4=`1`, 除外=`0`, 継続=`1`, 最終=`1`
- 件数式: `1 = 0 + 1、1 = 1`
- UI状態だけで除外した候補: `0件`

## 未検証事項

外部サービスのsandbox APIは未実施。

## 実行証跡

- 対象: `pr:42`
- BASE / HEAD / merge-base: `1111111111111111111111111111111111111111 / 2222222222222222222222222222222222222222 / 1111111111111111111111111111111111111111`
- オーケストレーター: `Codex`
- Claude reviewer: `Claude Code CLI opus / effort=xhigh`
- Codex reviewer: `Codex CLI gpt-5.6-sol / reasoning=high`
- review run ID: `11111111-1111-4111-8111-111111111111`
- tooling digest: `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- diff digest: `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`
- snapshot metadata digest: `cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc`
- BASE guidance digest: `dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd`
- final finding-set digest: `b7f968755bdb55d6656952a4a215454c22cabcce5e9ad68b0bfab15e8fc84753`
- handling digest: `eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee`
- 初回review: Claude `成功` / Codex `成功`
- retry / resume / 失敗: `なし`
- run固有report: `/tmp/report.md`
REPORT

echo "== RC01: valid integrated report =="
expect_pass "$T/valid.md" "valid report passes the structural and count contract"
sed 's/更新後の応答喪失を未完了として扱う/Result<T>の失敗分岐が未完了を返す/' \
  "$T/valid.md" > "$T/generic-type.md"
expect_pass "$T/generic-type.md" "TypeScript generic syntax is not mistaken for a placeholder"
sed \
  -e 's/#### M1. \[F1\] retryで処理が重複する/#### M1. [F1] `retry()`で処理が重複する/' \
  -e 's/b7f968755bdb55d6656952a4a215454c22cabcce5e9ad68b0bfab15e8fc84753/fbdf01dfcdf506c2be01827564462e04e2088da72ad12dcb817a6e3375e85c79/' \
  "$T/valid.md" > "$T/inline-code-title.md"
expect_pass "$T/inline-code-title.md" "finding title preserves Markdown inline code for its digest"
awk '
  /^- 問題の根拠:/ {
    print "<details>"
    print "<summary>監査・修正案の詳細</summary>"
    print ""
  }
  { print }
  /^  - 追加検証:/ {
    print ""
    print "</details>"
  }
' "$T/valid.md" > "$T/details-layout.md"
expect_pass "$T/details-layout.md" \
  "human-readable details layout preserves the machine report contract"
low_digest=$(node --input-type=module - "$SKILL_DIR/scripts/review-adjudication.mjs" <<'NODE'
import { pathToFileURL } from "node:url";
const { findingSetSha256 } = await import(pathToFileURL(process.argv[2]));
process.stdout.write(findingSetSha256([
  {id:"F1",severity:"Low",title:"retryで処理が重複する"},
]));
NODE
)
awk '
  $0 == "### Medium (1件)" {
    print "### Medium (0件)"
    print ""
    print "> 該当なし"
    capture = 1
    next
  }
  capture && $0 == "### Low (0件)" {
    capture = 0
    print "### Low (1件)"
    print ""
    for (idx = 1; idx <= captured; idx++) print buffer[idx]
    skip_low_marker = 1
    next
  }
  capture {
    if ($0 ~ /^#### M1\. \[F1\]/) sub(/^#### M1\./, "#### L1.")
    gsub(/→ 最終 `Medium`/, "→ 最終 `Low`")
    buffer[++captured] = $0
    next
  }
  skip_low_marker && $0 == "> 該当なし" { skip_low_marker = 0; next }
  { print }
' "$T/valid.md" > "$T/low-finding-layout.md"
sed \
  -e 's/| Medium | 1 | 明確な支障 |/| Medium | 0 | 明確な支障 |/' \
  -e 's/| Low | 0 | 軽微・改善提案 |/| Low | 1 | 軽微・改善提案 |/' \
  -e 's/| F1 | Medium | High | Medium |/| F1 | Medium | High | Low |/' \
  -e "s/b7f968755bdb55d6656952a4a215454c22cabcce5e9ad68b0bfab15e8fc84753/$low_digest/" \
  "$T/low-finding-layout.md" > "$T/low-finding.md"
expect_pass "$T/low-finding.md" \
  "Low findings preserve the handling and scope fields"

echo "== RC02: section and count failures are rejected =="
node --input-type=module - "$T" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
const root = process.argv[2];
const legacy = readFileSync(`${root}/valid.md`, "utf8");
const readable = legacy
  .replace("#### M1. [F1] retryで処理が重複する", "#### M1. 再試行すると同じ更新が2回反映される")
  .replace("### Low (0件)", "- **監査**\n  - 正典ID: F1\n  - 正典題名: retryで処理が重複する\n\n### Low (0件)");
writeFileSync(`${root}/readable-title.md`, readable);
writeFileSync(`${root}/readable-reworded.md`, readable.replace("再試行すると同じ更新が2回反映される", "通信の再試行で更新が重複する"));
writeFileSync(`${root}/readable-wrong-id.md`, readable.replace("正典ID: F1", "正典ID: F2"));
writeFileSync(`${root}/readable-wrong-title.md`, readable.replace("正典題名: retryで処理が重複する", "正典題名: 別の指摘"));
writeFileSync(`${root}/readable-missing-id.md`, readable.replace("  - 正典ID: F1\n", ""));
writeFileSync(`${root}/readable-duplicate-id.md`, readable.replace("  - 正典ID: F1", "  - 正典ID: F1\n  - 正典ID: F2"));
writeFileSync(`${root}/readable-no-audit.md`, readable.replace("- **監査**", "- 別の欄"));
writeFileSync(`${root}/readable-missing-evidence.md`, readable.replace(/^- 問題の根拠:.*\n/mu, ""));
const inline = readFileSync(`${root}/inline-code-title.md`, "utf8")
  .replace("#### M1. [F1] `retry()`で処理が重複する", "#### M1. 再試行で更新が重複する")
  .replace("### Low (0件)", "- **監査**\n  - 正典ID: F1\n  - 正典題名: `retry()`で処理が重複する\n\n### Low (0件)");
writeFileSync(`${root}/readable-inline-canonical.md`, inline);
const grouped = [
  "#### M1. 再試行すると同じ更新が2回反映される", "",
  "- **仕組みと影響**",
  "  - 問題の根拠: 更新後の応答喪失を未完了として扱う",
  "  - コードパス: `handler`から`save`まで",
  "  - 成立条件: timeout後に通常のretryを行う",
  "  - 影響: 同じ更新が2回反映される", "",
  "- **このPRでの扱い**",
  "  - 今回の取扱い: `このPRでの対応候補`",
  "  - 取扱いの根拠: 変更したretry経路が直接原因",
  "  - 目的との関係: retry重複防止という受け入れ条件に直接関係する",
  "  - 既存判断との照合: 初出", "",
  "- **該当箇所と確認済みのこと**",
  "  - 場所: `src/retry.ts:10`",
  "  - 確認した防御: idempotency keyがないことを確認",
  "  - 既存成功記録との照合: 通常成功テストはtimeout後retryを通らないため両立する", "",
  "- **今後確認すべきこと**",
  "  - 追加検証: sandbox APIで重複拒否を確認する", "",
  "- **対処案**",
  "  - 修正案: idempotency keyを保存する",
  "  - 修正案の裏付け: 既存repositoryが同じkeyを保存できる",
  "  - 修正案の影響範囲レビュー:",
  "    - 修正案の評価: `条件付き修正案`",
  "    - 既存呼び出し元への影響: optional引数を追加する",
  "    - テストへの影響: retry testを追加する",
  "    - デグレ確認: 外部サービス仕様が未確認",
  "    - proportionality: 局所変更で収まる", "",
  "- **監査**",
  "  - 正典ID: F1",
  "  - 正典題名: retryで処理が重複する",
  "  - レビュアー判定: Claude `Medium` / Codex `High` → 最終 `Medium`",
  "  - 検出: `両方`", "", "",
].join("\n");
const templateReport = legacy
  .replace(/#### M1\.[\s\S]*?(?=### Low)/u, grouped)
  .replace("## レビューの前提と範囲\n", "## レビューの前提と範囲\n\n### 表記\n\n- **指摘ID**\n  - 重要度別の番号。元の記録との対応は監査欄に記載する。\n- **今回の取扱い**\n  - このPRでの扱いを表す。\n\n### 対象\n");
writeFileSync(`${root}/readable-template.md`, templateReport);
NODE
expect_pass "$T/readable-template.md" "complete grouped template preserves all finding and section contracts"
expect_pass "$T/readable-title.md" "readable title uses the audit identity for canonical comparison"
expect_pass "$T/readable-reworded.md" "rewording only the display title preserves finding identity"
expect_pass "$T/readable-inline-canonical.md" "audit title preserves inline code for the canonical digest"
expect_fail "$T/readable-wrong-id.md" "wrong audit ID fails canonical comparison"
expect_fail "$T/readable-wrong-title.md" "wrong audit title fails canonical comparison"
expect_fail "$T/readable-missing-id.md" "readable finding requires its canonical ID"
expect_fail "$T/readable-duplicate-id.md" "ambiguous canonical IDs are rejected"
expect_fail "$T/readable-no-audit.md" "canonical identity must be in the finding audit block"
expect_fail "$T/readable-missing-evidence.md" "readable layout does not waive factual evidence"
sed 's/## レビューの前提と範囲/## レビューの前提と範囲 missing/' "$T/valid.md" > "$T/missing-section.md"
expect_fail "$T/missing-section.md" "missing required section fails"
sed 's/### Medium (1件)/### Medium (2件)/' "$T/valid.md" > "$T/heading-count.md"
expect_fail "$T/heading-count.md" "severity heading count mismatch fails"
sed 's/| Medium | 1 | 明確な支障 |/| Medium | 2 | 明確な支障 |/' "$T/valid.md" > "$T/table-count.md"
expect_fail "$T/table-count.md" "severity table count mismatch fails"
sed '/| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |/d' "$T/valid.md" > "$T/cross-count.md"
expect_fail "$T/cross-count.md" "cross-check row count mismatch fails"
sed 's/| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |/| F1 | Medium | High | High | このPRでの対応候補 | 到達条件限定 |/' \
  "$T/valid.md" > "$T/cross-distribution.md"
expect_fail "$T/cross-distribution.md" "cross-check severity distribution mismatch fails"
sed 's/| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |/| F2 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |/' \
  "$T/valid.md" > "$T/cross-id.md"
expect_fail "$T/cross-id.md" "cross-check IDs must match report finding IDs"
sed 's/#### M1. \[F1\] retryで処理が重複する/#### M1. [F2] retryで処理が重複する/' \
  "$T/valid.md" > "$T/finding-id.md"
expect_fail "$T/finding-id.md" "finding IDs are bound to the cross-check table"
sed 's/retryで処理が重複する/retryで別の処理が重複する/' \
  "$T/valid.md" > "$T/finding-title.md"
expect_fail "$T/finding-title.md" "finding titles are bound to the final finding-set digest"

echo "== RC03: restored quality fields are enforced =="
sed '/修正案の評価:/d' "$T/valid.md" > "$T/missing-status.md"
expect_fail "$T/missing-status.md" "Medium finding without fix proposal evaluation fails"
sed '/- 今回の取扱い:/d' "$T/valid.md" > "$T/missing-handling.md"
expect_fail "$T/missing-handling.md" "finding without handling fails"
awk '
  $0 == "- このPRでの対応候補: `1件`" { print "- このPRでの対応候補: `0件`"; next }
  $0 == "- ユーザー判断が必要: `0件`" { print "- ユーザー判断が必要: `1件`"; next }
  $0 == "| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |" {
    print "| F1 | Medium | High | Medium | ユーザー判断が必要 | 到達条件限定 |"; next
  }
  $0 == "| このPRでの対応候補 | 1 | 目的達成との直接関係あり |" {
    print "| このPRでの対応候補 | 0 | 目的達成との直接関係あり |"; next
  }
  $0 == "| ユーザー判断が必要 | 0 | 仕様・信頼境界・スコープの判断待ち |" {
    print "| ユーザー判断が必要 | 1 | 仕様・信頼境界・スコープの判断待ち |"; next
  }
  $0 == "- 今回の取扱い: `このPRでの対応候補`" {
    print "- 今回の取扱い: `ユーザー判断が必要`"; next
  }
  $0 == "- 取扱いの根拠: 変更したretry経路が直接原因" {
    print
    print "- ユーザーへの確認事項: 外部サービス仕様の確認をこのPRへ含めるか"
    print "- 選択による影響: 含める場合は仕様確認完了まで保留し、含めない場合は別Issueで追跡する"
    next
  }
  $0 == "### ユーザーへの確認事項" { in_decisions = 1; print; next }
  in_decisions && $0 == "> 該当なし" {
    print "| Finding ID | 確認事項 | 選択による影響 |"
    print "|---|---|---|"
    print "| F1 | 外部サービス仕様の確認をこのPRへ含めるか | 含める場合は仕様確認完了まで保留し、含めない場合は別Issueで追跡する |"
    in_decisions = 0
    next
  }
  { print }
' "$T/valid.md" > "$T/user-decision.md"
expect_pass "$T/user-decision.md" \
  "user decision report binds the question and decision impact to its summary"
awk '
  $0 == "- ユーザーへの確認事項: 外部サービス仕様の確認をこのPRへ含めるか" {
    print "- ユーザーへの確認事項: `API|retry`仕様の確認をこのPRへ含めるか"; next
  }
  $0 == "| F1 | 外部サービス仕様の確認をこのPRへ含めるか | 含める場合は仕様確認完了まで保留し、含めない場合は別Issueで追跡する |" {
    print "| F1 | `API\\|retry`仕様の確認をこのPRへ含めるか | 含める場合は仕様確認完了まで保留し、含めない場合は別Issueで追跡する |"; next
  }
  { print }
' "$T/user-decision.md" > "$T/user-decision-markdown.md"
expect_pass "$T/user-decision-markdown.md" \
  "user decision summary supports inline code and escaped table pipes"
sed '/- 選択による影響:/d' "$T/user-decision.md" > "$T/user-decision-no-impact.md"
expect_fail "$T/user-decision-no-impact.md" \
  "user decision report requires the impact of each choice"
sed \
  -e 's/- 今回の取扱い: `このPRでの対応候補`/- 今回の取扱い: `追加確認が必要`/' \
  -e 's/| F1 | Medium | High | Medium | このPRでの対応候補 | 到達条件限定 |/| F1 | Medium | High | Medium | 追加確認が必要 | 到達条件限定 |/' \
  -e 's/- このPRでの対応候補: `1件`/- このPRでの対応候補: `0件`/' \
  -e 's/- 追加確認が必要: `0件`/- 追加確認が必要: `1件`/' \
  -e 's/| このPRでの対応候補 | 1 | 目的達成との直接関係あり |/| このPRでの対応候補 | 0 | 目的達成との直接関係あり |/' \
  -e 's/| 追加確認が必要 | 0 | 事実・再現性・重要度の確定待ち |/| 追加確認が必要 | 1 | 事実・再現性・重要度の確定待ち |/' \
  "$T/valid.md" > "$T/verification-no-request.md"
expect_fail "$T/verification-no-request.md" \
  "additional verification report requires a concrete verification request"
sed 's/| このPRでの対応候補 | 1 | 目的達成との直接関係あり |/| このPRでの対応候補 | 0 | 目的達成との直接関係あり |/' \
  "$T/valid.md" > "$T/handling-count.md"
expect_fail "$T/handling-count.md" "handling counts cannot undercount visible findings"
sed 's/| 重要度 | 件数 | 意味 |/| 重要度 | 件数 | マージ前対応 |/' \
  "$T/valid.md" > "$T/severity-as-action.md"
expect_fail "$T/severity-as-action.md" \
  "severity table cannot silently become a required-action table"
sed '/- 前回からの変更:/d' "$T/valid.md" > "$T/missing-prior-scope.md"
expect_fail "$T/missing-prior-scope.md" \
  "report must state whether review premises changed from the prior run"
sed 's/| Review threads | 0 | 完全取得 |/| Other | 0 | 完全取得 |/' "$T/valid.md" > "$T/comments.md"
expect_fail "$T/comments.md" "missing review-thread accounting fails"
sed '/retry \/ resume \/ 失敗:/d' "$T/valid.md" > "$T/trace.md"
expect_fail "$T/trace.md" "missing retry resume failure trace fails"
sed 's/- 場所: `src\/retry.ts:10`/- 場所:/' "$T/valid.md" > "$T/empty-field.md"
expect_fail "$T/empty-field.md" "empty finding field fails"
sed 's#`src/retry.ts:10`#`<path>:<line>`#' "$T/valid.md" > "$T/placeholder-field.md"
expect_fail "$T/placeholder-field.md" "placeholder finding field fails"
sed 's/#### M1. \[F1\] retryで処理が重複する/#### M1. [F1] <短い題名>/' \
  "$T/valid.md" > "$T/placeholder-title.md"
expect_fail "$T/placeholder-title.md" "placeholder finding title fails"
sed 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/<sha256>/' \
  "$T/valid.md" > "$T/placeholder-trace.md"
expect_fail "$T/placeholder-trace.md" "placeholder execution trace fails"
# Remove only the Phase 5 empty marker without relying on a Markdown parser.
awk '
  /^### Phase 5で除外したfindings$/ { phase5 = 1; print; next }
  phase5 && /^> 該当なし$/ { phase5 = 0; next }
  { print }
' "$T/valid.md" > "$T/empty-exclusions.md"
expect_fail "$T/empty-exclusions.md" "empty exclusions section requires an explicit marker"
awk '
  /^## 除外・撤回・降格した候補$/ {
    print
    print ""
    print "### Phase 5で除外したfindings"
    print ""
    print "| # | Finding ID | 候補 | 元重要度 | 今回の取扱い | 理由・根拠 |"
    print "|---|---|---|---|---|---|"
    print ""
    print "### Phase 2〜4で棄却・撤回した候補"
    print ""
    print "> 該当なし"
    skip = 1
    next
  }
  /^## ラウンド別集計$/ { skip = 0 }
  !skip { print }
' "$T/valid.md" > "$T/header-only-exclusions.md"
expect_fail "$T/header-only-exclusions.md" \
  "excluded-candidate header without data rows fails"
awk '
  /^## 除外・撤回・降格した候補$/ { exclusions = 1 }
  { print }
  exclusions && /^\|---\|---\|---\|---\|---\|---\|$/ {
    print "| X1 | F2 | 重複候補 | Medium | 受容済み・見送り済み | 同じコードパス |"
    exclusions = 0
  }
' "$T/header-only-exclusions.md" > "$T/excluded-candidate.md"
expect_pass "$T/excluded-candidate.md" "a complete excluded-candidate row passes"
sed 's/| Issue comments | 0 | 完全取得 |/| Issue comments | <N> | <状態> |/' \
  "$T/valid.md" > "$T/placeholder-comment-source.md"
expect_fail "$T/placeholder-comment-source.md" \
  "placeholder PR comment source count and state fail"
sed 's/- 取得状態: checked/- 取得状態: unknown/' \
  "$T/valid.md" > "$T/invalid-comment-status.md"
expect_fail "$T/invalid-comment-status.md" \
  "unknown PR comment acquisition status fails"

echo "== RC04: convergence and PR accounting semantics are enforced =="
sed '/| 2 | セキュリティ |/d' "$T/valid.md" > "$T/one-stable-round.md"
expect_fail "$T/one-stable-round.md" "convergence with only one stable round fails"
awk '
  /^\| 2 \| セキュリティ \|/ {
    print
    print "| 3 | 追加視点 | 成功 | 成功 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | なし |"
    next
  }
  { print }
' "$T/valid.md" > "$T/post-convergence-round.md"
expect_fail "$T/post-convergence-round.md" \
  "a report cannot contain rounds after convergence was first reached"
sed \
  -e '/| 2 | セキュリティ |/d' \
  -e 's/- 判定: `収束`/- 判定: `未収束`/' \
  -e 's/- 安定round: `連続2回`/- 安定round: `連続1回`/' \
  "$T/valid.md" > "$T/early-unconverged.md"
expect_fail "$T/early-unconverged.md" \
  "an unconverged report cannot stop before the maximum round"
awk '
  /^\| 2 \| セキュリティ \|/ {
    print
    for (round = 3; round <= 21; round++) {
      printf "| %d | 追加視点 | 成功 | 成功 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | なし |\n", round
    }
    next
  }
  { print }
' "$T/valid.md" > "$T/twenty-one-rounds.md"
expect_fail "$T/twenty-one-rounds.md" \
  "a report cannot exceed twenty convergence rounds"
sed 's/| 2 | セキュリティ | 成功 | 成功 |/| 2 | セキュリティ | 成功 | 失敗 |/' \
  "$T/valid.md" > "$T/failed-reviewer-convergence.md"
expect_fail "$T/failed-reviewer-convergence.md" \
  "convergence fails when either reviewer did not succeed"
sed 's/- 判定: `収束`/- 判定: `判定中`/' "$T/valid.md" > "$T/invalid-convergence.md"
expect_fail "$T/invalid-convergence.md" "unknown convergence decision fails"
sed 's/Phase4=`1`, 除外=`0`, 継続=`1`, 最終=`1`/Phase4=`2`, 除外=`0`, 継続=`1`, 最終=`1`/' \
  "$T/valid.md" > "$T/bad-comment-arithmetic.md"
expect_fail "$T/bad-comment-arithmetic.md" "inconsistent PR comment arithmetic fails"
sed 's/最終=`1`/最終=`0`/' "$T/valid.md" > "$T/bad-final-total.md"
expect_fail "$T/bad-final-total.md" "PR comment final total must match findings"
sed \
  -e 's/- 取得状態: checked/- 取得状態: not-checked/' \
  -e 's/Phase4=`1`, 除外=`0`, 継続=`1`, 最終=`1`/Phase4=`2`, 除外=`1`, 継続=`1`, 最終=`1`/' \
  -e 's/`1 = 0 + 1、1 = 1`/`2 = 1 + 1、1 = 1`/' \
  "$T/valid.md" > "$T/not-checked-exclusion.md"
expect_fail "$T/not-checked-exclusion.md" \
  "not-checked PR comments cannot exclude findings"
awk '
  /^## PRコメント照合結果$/ {
    print
    print ""
    print "PR未作成のため不適用"
    skip = 1
    next
  }
  /^## 未検証事項$/ { skip = 0 }
  !skip { print }
' "$T/valid.md" > "$T/pr-skips-comments.md"
expect_fail "$T/pr-skips-comments.md" "PR report cannot use the branch reconciliation escape hatch"

echo ""
echo "== RC05: approved dialogue-first presentation =="
for fixture in valid readable-template low-finding user-decision user-decision-markdown excluded-candidate; do
  node "$TEST_DIR/report-dialogue-fixture.mjs" "$T/$fixture.md" "$T/dialogue-$fixture.md"
  expect_pass "$T/dialogue-$fixture.md" "dialogue layout preserves $fixture"
done
node --input-type=module - "$T" "$TEST_DIR/report-dialogue-fixture.mjs" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const {dialogueFixture}=await import(pathToFileURL(process.argv[3]));
const root=process.argv[2];
const good=readFileSync(`${root}/dialogue-valid.md`,'utf8');
writeFileSync(`${root}/dialogue-verification.md`,dialogueFixture(
  readFileSync(`${root}/verification-no-request.md`,'utf8')
    .replace('- 既存判断との照合: 初出','- 既存判断との照合: 初出\n- 必要な追加確認: 更新が重複する経路はコードで確認済み。外部サービスの履歴は権限不足で未取得のため、履歴を照合して影響件数・範囲と対応優先度を確定する。'))
  .replace('- 必要な追加確認:', '- 未確認の内容・理由と判断への影響:'));
writeFileSync(`${root}/dialogue-user-decision-code-id.md`,
  readFileSync(`${root}/dialogue-user-decision-markdown.md`,'utf8')
    .replaceAll('| M1 |','| `M1` |'));
writeFileSync(`${root}/dialogue-plain-labels.md`,good
  .replaceAll('- 確認した防御:', '- 既存の対策で、この問題を防げるか:')
  .replaceAll('- proportionality:', '- 変更の大きさと必要性:')
  .replaceAll('- 追加検証:', '- 修正案を採用した場合の確認方法:')
  .replaceAll('- 修正案の影響範囲レビュー:', '- 採用判断と影響範囲:'));
const cases={
  'dialogue-wrong-overview':good.replace('| Medium | 1 | 0 |','| Medium | 2 | 0 |'),
  'dialogue-invented-decision':good.replace('| Medium | 1 | 0 |','| Medium | 1 | 1 |'),
  'dialogue-wrong-index':good.replace('| M1 | retryで処理が重複する | このPRでの対応候補 | 未確認 |','| M1 | 別の問題 | このPRでの対応候補 | 未確認 |'),
  'dialogue-missing-index':good.replace(/^\| M1 \|.*\| 未確認 \|$/mu,''),
  'dialogue-wrong-model':good.replace('| M1 | retryで処理が重複する | Medium | High | Medium |','| M1 | retryで処理が重複する | Low | High | Medium |'),
  'dialogue-wrong-total':good.replace('C0 H0 M1 L0（計1）','C0 H0 M1 L0（計2）'),
  'dialogue-missing-primary':good.replace(/^\| 初回 \|.*$/mu,''),
  'dialogue-missing-round':good.replace(/^\| 2 \| C.*$/mu,''),
  'dialogue-duplicate-round':good.replace(/^(\| 2 \| C.*)$/mu,'$1\n$1'),
  'dialogue-duplicate-section':good.replace('## 重要度別の集計','## 重要度別の集計\n\n## 重要度別の集計'),
  'dialogue-missing-evidence':good.replace(/^- 問題の根拠:.*\n/mu,''),
  'dialogue-missing-canonical-id':good.replace(/^\s*- 正典ID:.*\n/mu,''),
  'dialogue-invented-state':good.replaceAll('未確認','対応済み・push済み'),
};
for(const [name,text] of Object.entries(cases)) writeFileSync(`${root}/${name}.md`,text);
NODE
expect_pass "$T/dialogue-plain-labels.md" "plain labels preserve defense and proposal checks"
expect_pass "$T/dialogue-user-decision-code-id.md" "code-formatted display IDs preserve user decision mapping"
expect_pass "$T/dialogue-verification.md" "plain unverified-point label preserves the verification request"
for fixture in wrong-overview invented-decision wrong-index missing-index wrong-model wrong-total missing-primary missing-round duplicate-round duplicate-section missing-evidence missing-canonical-id invented-state; do
  expect_fail "$T/dialogue-$fixture.md" "dialogue rejects $fixture"
done

echo "== RC06: final findings are partitioned without dropping audit evidence =="
node --input-type=module - "$T" "$TEST_DIR/report-dialogue-fixture.mjs" "$SKILL_DIR/scripts/review-adjudication.mjs" "$VALIDATOR" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [root, fixturePath, adjudicationPath, validatorPath] = process.argv.slice(2);
const { dialogueFixture } = await import(pathToFileURL(fixturePath));
const { findingSetSha256 } = await import(pathToFileURL(adjudicationPath));
const { validateReviewReport } = await import(pathToFileURL(validatorPath));
let legacy = readFileSync(`${root}/user-decision.md`, 'utf8');
const title = 'retryで処理が重複する';
const block = legacy.match(/^#### M1\.[\s\S]*?(?=^### Low)/mu)[0].trim();
const separateBlock = (displayId, id, severity) => block
  .replace(`#### M1. [F1] ${title}`, `#### ${displayId}. [${id}] ${title}`)
  .replace('- 今回の取扱い: `ユーザー判断が必要`', '- 今回の取扱い: `別Issue候補`')
  .replace(/^- (?:ユーザーへの確認事項|選択による影響):.*\n/gmu, '')
  .replace('→ 最終 `Medium`', `→ 最終 \`${severity}\``);
legacy = legacy
  .replace('### Medium (1件)', '### Medium (2件)')
  .replace(block, `${block}\n\n${separateBlock('M2', 'F2', 'Medium')}`)
  .replace('### Low (0件)\n\n> 該当なし', `### Low (1件)\n\n${separateBlock('L1', 'F3', 'Low')}`)
  .replace('| Medium | 1 | 明確な支障 |', '| Medium | 2 | 明確な支障 |')
  .replace('| Low | 0 | 軽微・改善提案 |', '| Low | 1 | 軽微・改善提案 |')
  .replace('| F1 | Medium | High | Medium | ユーザー判断が必要 | 到達条件限定 |',
    '| F1 | Medium | High | Medium | ユーザー判断が必要 | 到達条件限定 |\n' +
    '| F2 | Medium | High | Medium | 別Issue候補 | 到達条件限定 |\n' +
    '| F3 | Medium | High | Low | 別Issue候補 | 到達条件限定 |')
  .replace('- 別Issue候補: `0件`', '- 別Issue候補: `2件`')
  .replace('| 別Issue候補 | 0 |', '| 別Issue候補 | 2 |')
  .replace(/^- 件数集計:.*$/mu, '- 件数集計: Phase4=3, 除外=0, 継続=3, 最終=3')
  .replace(/^- 件数式:.*$/mu, '- 件数式: 3 = 0 + 3、3 = 3')
  .replace(/^- 判定内訳:.*$/mu, '- 判定内訳: addressed=0, dismissed-valid=0, dismissed-but-rechallenge=0, not-judged=3');
const finalFindings = [
  { id: 'F1', severity: 'Medium', title },
  { id: 'F2', severity: 'Medium', title },
  { id: 'F3', severity: 'Low', title },
];
const digest = findingSetSha256(finalFindings);
legacy = legacy.replace(/^- final finding-set digest:.*$/mu, `- final finding-set digest: ${digest}`);
const good = dialogueFixture(legacy);
writeFileSync(`${root}/dialogue-partitioned.md`, good);
const result = validateReviewReport(`${root}/dialogue-partitioned.md`);
assert.equal(result.total, 3);
assert.deepEqual(result.counts, { Critical: 0, High: 0, Medium: 2, Low: 1 });
assert.equal(result.handlingCounts['別Issue候補'], 2);
assert.ok(good.includes('| Medium | 2 | 0 | 1 | 1 |'));
assert.ok(good.includes('| Low | 1 | — | 0 | 1 |'));
assert.ok(good.includes(`- final finding-set digest: ${digest}`));
assert.ok(good.includes('| M1 | 外部サービス仕様の確認をこのPRへ含めるか |'));
const separateRow = `| M2 | ${title} | 別Issue候補 | 未確認 |`;
const mainRow = `| M1 | ${title} | ユーザー判断が必要 | 未確認 |`;
const separateSection = /### 別Issue候補（Medium以上）\n[\s\S]*?(?=### ユーザーへの確認事項)/u;
const cases = {
  'partition-forged-main-count': good.replace('| Medium | 2 | 0 | 1 | 1 |', '| Medium | 2 | 0 | 2 | 1 |'),
  'partition-swapped-counts': good.replace('| Medium | 2 | 0 | 1 | 1 |', '| Medium | 2 | 0 | 2 | 0 |'),
  'partition-forged-separate-count': good.replace('| Medium | 2 | 0 | 1 | 1 |', '| Medium | 2 | 0 | 1 | 2 |'),
  'partition-forged-low-count': good.replace('| Low | 1 | — | 0 | 1 |', '| Low | 1 | — | 0 | 2 |'),
  'partition-missing-low-count': good.replace('| Low | 1 | — | 0 | 1 |', '| Low | 1 | — | 0 | 0 |'),
  'partition-missing-separate-section': good.replace(separateSection, ''),
  'partition-empty-separate': good.replace(separateRow, '> 該当なし'),
  'partition-separate-in-main': good.replace(separateRow, '> 該当なし').replace(mainRow, `${mainRow}\n${separateRow}`),
  'partition-main-in-separate': good.replace(mainRow, '> 該当なし').replace(separateRow, `${separateRow}\n${mainRow}`),
  'partition-missing-cross-check': good.replace(/^\| L1 \|.*\| Low \|$/mu, ''),
  'partition-main-only-digest': good.replace(digest, findingSetSha256(finalFindings.slice(0, 1))),
};
for (const [name, text] of Object.entries(cases)) writeFileSync(`${root}/${name}.md`, text);
const zero = readFileSync(`${root}/dialogue-valid.md`, 'utf8');
writeFileSync(`${root}/partition-missing-empty-section.md`, zero.replace(/### 別Issue候補（Medium以上）\n[\s\S]*?(?=## レビューの前提と範囲)/u, ''));
NODE
check_partition_rc=$?
if [ "$check_partition_rc" = "0" ]; then
  ok "mixed severity partitions preserve Low, user decisions and the complete final digest"
else
  ng "mixed severity partition fixture and audit assertions"
fi
for fixture in forged-main-count swapped-counts forged-separate-count forged-low-count missing-low-count missing-separate-section empty-separate separate-in-main main-in-separate missing-cross-check main-only-digest missing-empty-section; do
  expect_fail "$T/partition-$fixture.md" "dialogue rejects partition $fixture"
done

printf 'RESULT: pass=%s fail=%s\n' "$pass" "$fail"
exit "$fail"
