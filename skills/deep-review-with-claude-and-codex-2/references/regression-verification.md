# 回帰検証

## 機械的suite

```bash
bash scripts/test-regression.sh
```

fake Claude/Codex CLIと一時Gitリポジトリを使い、外部ネットワークや実モデルへ接続せず次を検証する。

- Codex read-only sandbox、private cwd、multi-agent無効化、timeout、resume、
  起動前readonly DB / app-server拒否のexit 3分類
- Codexホストの固定reviewer launcherがinitial pair、片側retry/resume、wave、Claude follow-upの
  正規形だけを受理し、任意option、run外prompt、run外出力、未知modeを外部CLI起動前に拒否すること
- prepared contextがinstalled reviewer launcherを固定し、tooling digest検証後も既存のrun固有
  pair / wave / Claude runnerへそのまま委譲すること
- Claude follow-upのstdout/stderrがfresh directory内の新規fileだけに限定され、private umaskと
  noclobberで既存fileやsymlinkを上書きしないこと
- Claude safe mode、許可/deny tool、private cwd、timeout、resume
- Claude/Codex input receipt、digest、challenge、diff probe、本文契約
- `.gitattributes`、replace ref、external diff、textconv、symlink、gitlinkを信用しないsafe diff/snapshot
- tooling snapshot、BASE guidance、run全体integrity
- trusted preflightによるbranch/PRの固定入力、初期PR context、段階別時刻、失敗伝播、reviewer未起動
- run IDと成果物の並行分離、原子的なcompatibility copy
- Claude/Codex pairの同時起動、片側retry/resume、attempt履歴、モデル別正典結果、
  exit 3側だけのfresh retryと成功側の保持
- 連続2roundのwave並列起動、投機roundの隔離、昇格、中断、完了済み非採用、昇格後retry/resume
- leadのfinalize-only resumeと待機中の終了code回復、空wave directoryでの逐次互換性、逐次/wave同時claim
- dead lockの並行回収、stale reaperのfail-closed、完成済みlock metadataとwave予約の原子的公開、
  予約直後に停止したsupervisorへの安全な再接続、無効roundによる実行mode汚染の防止、中断promotionの再開
- fork直後の旧childと再接続childによるrole claim競合、開始済みroleを保持した部分wave再接続、
  wave/pairのforkとPID登録間のsignal保留、全role claim前のdecision拒否、取消後の外部CLI起動拒否、
  旧世代roleへ保存済みPIDだけでsignalしないこと、
  認証済み取消intentをrole所有者が実行して外側signalと収束時に旧世代childも回収すること、pair child自身の結果確定、
  実行開始後のsupervisor喪失からの同一action再同期、pair status欠落時の非正典終端化、
  lead status欠落時の`prior-failure`終端化、生存中supervisorの実測結果を待ってから終端化するcancel競合、
  正常結果確定後のlate signalでattempt/evidenceを再公開しないこと、
  promote対象のstatus欠落でも子process時間込みでboundedに停止すること、controllerが所有未確認PIDへsignalを送らないこと
- wave前半での収束、process group単位のsignal、非正典出力がfinding・収束・reportへ混入しないこと
- WindowsのGit Bash形式pathをNodeのfilesystem境界でnative pathへ戻すこと、promoted waveをpublisherまで
  通した成功系と非正典artifact改変の拒否、native supervisor PIDによる生存判定
- prompt manifestのreviewer・phase・round・purpose・digest照合、wrong-round／reviewer交換／生成後改変の拒否
- resume IDと同じphase/round・同じreviewerの直前失敗attemptとの照合、別run ID・欠落・重複・
  exit 3直後resumeの拒否、fresh retryの維持
- Claude/Codex両ホストが同じ外部2モデルを使う契約
- 共通threat model、7観点、重要度、Medium以上の修正案契約が両promptで一致すること
- 最終reportの必須section、クロスチェック表、4重要度、検出数と詳細件数・除外件数の合計、件数付き見出しと実finding数の一致
- 冒頭の本PR/別Issueの最終件数・Medium以上一覧がhandlingで分かれ、全最終集合・除外・監査と一致すること
- 重要度と今回の取扱いが独立し、4重要度と6取扱いの件数が正典artifact・集計表・findingで一致すること
- モデル別重要度、各roundの全候補数と統合後の採用累積が正典artifactと一致すること
- 重要度表がマージ前対応や必須・推奨・任意の表へ戻らないこと
- ユーザー判断に具体的な確認事項と選択の影響があり、追加確認には具体的な確認内容があること
- 過去判断の再提起根拠と、除外表のFinding ID・題名・重要度・取扱い・根拠が正典artifactと一致すること
- レポートが目的・対象・非対象・前回からの前提変更を日本語で明示すること
- round別の新規・重複・撤回・降格・昇格・据置と最終集合安定による収束契約
- PRコメント4情報源とretry / resume / 失敗を含む実行証跡
- 改良版の`pr-<N>-v2.md`とbranchの衝突しない`deep-review-2-*`が
  旧版の人向け直近コピーを上書きしないこと
- review-only toolingにworkspace-write入口が同梱されないこと
- 正典global / repository経路を維持し、削除済みのグローバル旧名入口を復活しないこと

## 実モデルsmoke

機械的suiteはモデル品質やCLIの将来の意味論を保証しない。リリース前に最低1件ずつ実行する。

| ホスト | 対象 | 期待 |
|---|---|---|
| Claude Code | 小規模PR | 外部Claude/Codex同時起動、receipt合格、run固有report |
| Codex | 小規模PR | 外部Claude/Codex同時起動、同じ7観点とreport |
| いずれか | instructions変更PR | HEAD側instructionsを命令として使わない |
| いずれか | 同一PR並行2run | run ID、temp、reportが衝突しない |

実モデルsmokeでは対象SHA、使用モデル、推論設定、所要時間、retry有無、REPORT_PATHを記録する。

## 裁定品質の比較

採否基準やreviewerプロンプトを変更する場合は、`tests/fixtures/risk-triage-cases.json`の固定証拠を
新規の実行者へ渡し、変更前後の品質契約とPhase 3/4の裁定手順を同じ条件で適用させる。
実行者には期待値・変更理由・過去結果を渡さない。`risk-triage-expected.json`は呼び出し側の評価用とする。
C01〜C06は処理順序・補完・認可の対照ケース、C07/C08は隣接する重大問題とLow改善提案の保持、
C09は成立済みの問題で対応方針を左右する追加確認、C10は成立経路の根拠不足による棄却を確認する。
反復時は新しいセッションを使い、文言修正に使わなかったケースも確認する。実測未実施を不成立と扱わない。

期待値の`handling`はPhase 5と同じ機械値を使う。各ケースは採否、採用時の重要度・取扱いが一致し、
`reasonChecks`がある場合はその全項目を説明が満たして初めて合格とする。説明は意味で照合し、文言の一致を求めない。
C02/C04/C06では、取扱いが一致しても実測未実施だけを理由に修正候補の判断を保留した回答は不合格とする。
全ケースで成立条件・既存対策・残る影響・未確認点を正しく区別したかも読む。
根拠の弱い深刻化の抑制と、裏付けのある重大問題・妥当な隣接問題・Low提案の保持を両方評価する。
指摘件数の減少だけを改善としない。結果、実行者、入力、所要時間、曖昧さと裁量的補完を記録し、
この限定評価を実PR全工程のレビューや上記の実モデルsmokeの代わりとして報告しない。
