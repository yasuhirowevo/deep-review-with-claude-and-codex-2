// Test-only renderer: reuses synthetic legacy fixtures, never production reports.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const severities = ["Critical", "High", "Medium", "Low"];
const splitCells = (line) =>
  line
    .trim()
    .slice(1, -1)
    .split(/(?<!\\)\|/u)
    .map((cell) => cell.trim().replaceAll("\\|", "|").replaceAll("`", ""));
const mdCell = (value) => value.replaceAll("|", "\\|");
const count = (items) =>
  severities.map(
    (severity) => items.filter((item) => item.severity === severity).length
  );
const countsCell = (values) =>
  values.map((value, index) => `${"CHML"[index]}${value}`).join(" ") +
  `（計${values.reduce((a, b) => a + b, 0)}）`;
const section = (text, heading, level = 2) => {
  const start = `${"#".repeat(level)} ${heading}\n`;
  const rest = text.slice(text.indexOf(start) + start.length);
  return rest.split(new RegExp(`^#{1,${level}} `, "mu"))[0].trim();
};

export function dialogueFixture(legacy, artifact) {
  const crossSection = section(legacy, "Claude／Codexクロスチェック");
  const cross = crossSection
    .split("\n")
    .filter((line) => /^\| F\d+ \|/u.test(line))
    .map(splitCells);
  const crossById = new Map(cross.map((row) => [row[0], row]));
  const roundBody = section(legacy, "ラウンド別集計");
  const roundCount = roundBody
    .split("\n")
    .filter((line) => /^\| \d+ \|/u.test(line)).length;
  let roundRows;
  if (artifact) {
    const data = [];
    const latest = new Map();
    for (let round = 0; round <= roundCount; round++) {
      const folder = round === 0 ? "phase2" : `phase4/round-${round}`;
      const a = JSON.parse(
        fs.readFileSync(
          path.join(artifact, folder, "adjudication.json"),
          "utf8"
        )
      );
      const evidence = ["claude", "codex"].map(
        (model) =>
          JSON.parse(fs.readFileSync(a.inputs[model].evidencePath, "utf8"))
            .candidates
      );
      data.push(
        `| ${round === 0 ? "初回" : round} | ${[...evidence, a.after.findings]
          .map((items) => countsCell(count(items)))
          .join(" | ")} |`
      );
      for (const decision of a.decisions) {
        if (!["new", "duplicate"].includes(decision.outcome)) continue;
        const model = decision.candidateId.startsWith("claude-") ? 0 : 1;
        latest.set(
          `${decision.findingId}:${model}`,
          evidence[model].find(
            (item) => item.candidateId === decision.candidateId
          ).severity
        );
      }
    }
    roundRows = data;
    for (const row of cross) {
      for (const model of [0, 1])
        row[model + 1] = latest.get(`${row[0]}:${model}`) ?? "未検出";
    }
  } else {
    const values = [1, 2, 3].map((column) =>
      countsCell(count(cross.map((row) => ({ severity: row[column] }))))
    );
    roundRows = Array.from(
      { length: roundCount + 1 },
      (_, round) =>
        `| ${round === 0 ? "初回" : round} | ${values.join(" | ")} |`
    );
  }
  const groups = [];
  const indexRows = [];
  const crossRows = [];
  const ids = new Map();
  severities.forEach((severity) => {
    const match = legacy.match(
      new RegExp(`^### ${severity} \\((\\d+)件\\)$`, "mu")
    );
    let body = section(legacy, `${severity} (${match[1]}件)`, 3);
    body = body.replace(
      /^#### ([CHML]\d+)\. (.+)\n([\s\S]*?)(?=^#### |$(?![\s\S]))/gmu,
      (_full, displayId, heading, block) => {
        const old = heading.match(/^\[(F\d+)\] (.+)$/u);
        const id = old?.[1] ?? block.match(/^\s*- 正典ID: (F\d+)$/mu)?.[1];
        const title = old?.[2] ?? heading;
        const row = crossById.get(id);
        if (!row) throw new Error(`test fixture cross-check missing ${id}`);
        ids.set(id, displayId);
        const verdict = `Claude ${row[1]} / Codex ${row[2]} → 最終 ${row[3]}`;
        block = block.replace(/^\s*- レビュアー判定:.*$/gmu, "");
        if (!block.includes("- **監査**"))
          block += `\n- **監査**\n  - 正典ID: ${id}\n  - 正典題名: ${title}\n`;
        block += `\n  - モデル別重要度: ${verdict}\n  - 最終重要度の理由: ${row[5]}\n`;
        if (severity !== "Low") {
          block = `- 状態: 未確認\n${block}`;
          indexRows.push(
            `| ${displayId} | ${mdCell(title)} | ${row[4]} | 未確認 |`
          );
        }
        crossRows.push(
          `| ${displayId} | ${mdCell(title)} | ${row[1]} | ${row[2]} | ${
            row[3]
          } |`
        );
        return `### ${displayId} — ${title}\n\n${block.trim()}\n\n`;
      }
    );
    groups.push(`## ${severity}（${match[1]}件）\n\n${body}`);
  });
  const excluded = section(legacy, "除外・撤回・降格した候補");
  const excludedRows = excluded
    .split("\n")
    .filter((line) => /^\| X\d+ \|/u.test(line))
    .map(splitCells);
  const overview = severities.map((severity) => {
    const existing = cross.filter((row) => row[3] === severity).length;
    const removed = excludedRows.filter((row) => row[3] === severity).length;
    return `| ${severity} | ${existing + removed} | ${
      severity === "Low" ? "—" : removed
    } |`;
  });
  let decisions = section(legacy, "ユーザーへの確認事項", 3);
  if (decisions === "> 該当なし") decisions = "";
  else
    decisions =
      "### ユーザーへの確認事項\n\n" +
      decisions
        .replace("| Finding ID |", "| ID |")
        .replace(/^\| (F\d+) \|/gmu, (_match, id) => `| ${ids.get(id)} |`);
  const conclusion = section(legacy, "結論")
    .split(/^-[ \t]/mu)[0]
    .trim();
  return (
    [
      legacy.split("\n")[0],
      "## 結論",
      conclusion,
      "## 重要度別の集計",
      "| 重要度 | 検出数 | 判断済 |\n|---|---:|---:|\n" + overview.join("\n"),
      "検出数は除外前の指摘数。判断済はコメントで対応済み・受容済みを確認した件数。",
      "## Medium以上の指摘一覧",
      "| ID | 一言でいうと | 取扱い | 状態 |\n|---|---|---|---|\n" +
        indexRows.join("\n"),
      decisions,
      "## レビューの前提と範囲",
      section(legacy, "レビューの前提と範囲"),
      ...groups,
      "## 指摘として採用しなかった候補",
      excluded
        .replace(
          "### Phase 5で除外したfindings",
          "### 対応済み・受容済みの指摘"
        )
        .replace(
          "### Phase 2〜4で棄却・撤回した候補",
          "### 要対応根拠不十分などで取り下げた候補"
        ),
      "## 未検証事項",
      section(legacy, "未検証事項"),
      "## 監査情報",
      "### クロスチェック結果",
      "| ID | 指摘 | Claude重要度 | Codex重要度 | 最終重要度 |\n|---|---|---|---|---|\n" +
        crossRows.join("\n"),
      "### ラウンド別集計",
      "**重要度別件数**（C=Critical、H=High、M=Medium、L=Low）",
      "| Round | Claude判定（その回の全候補） | Codex判定（その回の全候補） | 統合後（採用累積） |\n|---|---|---|---|\n" +
        roundRows.join("\n"),
      "各モデルは重複・棄却を含むその回の候補、統合後は採用累積であり、残件数ではありません。",
      "**採否と集合変化**",
      roundBody,
      "### 今回の取扱い件数",
      section(legacy, "今回の取扱い件数", 3),
      "### 収束判定",
      section(legacy, "収束判定"),
      "### PRコメント照合結果",
      section(legacy, "PRコメント照合結果"),
      "### 実行証跡",
      section(legacy, "実行証跡"),
      "",
    ]
      .filter((part) => part !== "")
      .join("\n\n") + "\n"
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  fs.writeFileSync(
    process.argv[3],
    dialogueFixture(fs.readFileSync(process.argv[2], "utf8"), process.argv[4])
  );
}
