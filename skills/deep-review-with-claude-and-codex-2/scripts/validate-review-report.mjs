#!/usr/bin/env node

import { existsSync, lstatSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";

import { verifyPromptReceipt } from "./review-prompt-manifest.mjs";
import { assertReviewerAttemptTransition } from "./review-pair-policy.mjs";
import { extractResumeId } from "./review-resume-provenance.mjs";
import { validateOutputEvidenceFile } from "./review-output-evidence.mjs";
import {
  canonicalFindings,
  findingSetSha256,
  validateAdjudicationFile,
} from "./review-adjudication.mjs";
import {
  firstConvergenceEndIndex,
  stableTailLength,
} from "./review-convergence.mjs";
import {
  HANDLING_LABELS,
  RECHALLENGE_EVIDENCE_LABELS,
  validateFinalFindingSetFile,
} from "./review-final-findings.mjs";
import { readPrReviewContextArtifacts } from "./review-pr-context.mjs";
import { inspectReviewWaves } from "./review-wave-state.mjs";
import { toNativeAbsolutePath } from "./path-interop.mjs";

const MAX_REPORT_BYTES = 4 * 1024 * 1024;
const MAX_CONVERGENCE_ROUNDS = 20;
const SEVERITIES = ["Critical", "High", "Medium", "Low"];
const PREFIX = { Critical: "C", High: "H", Medium: "M", Low: "L" };
const HANDLING_LABEL_SET = new Set(Object.values(HANDLING_LABELS));
const REVIEWER_STATES = new Set(["成功", "失敗", "未起動"]);
const GIT_SHA_PATTERN = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/u;
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const TEXT_PLACEHOLDER_PATTERN =
  /(?:^|\s)(?:TBD|TODO|N\/A|PLACEHOLDER|未記入|未設定)(?:$|\s)|^\.{3}$/iu;
const ANGLE_PLACEHOLDER_PATTERN =
  /<(?:[^>\n]*[ぁ-んァ-ン一-龯][^>\n]*|sha(?:-?256)?|uuid|path|line|target|ref|model|value|content|placeholder|[nxyzadrcj])>/iu;
const REQUIRED_SECTIONS = [
  "結論",
  "レビューの前提と範囲",
  "Claude／Codexクロスチェック",
  "Findings",
  "除外・撤回・降格した候補",
  "ラウンド別集計",
  "収束判定",
  "PRコメント照合結果",
  "未検証事項",
  "実行証跡",
];

function fail(message) {
  throw new Error(message);
}

function assertRegularReport(reportPath) {
  const stat = lstatSync(reportPath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) {
    fail("report must be a non-empty regular non-symlink file");
  }
  if (stat.size > MAX_REPORT_BYTES) {
    fail(`report exceeds ${MAX_REPORT_BYTES} bytes`);
  }
}

function sectionBody(lines, heading, nextLevel = 2) {
  const marker = `${"#".repeat(nextLevel)} ${heading}`;
  const start = lines.indexOf(marker);
  if (start < 0) fail(`missing section: ${heading}`);
  let end = lines.length;
  const nextPrefix = `${"#".repeat(nextLevel)} `;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (lines[index].startsWith(nextPrefix)) {
      end = index;
      break;
    }
  }
  return { start, end, lines: lines.slice(start + 1, end) };
}

function requireText(lines, expected, label) {
  if (!lines.some((line) => line.includes(expected))) {
    fail(`missing ${label}: ${expected}`);
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function normalizeMarkdownValue(value) {
  return value.trim().replaceAll("`", "").trim();
}

function assertMeaningfulValue(value, label, options = {}) {
  const normalized = normalizeMarkdownValue(value);
  if (!normalized) fail(`${label} must not be empty`);
  if (
    !options.allowPlaceholder &&
    (TEXT_PLACEHOLDER_PATTERN.test(normalized) ||
      ANGLE_PLACEHOLDER_PATTERN.test(normalized))
  ) {
    fail(`${label} must not contain a placeholder`);
  }
  return normalized;
}

function fieldValue(lines, label, options = {}) {
  const pattern = new RegExp(`^\\s*-\\s+${escapeRegExp(label)}:\\s*(.*)$`, "u");
  const matches = lines
    .map((line) => line.match(pattern))
    .filter((match) => match !== null);
  if (matches.length !== 1) {
    fail(`expected exactly one ${options.kind ?? "field"}: ${label}`);
  }
  return assertMeaningfulValue(matches[0][1], label, options);
}

function tableDataRows(lines) {
  return lines.filter((line) => {
    if (!/^\s*\|.*\|\s*$/u.test(line)) return false;
    if (/^\s*\|\s*[-:]+(?:\s*\|\s*[-:]+)+\s*\|\s*$/u.test(line)) {
      return false;
    }
    return true;
  });
}

function parseTableCells(line) {
  const trimmed = line.trim();
  if (!trimmed.startsWith("|") || !trimmed.endsWith("|")) return [];
  const cells = [];
  let cell = "";
  const body = trimmed.slice(1, -1);
  for (let index = 0; index < body.length; index += 1) {
    if (body[index] === "\\" && body[index + 1] === "|") {
      cell += "|";
      index += 1;
    } else if (body[index] === "|") {
      cells.push(normalizeMarkdownValue(cell));
      cell = "";
    } else {
      cell += body[index];
    }
  }
  cells.push(normalizeMarkdownValue(cell));
  return cells;
}

// Presentation-only adapter. The established artifact, evidence and publication
// checks below still validate the same canonical findings and handling decisions.
function normalizeDialogueLayout(source) {
  if (!source.includes("## 重要度別の集計")) return { lines: source };
  const labels = new Map([
    ["既存の対策で、この問題を防げるか", "確認した防御"],
    ["変更の大きさと必要性", "proportionality"],
    ["修正案を採用した場合の確認方法", "追加検証"],
    ["未確認の内容・理由と判断への影響", "必要な追加確認"],
    ["採用判断と影響範囲", "修正案の影響範囲レビュー"],
    ["モデル別重要度", "レビュアー判定"],
  ]);
  source = source.map((line) =>
    line.replace(/^(\s*-\s+)([^:]+):/u, (match, prefix, label) =>
      labels.has(label) ? `${prefix}${labels.get(label)}:` : match
    )
  );
  const severityHeadings = SEVERITIES.map((severity) => {
    const matches = source.filter((line) =>
      new RegExp(`^## ${severity}[（(]\\d+件[）)]$`, "u").test(line)
    );
    if (matches.length !== 1) fail(`expected one dialogue ${severity} heading`);
    return matches[0].slice(3);
  });
  const expectedHeadings = [
    "結論",
    "重要度別の集計",
    "Medium以上の指摘一覧",
    "レビューの前提と範囲",
    ...severityHeadings,
    "指摘として採用しなかった候補",
    "未検証事項",
    "監査情報",
  ];
  const headings = source
    .filter((line) => line.startsWith("## "))
    .map((line) => line.slice(3));
  if (!isDeepStrictEqual(headings, expectedHeadings))
    fail("dialogue report sections are missing, duplicated or out of order");
  const body = (heading) => sectionBody(source, heading).lines;
  const audit = body("監査情報");
  const auditHeadings = [
    "クロスチェック結果",
    "ラウンド別集計",
    "今回の取扱い件数",
    "収束判定",
    "PRコメント照合結果",
    "実行証跡",
  ];
  if (
    !isDeepStrictEqual(
      audit
        .filter((line) => line.startsWith("### "))
        .map((line) => line.slice(4)),
      auditHeadings
    )
  ) {
    fail("dialogue audit sections are missing, duplicated or out of order");
  }
  const auditBody = (heading) => sectionBody(audit, heading, 3).lines;
  const table = (content, header) => {
    requireText(content, header, "dialogue table header");
    return tableDataRows(content)
      .filter((line) => line.trim() !== header)
      .map(parseTableCells);
  };
  const displayFindings = new Map();
  const finalCounts = new Map();
  const findingLines = [];
  severityHeadings.forEach((heading, index) => {
    const severity = SEVERITIES[index];
    const count = Number(heading.match(/\d+/u)[0]);
    finalCounts.set(severity, count);
    findingLines.push(`### ${severity} (${count}件)`);
    const content = body(heading);
    const starts = content.flatMap((line, offset) => {
      const match = line.match(/^### ([CHML][1-9][0-9]*) — (.+)$/u);
      return match ? [{ offset, displayId: match[1], title: match[2] }] : [];
    });
    starts.forEach((entry, ordinal) => {
      const block = content.slice(
        entry.offset + 1,
        starts[ordinal + 1]?.offset ?? content.length
      );
      if (displayFindings.has(entry.displayId))
        fail("duplicate dialogue finding ID");
      displayFindings.set(entry.displayId, {
        ...entry,
        severity,
        block,
        id: fieldValue(block, "正典ID"),
        handling: fieldValue(block, "今回の取扱い"),
        reason: fieldValue(block, "最終重要度の理由"),
      });
    });
    findingLines.push(
      ...content.map((line) =>
        line.replace(/^### ([CHML]\d+) — /u, "#### $1. ")
      )
    );
  });
  const crossRows = table(
    auditBody("クロスチェック結果"),
    "| ID | 指摘 | Claude重要度 | Codex重要度 | 最終重要度 |"
  );
  const cross = [
    "| Finding ID | Claude重要度 | Codex重要度 | 最終重要度 | 今回の取扱い | 訂正理由 |",
    "|---|---|---|---|---|---|",
  ];
  const seen = new Set();
  const cell = (value) => value.replaceAll("|", "\\|");
  for (const row of crossRows) {
    const finding = displayFindings.get(row[0]);
    if (
      row.length !== 5 ||
      !finding ||
      seen.has(row[0]) ||
      row[1] !== normalizeMarkdownValue(finding.title) ||
      row[4] !== finding.severity
    ) {
      fail(
        "dialogue cross-check must match each finding ID, display title and severity"
      );
    }
    seen.add(row[0]);
    const expected = `Claude ${row[2]} / Codex ${row[3]} → 最終 ${row[4]}`;
    if (fieldValue(finding.block, "レビュアー判定") !== expected)
      fail("dialogue cross-check differs from finding reviewer verdict");
    cross.push(
      `| ${[
        finding.id,
        row[2],
        row[3],
        row[4],
        finding.handling,
        finding.reason,
      ]
        .map(cell)
        .join(" | ")} |`
    );
  }
  if (seen.size !== displayFindings.size)
    fail("dialogue cross-check omits findings");
  const indexContent = body("Medium以上の指摘一覧");
  const separateHeading = "### 別Issue候補（Medium以上）";
  const separateStart = indexContent.indexOf(separateHeading);
  const decisionStart = indexContent.indexOf("### ユーザーへの確認事項");
  const indexHeadings = indexContent.filter((line) => line.startsWith("### "));
  if (
    !isDeepStrictEqual(indexHeadings, [
      separateHeading,
      ...(decisionStart < 0 ? [] : ["### ユーザーへの確認事項"]),
    ])
  ) fail("dialogue finding index partitions are missing, duplicated or out of order");
  const indexTable = (content) => {
    const header = "| ID | 一言でいうと | 取扱い | 状態 |";
    const rows = content.some((line) => line.trim() === header)
      ? table(content, header)
      : [];
    if (rows.length === 0 && !content.includes("> 該当なし"))
      fail("empty dialogue finding index partition requires an explicit marker");
    if (
      rows.length === 0 &&
      tableDataRows(content).some((line) => line.trim() !== header)
    )
      fail("dialogue finding index partition has an invalid table");
    return rows;
  };
  const indexPartitions = [
    indexTable(indexContent.slice(0, separateStart)),
    indexTable(indexContent.slice(
      separateStart + 1,
      decisionStart < 0 ? undefined : decisionStart
    )),
  ];
  const indexed = new Set();
  const states = new Set([
    "未確認",
    "未着手",
    "対応中",
    "対応済み・未push",
    "対応済み・push済み",
    "—",
  ]);
  for (const [partition, indexRows] of indexPartitions.entries()) {
    for (const row of indexRows) {
      const finding = displayFindings.get(row[0]);
      if (
        row.length !== 4 ||
        !finding ||
        finding.severity === "Low" ||
        indexed.has(row[0]) ||
        row[1] !== normalizeMarkdownValue(finding.title) ||
        row[2] !== finding.handling ||
        (finding.handling === HANDLING_LABELS["separate-issue"]) !== (partition === 1) ||
        !states.has(row[3]) ||
        row[3] !== fieldValue(finding.block, "状態")
      ) {
        fail("dialogue finding index does not match the finding details");
      }
      if (!["未確認", "—"].includes(row[3]))
        fieldValue(finding.block, "状態の根拠");
      indexed.add(row[0]);
    }
  }
  if (
    indexed.size !==
    [...displayFindings.values()].filter(
      (finding) => finding.severity !== "Low"
    ).length
  ) {
    fail("dialogue finding index omits Medium or higher findings");
  }
  const decisions =
    decisionStart < 0
      ? ["> 該当なし"]
      : indexContent.slice(decisionStart + 1).map((line) => {
          if (line.trim() === "| ID | 確認事項 | 選択による影響 |")
            return "| Finding ID | 確認事項 | 選択による影響 |";
          if (!line.trim().startsWith("|")) return line;
          const cells = parseTableCells(line);
          const finding = displayFindings.get(cells[0]);
          if (!finding) return line;
          cells[0] = finding.id;
          return `| ${cells.map(cell).join(" | ")} |`;
        });
  const handling = auditBody("今回の取扱い件数");
  const handlingCounts = parseHandlingCounts(handling);
  const rounds = auditBody("ラウンド別集計");
  const roundSplit = rounds.indexOf("**採否と集合変化**");
  if (roundSplit < 0) fail("missing dialogue round adoption table label");
  const roundSeverityRows = table(
    rounds.slice(0, roundSplit),
    "| Round | Claude判定（その回の全候補） | Codex判定（その回の全候補） | 統合後（採用累積） |"
  );
  const overviewRows = table(
    body("重要度別の集計"),
    "| 重要度 | 検出数 | 判断済 | 本PRの最終指摘 | 別Issue候補 |"
  );
  const excluded = body("指摘として採用しなかった候補").map((line) =>
    line
      .replace("### 対応済み・受容済みの指摘", "### Phase 5で除外したfindings")
      .replace(
        "### 要対応根拠不十分などで取り下げた候補",
        "### Phase 2〜4で棄却・撤回した候補"
      )
  );
  const normalized = [
    source[0],
    "## 結論",
    ...body("結論"),
    ...[...handlingCounts].map(([label, count]) => `- ${label}: ${count}件`),
    "### ユーザーへの確認事項",
    ...decisions,
    "## レビューの前提と範囲",
    ...body("レビューの前提と範囲"),
    "## Claude／Codexクロスチェック",
    ...cross,
    "### 最終重要度件数",
    "| 重要度 | 件数 | 意味 |",
    "|---|---:|---|",
    ...SEVERITIES.map(
      (severity) =>
        `| ${severity} | ${finalCounts.get(severity)} | 問題の重要度 |`
    ),
    "### 今回の取扱い件数",
    ...handling,
    "## Findings",
    ...findingLines,
    "## 除外・撤回・降格した候補",
    ...excluded,
    "## ラウンド別集計",
    ...rounds.slice(roundSplit + 1),
    "## 収束判定",
    ...auditBody("収束判定"),
    "## PRコメント照合結果",
    ...auditBody("PRコメント照合結果"),
    "## 未検証事項",
    ...body("未検証事項"),
    "## 実行証跡",
    ...auditBody("実行証跡"),
  ];
  return {
    lines: normalized,
    overviewRows,
    roundSeverityRows,
    displayFindings,
    crossRows,
    indexPartitions,
  };
}

function validateDialogueAccounting(
  layout,
  findings,
  exclusions,
  primary,
  rounds,
  finalFindingSet,
  reportTreatments
) {
  if (!layout.overviewRows) return;
  if (layout.overviewRows.length !== 4)
    fail("dialogue overview requires all four severities");
  const finalFindings = finalFindingSet?.final.findings ?? findings;
  const separateIds = new Set(
    finalFindingSet
      ? finalFindingSet.decisions
        .filter((decision) => decision.handling === "separate-issue")
        .map((decision) => decision.findingId)
      : [...reportTreatments]
        .filter(([, treatment]) => treatment.handling === HANDLING_LABELS["separate-issue"])
        .map(([id]) => id)
  );
  const partitions = [false, true].map((separate) =>
    finalFindings.filter((finding) => separateIds.has(finding.id) === separate)
  );
  partitions.forEach((partition, index) => {
    const expectedIds = partition.filter((finding) => finding.severity !== "Low")
      .map((finding) => finding.id).sort();
    const actualIds = layout.indexPartitions[index]
      .map((row) => layout.displayFindings.get(row[0]).id).sort();
    if (!isDeepStrictEqual(actualIds, expectedIds))
      fail("dialogue finding index partition differs from final findings");
  });
  SEVERITIES.forEach((severity, index) => {
    const excluded = exclusions.filter(
      (finding) => finding.severity === severity
    ).length;
    const count =
      findings.filter((finding) => finding.severity === severity).length +
      excluded;
    const expected = [
      severity,
      String(count),
      severity === "Low" ? "—" : String(excluded),
      ...partitions.map((partition) => String(
        partition.filter((finding) => finding.severity === severity).length
      )),
    ];
    if (!isDeepStrictEqual(layout.overviewRows[index], expected))
      fail(`dialogue overview count mismatch: ${severity}`);
  });
  const countSeverities = (items) =>
    SEVERITIES.map(
      (severity) => items.filter((item) => item.severity === severity).length
    );
  if (layout.roundSeverityRows.length !== rounds.length + 1)
    fail(
      "dialogue severity table must include primary and every canonical round"
    );
  const crossVerdicts = new Map();
  [primary, ...rounds].forEach((adjudication, index) => {
    const row = layout.roundSeverityRows[index];
    if (row.length !== 4 || row[0] !== (index === 0 ? "初回" : String(index)))
      fail("dialogue severity round numbering is invalid");
    const counts = row.slice(1).map((value) => {
      const match = value.match(/^C(\d+) H(\d+) M(\d+) L(\d+)（計(\d+)）$/u);
      if (!match)
        fail("dialogue severity counts need C/H/M/L labels and a total");
      const values = match.slice(1, 5).map(Number);
      if (values.reduce((sum, item) => sum + item, 0) !== Number(match[5]))
        fail("dialogue severity total does not match its counts");
      return values;
    });
    if (!adjudication?.inputs) return; // Standalone validation has no raw artifacts.
    const evidence = ["claude", "codex"].map((model, column) => {
      // These evidence files and hashes were validated with the adjudication chain.
      const data = readJsonFile(
        toNativeAbsolutePath(adjudication.inputs[model].evidencePath),
        "reviewer evidence"
      );
      if (!isDeepStrictEqual(counts[column], countSeverities(data.candidates)))
        fail(
          `dialogue ${row[0]} ${model} counts differ from reviewer evidence`
        );
      return data.candidates;
    });
    if (
      !isDeepStrictEqual(
        counts[2],
        countSeverities(adjudication.after.findings)
      )
    )
      fail(`dialogue ${row[0]} integrated counts differ from adjudication`);
    for (const decision of adjudication.decisions) {
      if (!["new", "duplicate"].includes(decision.outcome)) continue;
      const column = decision.candidateId.startsWith("claude-") ? 0 : 1;
      const candidate = evidence[column].find(
        (item) => item.candidateId === decision.candidateId
      );
      crossVerdicts.set(`${decision.findingId}:${column}`, candidate.severity);
    }
  });
  if (primary) {
    for (const row of layout.crossRows) {
      const finding = layout.displayFindings.get(row[0]);
      for (const column of [0, 1]) {
        if (
          row[column + 2] !==
          (crossVerdicts.get(`${finding.id}:${column}`) ?? "未検出")
        )
          fail(
            `dialogue cross-check differs from reviewer evidence: ${row[0]}`
          );
      }
    }
  }
}

function validateRequiredSections(lines) {
  let previous = -1;
  for (const heading of REQUIRED_SECTIONS) {
    const index = lines.indexOf(`## ${heading}`);
    if (index < 0) fail(`missing required section: ${heading}`);
    if (index <= previous) fail(`section order is invalid at: ${heading}`);
    previous = index;
  }
}

function validateReviewScope(lines) {
  const body = sectionBody(lines, "レビューの前提と範囲").lines;
  for (const label of [
    "レビュー目的",
    "このPRの対象",
    "このPRの非対象",
    "プロジェクトの性質・利用者",
    "現実的な攻撃者・誤操作・障害",
    "データの機密性・完全性",
    "防御・検知・復旧",
    "不明点・保守的仮定",
    "前回からの変更",
  ]) {
    fieldValue(body, label, { kind: "review scope field" });
  }
}

function validateConclusionHandlingSummary(lines, handlingCounts) {
  const body = sectionBody(lines, "結論").lines;
  for (const label of HANDLING_LABEL_SET) {
    const value = fieldValue(body, label, {
      kind: "conclusion handling summary",
    });
    const match = value.match(/^(\d+)件$/u);
    if (!match || Number(match[1]) !== handlingCounts.get(label)) {
      fail(`conclusion handling count does not match: ${label}`);
    }
  }
}

function validateUserDecisionSummary(lines, reportTreatments) {
  const body = sectionBody(lines, "結論").lines;
  const heading = body.indexOf("### ユーザーへの確認事項");
  if (heading < 0) fail("missing user decision summary heading");
  const content = body.slice(heading + 1).filter((line) => line.trim() !== "");
  const expected = [...reportTreatments.entries()].filter(
    ([, treatment]) => treatment.handling === "ユーザー判断が必要",
  );
  if (expected.length === 0) {
    if (content.length !== 1 || content[0].trim() !== "> 該当なし") {
      fail("empty user decision summary must use the explicit empty marker");
    }
    return;
  }
  requireText(
    content,
    "| Finding ID | 確認事項 | 選択による影響 |",
    "user decision summary table header",
  );
  const rows = tableDataRows(content)
    .map(parseTableCells)
    .filter((cells) => cells[0] !== "Finding ID");
  if (rows.length !== expected.length) {
    fail("user decision summary count does not match the findings");
  }
  const rowsById = new Map();
  for (const cells of rows) {
    if (cells.length !== 3 || rowsById.has(cells[0])) {
      fail("user decision summary contains an invalid or duplicate row");
    }
    rowsById.set(cells[0], cells);
  }
  expected.forEach(([findingId, treatment]) => {
    const cells = rowsById.get(findingId);
    if (
      !cells ||
      cells[1] !== normalizeMarkdownValue(treatment.userDecisionRequest) ||
      cells[2] !== normalizeMarkdownValue(treatment.userDecisionImpact)
    ) {
      fail(`user decision summary does not match finding: ${findingId}`);
    }
  });
}

function parseHandlingCounts(lines) {
  const counts = new Map();
  for (const line of lines) {
    const cells = parseTableCells(line);
    if (
      cells.length !== 3 ||
      !HANDLING_LABEL_SET.has(cells[0]) ||
      !/^\d+$/u.test(cells[1])
    ) {
      continue;
    }
    if (counts.has(cells[0])) {
      fail(`duplicate handling count row: ${cells[0]}`);
    }
    assertMeaningfulValue(cells[2], `handling meaning: ${cells[0]}`);
    counts.set(cells[0], Number(cells[1]));
  }
  for (const label of HANDLING_LABEL_SET) {
    if (!counts.has(label)) fail(`missing handling count row: ${label}`);
  }
  return counts;
}

function validateCrossCheck(
  lines,
  tableCounts,
  reportFindings,
  reportTreatments,
  handlingCounts,
) {
  const body = sectionBody(lines, "Claude／Codexクロスチェック").lines;
  const countHeading = body.indexOf("### 最終重要度件数");
  if (countHeading < 0) fail("missing final severity count heading");
  const crossLines = body.slice(0, countHeading);
  requireText(
    crossLines,
    "| Finding ID | Claude重要度 | Codex重要度 | 最終重要度 | 今回の取扱い | 訂正理由 |",
    "cross-check table header",
  );
  const rows = tableDataRows(crossLines)
    .filter((line) => !line.includes("Finding ID"))
    .map(parseTableCells);
  const expectedTotal = SEVERITIES.reduce(
    (total, severity) => total + tableCounts.get(severity),
    0,
  );
  if (rows.length !== expectedTotal) {
    fail(
      `cross-check row count mismatch: expected ${expectedTotal}, got ${rows.length}`,
    );
  }
  const finalDistribution = new Map(
    SEVERITIES.map((severity) => [severity, 0]),
  );
  const reportById = new Map(
    reportFindings.map((finding) => [finding.id, finding]),
  );
  const crossChecked = new Set();
  const reviewerSeverities = new Set([...SEVERITIES, "未検出"]);
  rows.forEach((cells) => {
    if (cells.length !== 6) fail("cross-check row must contain six columns");
    if (!reportById.has(cells[0]) || crossChecked.has(cells[0])) {
      fail("cross-check finding ID does not match the report findings");
    }
    crossChecked.add(cells[0]);
    if (
      !reviewerSeverities.has(cells[1]) ||
      !reviewerSeverities.has(cells[2])
    ) {
      fail("cross-check reviewer severity is invalid");
    }
    if (!SEVERITIES.includes(cells[3])) {
      fail("cross-check final severity is invalid");
    }
    if (reportById.get(cells[0]).severity !== cells[3]) {
      fail("cross-check final severity does not match its report finding");
    }
    if (
      !HANDLING_LABEL_SET.has(cells[4]) ||
      reportTreatments.get(cells[0])?.handling !== cells[4]
    ) {
      fail("cross-check handling does not match its report finding");
    }
    assertMeaningfulValue(cells[5], "cross-check correction reason");
    finalDistribution.set(cells[3], finalDistribution.get(cells[3]) + 1);
  });
  if (crossChecked.size !== reportById.size) {
    fail("cross-check findings do not match the report finding set");
  }
  for (const severity of SEVERITIES) {
    if (finalDistribution.get(severity) !== tableCounts.get(severity)) {
      fail(
        `cross-check ${severity} distribution does not match severity counts`,
      );
    }
  }
  for (const [label, count] of handlingCounts) {
    const visible = [...reportTreatments.values()].filter(
      (treatment) => treatment.handling === label,
    ).length;
    if (visible > count) {
      fail(`visible handling count exceeds total handling count: ${label}`);
    }
  }
}

function parseSeverityCounts(countLines) {
  const counts = new Map();
  for (const line of countLines) {
    const match = line.match(
      /^\s*\|\s*(Critical|High|Medium|Low)\s*\|\s*(\d+)\s*\|/u,
    );
    if (!match) continue;
    if (counts.has(match[1])) fail(`duplicate severity count row: ${match[1]}`);
    counts.set(match[1], Number(match[2]));
  }
  for (const severity of SEVERITIES) {
    if (!counts.has(severity)) fail(`missing severity count row: ${severity}`);
  }
  return counts;
}

function validateFindingBlock(block, severity) {
  const required = [
    "今回の取扱い",
    "取扱いの根拠",
    "目的との関係",
    "既存成功記録との照合",
    "既存判断との照合",
    "場所",
    "成立条件",
    "影響",
    "問題の根拠",
    "コードパス",
    "確認した防御",
    "検出",
    "修正案",
  ];
  if (severity !== "Low") {
    required.push(
      "レビュアー判定",
      "修正案の裏付け",
      "修正案の評価",
      "既存呼び出し元への影響",
      "テストへの影響",
      "デグレ確認",
      "proportionality",
      "追加検証",
    );
    if (!block.some((line) => line.trim() === "- 修正案の影響範囲レビュー:")) {
      fail(`${severity} finding is missing the fix impact review container`);
    }
  }
  const values = new Map(
    required.map((field) => [
      field,
      fieldValue(block, field, { kind: `${severity} field` }),
    ]),
  );
  if (severity !== "Low") {
    const status = values.get("修正案の評価");
    if (
      !new Set(["推奨修正案", "条件付き修正案", "非推奨案", "要設計判断"]).has(
        status,
      )
    ) {
      fail(`${severity} finding has an invalid fix-proposal evaluation`);
    }
  }
  const handling = values.get("今回の取扱い");
  if (!HANDLING_LABEL_SET.has(handling)) {
    fail(`${severity} finding has an invalid handling`);
  }
  const userDecisionRequest =
    handling === "ユーザー判断が必要"
      ? fieldValue(block, "ユーザーへの確認事項", {
          kind: `${severity} field`,
        })
      : null;
  const userDecisionImpact =
    handling === "ユーザー判断が必要"
      ? fieldValue(block, "選択による影響", {
          kind: `${severity} field`,
        })
      : null;
  const verificationRequest =
    handling === "追加確認が必要"
      ? fieldValue(block, "必要な追加確認", {
          kind: `${severity} field`,
        })
      : null;
  for (const [label, allowed] of [
    ["ユーザーへの確認事項", handling === "ユーザー判断が必要"],
    ["選択による影響", handling === "ユーザー判断が必要"],
    ["必要な追加確認", handling === "追加確認が必要"],
  ]) {
    if (
      !allowed &&
      block.some((line) =>
        new RegExp(`^\\s*-\\s+${escapeRegExp(label)}:`, "u").test(line),
      )
    ) {
      fail(`${severity} finding contains ${label} for an unrelated handling`);
    }
  }
  const priorDecisionComparison = values.get("既存判断との照合");
  if (
    priorDecisionComparison.startsWith("再提起:") &&
    !Object.values(RECHALLENGE_EVIDENCE_LABELS).some((label) =>
      priorDecisionComparison.startsWith(`再提起: ${label} — `),
    )
  ) {
    fail(`${severity} finding has an invalid rechallenge evidence label`);
  }
  return {
    handling,
    handlingRationale: values.get("取扱いの根拠"),
    userDecisionRequest,
    userDecisionImpact,
    verificationRequest,
    priorDecisionComparison,
  };
}

function validateFindings(lines, tableCounts) {
  const findings = sectionBody(lines, "Findings");
  const headingCounts = new Map();
  const actualCounts = new Map();
  const reportFindings = [];
  const reportTreatments = new Map();
  for (const severity of SEVERITIES) {
    const headingPattern = new RegExp(`^### ${severity} \\((\\d+)件\\)$`, "u");
    const matches = [];
    for (let index = findings.start + 1; index < findings.end; index += 1) {
      const match = lines[index].match(headingPattern);
      if (match) matches.push({ index, count: Number(match[1]) });
    }
    if (matches.length !== 1) fail(`expected one ${severity} count heading`);
    headingCounts.set(severity, matches[0].count);

    let end = findings.end;
    for (let index = matches[0].index + 1; index < findings.end; index += 1) {
      if (/^### (Critical|High|Medium|Low) \(\d+件\)$/u.test(lines[index])) {
        end = index;
        break;
      }
    }
    const sectionLines = lines.slice(matches[0].index + 1, end);
    const prefix = PREFIX[severity];
    const findingIndexes = [];
    for (let index = 0; index < sectionLines.length; index += 1) {
      const legacyMatch = sectionLines[index].match(
        new RegExp(`^#### ${prefix}(\\d+)\\.\\s+\\[(F[1-9][0-9]*)\\]\\s+(.+)$`, "u"),
      );
      const match = legacyMatch ?? sectionLines[index].match(
        new RegExp(`^#### ${prefix}(\\d+)\\.\\s+(.+)$`, "u"),
      );
      if (match) {
        const title = (legacyMatch ? match[3] : match[2]).trim();
        assertMeaningfulValue(title, `${severity} finding title`);
        findingIndexes.push({
          index,
          number: Number(match[1]),
          id: legacyMatch ? match[2] : null,
          title,
        });
      }
    }
    actualCounts.set(severity, findingIndexes.length);
    findingIndexes.forEach((finding, ordinal) => {
      if (finding.number !== ordinal + 1) {
        fail(`${severity} finding numbering is not contiguous`);
      }
      const next = findingIndexes[ordinal + 1]?.index ?? sectionLines.length;
      const block = sectionLines.slice(finding.index + 1, next);
      if (finding.id === null) {
        const auditMarkers = block.flatMap((line, index) =>
          line.trim() === "- **監査**" ? [index] : [],
        );
        if (auditMarkers.length !== 1) fail("expected exactly one finding audit block");
        const audit = block.slice(auditMarkers[0] + 1);
        finding.id = fieldValue(audit, "正典ID");
        if (!/^F[1-9][0-9]*$/u.test(finding.id)) fail("invalid canonical finding ID");
        const canonicalTitles = audit
          .map((line) => line.match(/^\s*-\s+正典題名:\s*(.*)$/u))
          .filter(Boolean);
        if (canonicalTitles.length !== 1) fail("expected exactly one canonical finding title");
        finding.title = canonicalTitles[0][1].trim();
        assertMeaningfulValue(finding.title, `${severity} canonical finding title`);
      }
      const treatment = validateFindingBlock(block, severity);
      reportTreatments.set(finding.id, treatment);
      reportFindings.push({
        id: finding.id,
        severity,
        title: finding.title,
      });
    });
    if (findingIndexes.length === 0) {
      requireText(sectionLines, "> 該当なし", `${severity} empty marker`);
    } else if (sectionLines.some((line) => line.trim() === "> 該当なし")) {
      fail(`${severity} contains findings and an empty marker`);
    }
  }

  for (const severity of SEVERITIES) {
    const table = tableCounts.get(severity);
    const heading = headingCounts.get(severity);
    const actual = actualCounts.get(severity);
    if (table !== heading || heading !== actual) {
      fail(
        `${severity} count mismatch: table=${table} heading=${heading} actual=${actual}`,
      );
    }
  }
  return {
    findings: canonicalFindings(reportFindings, "report finding set"),
    treatments: reportTreatments,
  };
}

function validateExcludedCandidates(lines) {
  const body = sectionBody(lines, "除外・撤回・降格した候補").lines;
  const phase5Heading = body.indexOf("### Phase 5で除外したfindings");
  const earlierHeading = body.indexOf("### Phase 2〜4で棄却・撤回した候補");
  if (
    phase5Heading < 0 ||
    earlierHeading < 0 ||
    earlierHeading <= phase5Heading
  ) {
    fail("excluded candidates subsections are missing or out of order");
  }
  const content = body
    .slice(phase5Heading + 1, earlierHeading)
    .filter((line) => line.trim() !== "");
  if (content.length === 0) {
    fail("excluded candidates section must use an explicit empty marker");
  }
  let phase5Rows;
  if (content.some((line) => line.trim() === "> 該当なし")) {
    if (content.length !== 1) {
      fail("excluded candidates empty marker must be the only content");
    }
    phase5Rows = [];
  } else {
    requireText(
      content,
      "| # | Finding ID | 候補 | 元重要度 | 今回の取扱い | 理由・根拠 |",
      "excluded candidates table header",
    );
    const rows = tableDataRows(content)
      .map(parseTableCells)
      .filter((cells) => cells[0] !== "#");
    if (rows.length === 0) {
      fail("excluded candidates table must contain at least one candidate");
    }
    phase5Rows = rows.map((cells, index) => {
      if (cells.length !== 6) {
        fail("excluded candidate row must contain six columns");
      }
      if (cells[0] !== `X${index + 1}`) {
        fail("excluded candidate IDs must be contiguous");
      }
      for (const [column, label] of [
        [1, "finding ID"],
        [2, "candidate"],
        [3, "original severity"],
        [4, "handling"],
        [5, "reason"],
      ]) {
        assertMeaningfulValue(cells[column], `excluded candidate ${label}`);
      }
      if (!/^F[1-9][0-9]*$/u.test(cells[1])) {
        fail("excluded candidate must use a stable Finding ID");
      }
      if (!SEVERITIES.includes(cells[3])) {
        fail("excluded candidate must use a valid original severity");
      }
      if (!HANDLING_LABEL_SET.has(cells[4])) {
        fail("excluded candidate must use a valid handling");
      }
      return {
        findingId: cells[1],
        title: cells[2],
        severity: cells[3],
        handling: cells[4],
        handlingRationale: cells[5],
      };
    });
  }

  const earlierContent = body
    .slice(earlierHeading + 1)
    .filter((line) => line.trim() !== "");
  if (earlierContent.length === 0) {
    fail("earlier rejected candidates must use an explicit empty marker");
  }
  let earlierRows;
  if (earlierContent.some((line) => line.trim() === "> 該当なし")) {
    if (earlierContent.length !== 1) {
      fail("earlier rejected candidates empty marker must be the only content");
    }
    earlierRows = [];
  } else {
    requireText(
      earlierContent,
      "| 段階 | ID | 判定 | 理由 |",
      "earlier rejected candidates table header",
    );
    const rows = tableDataRows(earlierContent)
      .map(parseTableCells)
      .filter((cells) => cells[0] !== "段階");
    if (rows.length === 0) {
      fail("earlier rejected candidates table must contain at least one row");
    }
    earlierRows = rows.map((cells) => {
      if (
        cells.length !== 4 ||
        !/^(?:Phase 2|round [1-9][0-9]*)$/u.test(cells[0]) ||
        !new Set(["棄却", "撤回"]).has(cells[2])
      ) {
        fail("earlier rejected candidate row is invalid");
      }
      assertMeaningfulValue(cells[1], "earlier rejected candidate ID");
      assertMeaningfulValue(cells[3], "earlier rejected candidate rationale");
      return {
        scope: cells[0],
        id: cells[1],
        outcome: cells[2],
        rationale: cells[3],
      };
    });
  }
  return { phase5Rows, earlierRows };
}

function reviewerState(canonical) {
  if (!canonical || canonical.launched === false) return "未起動";
  return canonical.exitCode === 0 ? "成功" : "失敗";
}

function assertDirectory(directoryPath, label) {
  let stat;
  try {
    stat = lstatSync(directoryPath);
  } catch {
    fail(`${label} is unavailable`);
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fail(`${label} must be a non-symlink directory`);
  }
}

function assertRegularFile(filePath, label, requireNonEmpty = false) {
  let stat;
  try {
    stat = lstatSync(filePath);
  } catch {
    fail(`${label} is unavailable`);
  }
  if (
    stat.isSymbolicLink() ||
    !stat.isFile() ||
    (requireNonEmpty && stat.size === 0)
  ) {
    fail(
      `${label} must be a ${requireNonEmpty ? "non-empty " : ""}regular non-symlink file`,
    );
  }
}

function readJsonFile(filePath, label) {
  assertRegularFile(filePath, label, true);
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    fail(`${label} is invalid JSON`);
  }
}

function numberedDirectories(parentPath, prefix, label) {
  assertDirectory(parentPath, label);
  const pattern = new RegExp(`^${escapeRegExp(prefix)}([1-9][0-9]*)$`, "u");
  const numbers = [];
  for (const entry of readdirSync(parentPath, { withFileTypes: true })) {
    if (!entry.name.startsWith(prefix)) continue;
    const match = entry.name.match(pattern);
    if (!match || entry.isSymbolicLink() || !entry.isDirectory()) {
      fail(`${label} contains an invalid ${prefix} directory: ${entry.name}`);
    }
    numbers.push(Number(match[1]));
  }
  return numbers.sort((left, right) => left - right);
}

function phaseStatusDirectory(artifactDirectory, phase, round) {
  if (phase === "primary") {
    const phase2 = path.join(artifactDirectory, "phase2");
    assertDirectory(phase2, "Phase 2 status directory");
    return phase2;
  }
  const phase4 = path.join(artifactDirectory, "phase4");
  assertDirectory(phase4, "Phase 4 status directory");
  const roundDirectory = path.join(phase4, `round-${round}`);
  assertDirectory(roundDirectory, `round ${round} status directory`);
  return roundDirectory;
}

function validateAttemptReviewer(
  record,
  reviewer,
  attemptNumber,
  attemptDirectory,
  context,
  phase,
  round,
) {
  if (
    !record ||
    typeof record.requested !== "boolean" ||
    typeof record.launched !== "boolean"
  ) {
    fail(`attempt ${reviewer} state is invalid`);
  }
  if (!record.requested) {
    if (
      record.launched !== false ||
      record.exitCode !== null ||
      record.execution !== null ||
      record.resumeId !== null ||
      record.resumedFromAttempt !== null ||
      record.prompt !== null ||
      record.evidence !== null ||
      record.stdout !== null ||
      record.stderr !== null
    ) {
      fail(`unrequested ${reviewer} attempt contains execution evidence`);
    }
    return;
  }
  if (
    !Number.isInteger(record.exitCode) ||
    !new Set(["initial", "retry", "resume"]).has(record.execution) ||
    (attemptNumber === 1) !== (record.execution === "initial") ||
    (!record.launched && record.exitCode === 0) ||
    (record.execution === "resume"
      ? typeof record.resumeId !== "string" || record.resumeId.length === 0
      : record.resumeId !== null) ||
    (record.execution === "resume"
      ? !Number.isInteger(record.resumedFromAttempt) ||
        record.resumedFromAttempt < 1 ||
        record.resumedFromAttempt >= attemptNumber
      : record.resumedFromAttempt !== null) ||
    typeof record.stdout !== "string" ||
    record.stdout.length === 0 ||
    typeof record.stderr !== "string" ||
    record.stderr.length === 0
  ) {
    fail(`requested ${reviewer} attempt metadata is invalid`);
  }
  try {
    verifyPromptReceipt(record.prompt, {
      context,
      reviewer,
      phase,
      round,
      purpose: record.execution === "resume" ? "resume" : "review",
    });
  } catch (error) {
    fail(`${reviewer} attempt prompt provenance is invalid: ${error.message}`);
  }
  const expectedStdout = path.join(attemptDirectory, `${reviewer}.out`);
  const expectedStderr = path.join(attemptDirectory, `${reviewer}.err`);
  if (
    normalizePortablePath(record.stdout) !==
      normalizePortablePath(expectedStdout) ||
    normalizePortablePath(record.stderr) !==
      normalizePortablePath(expectedStderr)
  ) {
    fail(`${reviewer} attempt output paths do not match the attempt directory`);
  }
  if (record.launched) {
    assertRegularFile(expectedStdout, `${reviewer} attempt stdout`);
    assertRegularFile(expectedStderr, `${reviewer} attempt stderr`);
  }
  if (record.exitCode === 0) {
    const expectedEvidence = path.join(
      attemptDirectory,
      `${reviewer}.evidence.json`,
    );
    if (
      !record.evidence ||
      normalizePortablePath(record.evidence.path) !==
        normalizePortablePath(expectedEvidence)
    ) {
      fail(`${reviewer} successful attempt is missing output evidence`);
    }
    try {
      validateOutputEvidenceFile({
        evidencePath: expectedEvidence,
        outputPath: expectedStdout,
        reviewer,
        phase,
        round,
        attempt: attemptNumber,
        receipt: record.evidence,
      });
    } catch (error) {
      fail(`${reviewer} attempt output evidence is invalid: ${error.message}`);
    }
  } else if (record.evidence !== null) {
    fail(`${reviewer} failed attempt must not claim output evidence`);
  }
}

function validateResumeSource(
  status,
  reviewer,
  resumeAttempt,
  statusDirectory,
  label,
) {
  const resumeRecord = resumeAttempt[reviewer];
  if (resumeRecord.execution !== "resume") return;
  const priorReviewerAttempts = status.attempts.filter(
    (attempt) =>
      attempt.attempt < resumeAttempt.attempt && attempt[reviewer].requested,
  );
  const sourceAttempt = priorReviewerAttempts.at(-1);
  const sourceRecord = sourceAttempt?.[reviewer];
  if (
    !sourceAttempt ||
    resumeRecord.resumedFromAttempt !== sourceAttempt.attempt ||
    sourceRecord.launched !== true ||
    !Number.isInteger(sourceRecord.exitCode) ||
    sourceRecord.exitCode === 0
  ) {
    fail(`${label} ${reviewer} resume source attempt is invalid`);
  }
  try {
    assertReviewerAttemptTransition(
      sourceRecord.exitCode,
      resumeRecord.execution,
      `${label} ${reviewer}`,
    );
  } catch (error) {
    fail(error.message);
  }
  const sourceOutput = path.join(
    statusDirectory,
    `attempt-${sourceAttempt.attempt}`,
    `${reviewer}.out`,
  );
  if (
    normalizePortablePath(sourceRecord.stdout) !==
    normalizePortablePath(sourceOutput)
  ) {
    fail(`${label} ${reviewer} resume source output path is invalid`);
  }
  let sourceId;
  try {
    sourceId = extractResumeId(sourceOutput, reviewer);
  } catch (error) {
    fail(`${label} ${reviewer} resume source ID is invalid: ${error.message}`);
  }
  if (sourceId !== resumeRecord.resumeId) {
    fail(`${label} ${reviewer} resume ID does not match its source attempt`);
  }
}

function canonicalAttempt(attempts, reviewer) {
  const runs = attempts
    .filter((attempt) => attempt[reviewer].requested)
    .map((attempt) => ({
      ...attempt[reviewer],
      attempt: attempt.attempt,
      interrupted: attempt.interrupted,
    }));
  if (runs.length === 0) return null;
  return runs.filter((run) => run.exitCode === 0).at(-1) ?? runs.at(-1);
}

function validateAttestedOutput(outputPath, context, label) {
  assertRegularFile(outputPath, label, true);
  const lines = readFileSync(outputPath, "utf8").split(/\r?\n/u);
  const expected = [
    `RUN_ID: ${context.reviewRunId}`,
    "INPUT_ATTESTATION: verified",
    `TARGET: ${context.target}`,
    `HEAD_SHA: ${context.headSha}`,
    `DIFF_SHA256: ${context.diffSha256}`,
    `SNAPSHOT_METADATA_SHA256: ${context.snapshotMetadataSha256}`,
  ];
  const separator = lines.indexOf("---");
  const header = separator < 0 ? [] : lines.slice(0, separator);
  if (
    separator < expected.length ||
    !isDeepStrictEqual(header.slice(-expected.length), expected) ||
    header.filter((line) => expected.includes(line)).length !== expected.length
  ) {
    fail(`${label} has an invalid attestation header`);
  }
}

function validatePairStatusDirectory(
  statusDirectory,
  context,
  phase,
  round,
  label,
) {
  assertDirectory(statusDirectory, `${label} directory`);
  const status = readJsonFile(path.join(statusDirectory, "status.json"), label);
  if (
    status.schema !== "deep-review-pair/v6" ||
    status.reviewRunId !== context.reviewRunId ||
    !isDeepStrictEqual(status.expectedReviewers, ["claude", "codex"]) ||
    status.phase !== phase ||
    status.round !== round ||
    !Array.isArray(status.attempts) ||
    status.attempts.length === 0
  ) {
    fail(`${label} is incompatible with the review context`);
  }
  const actualAttempts = numberedDirectories(
    statusDirectory,
    "attempt-",
    `${label} directory`,
  );
  const expectedAttempts = status.attempts.map((attempt) => attempt?.attempt);
  if (
    expectedAttempts.some(
      (attempt, index) => !Number.isInteger(attempt) || attempt !== index + 1,
    ) ||
    !isDeepStrictEqual(actualAttempts, expectedAttempts)
  ) {
    fail(`${label} attempt directories do not match its history`);
  }
  for (const attempt of status.attempts) {
    if (
      attempt.schema !== "deep-review-attempt/v4" ||
      attempt.phase !== phase ||
      attempt.round !== round ||
      typeof attempt.interrupted !== "boolean"
    ) {
      fail(`${label} contains an incompatible attempt`);
    }
    const attemptDirectory = path.join(
      statusDirectory,
      `attempt-${attempt.attempt}`,
    );
    const persistedAttempt = readJsonFile(
      path.join(attemptDirectory, "status.json"),
      `${label} attempt ${attempt.attempt} status`,
    );
    if (!isDeepStrictEqual(attempt, persistedAttempt)) {
      fail(`${label} attempt history does not match its persisted status`);
    }
    validateAttemptReviewer(
      attempt.claude,
      "claude",
      attempt.attempt,
      attemptDirectory,
      context,
      phase,
      round,
    );
    validateAttemptReviewer(
      attempt.codex,
      "codex",
      attempt.attempt,
      attemptDirectory,
      context,
      phase,
      round,
    );
    validateResumeSource(
      status,
      "claude",
      attempt,
      statusDirectory,
      label,
    );
    validateResumeSource(
      status,
      "codex",
      attempt,
      statusDirectory,
      label,
    );
  }
  if (
    status.attempts[0].claude.requested !== true ||
    status.attempts[0].codex.requested !== true
  ) {
    fail(`${label} attempt 1 must request both reviewers`);
  }
  for (const reviewer of ["claude", "codex"]) {
    const reviewerAttempts = status.attempts.filter(
      (attempt) => attempt[reviewer].requested,
    );
    if (
      reviewerAttempts.length > 2 ||
      reviewerAttempts
        .slice(0, -1)
        .some((attempt) => attempt[reviewer].exitCode === 0)
    ) {
      fail(
        label +
          " " +
          reviewer +
          " retry history violates the execution contract",
      );
    }
    const initialPromptSha = reviewerAttempts[0]?.[reviewer].prompt.promptSha256;
    if (
      reviewerAttempts.some(
        (attempt) =>
          attempt[reviewer].execution === "retry" &&
          attempt[reviewer].prompt.promptSha256 !== initialPromptSha,
      )
    ) {
      fail(`${label} ${reviewer} retry does not reuse the initial prompt`);
    }
    const expectedCanonical = canonicalAttempt(status.attempts, reviewer);
    if (!isDeepStrictEqual(status.canonical?.[reviewer], expectedCanonical)) {
      fail(`${label} canonical ${reviewer} result does not match its history`);
    }
    if (expectedCanonical?.exitCode === 0) {
      validateAttestedOutput(
        path.join(
          statusDirectory,
          `attempt-${expectedCanonical.attempt}`,
          `${reviewer}.out`,
        ),
        context,
        `${label} canonical ${reviewer} output`,
      );
    }
  }
  const complete =
    status.canonical.claude.exitCode === 0 &&
    status.canonical.codex.exitCode === 0;
  if (status.complete !== complete) {
    fail(`${label} has an inconsistent complete flag`);
  }
  return status;
}

function validatePairStatus(artifactDirectory, context, phase, round = null) {
  const statusDirectory = phaseStatusDirectory(artifactDirectory, phase, round);
  const label =
    phase === "primary" ? "Phase 2 pair status" : `round ${round} pair status`;
  return validatePairStatusDirectory(
    statusDirectory,
    context,
    phase,
    round,
    label,
  );
}

function validatePrimaryExecution(context, artifactDirectory) {
  if (!context) return null;
  const statusRoot = artifactDirectory ?? context.reviewArtifactDir;
  const status = validatePairStatus(statusRoot, context, "primary");
  if (!status.complete) {
    fail("Phase 2 requires successful canonical results from both reviewers");
  }
  return status;
}

function validateAdjudication(statusRoot, status, previous = null) {
  const statusDirectory = phaseStatusDirectory(
    statusRoot,
    status.phase,
    status.round,
  );
  const adjudicationPath = path.join(statusDirectory, "adjudication.json");
  try {
    return validateAdjudicationFile({
      adjudicationPath,
      pairStatus: status,
      previous,
    });
  } catch (error) {
    const scope =
      status.phase === "primary" ? "Phase 2" : `round ${status.round}`;
    fail(`${scope} adjudication is invalid: ${error.message}`);
  }
}

function validateRoundStatusArtifacts(roundRows, context, artifactDirectory) {
  if (!context) return [];
  const statusRoot = artifactDirectory ?? context.reviewArtifactDir;
  const phase4Directory = path.join(statusRoot, "phase4");
  const actualRounds = numberedDirectories(
    phase4Directory,
    "round-",
    "Phase 4 status directory",
  );
  let waveSummary;
  try {
    waveSummary = inspectReviewWaves({
      context,
      artifactDirectory: statusRoot,
    });
  } catch (error) {
    fail(`Phase 4 wave evidence is invalid: ${error.message}`);
  }
  if (waveSummary.enabled) {
    if (
      waveSummary.waves.some(
        ({ status: wave }) =>
          wave.speculative.state === "aborted-incomplete",
      )
    ) {
      fail("aborted incomplete speculative wave cannot be published");
    }
    if (!isDeepStrictEqual(actualRounds, waveSummary.canonicalRounds)) {
      fail("Phase 4 canonical rounds do not match the promoted wave sequence");
    }
    for (const { status: wave } of waveSummary.waves) {
      const speculativeDirectory = toNativeAbsolutePath(
        wave.speculative.artifactDir,
      );
      const speculativeStatusPath = path.join(
        speculativeDirectory,
        "status.json",
      );
      const speculativeStatus = existsSync(speculativeStatusPath)
        ? validatePairStatusDirectory(
            speculativeDirectory,
            context,
            "convergence",
            wave.speculativeRound,
            `speculative round ${wave.speculativeRound} pair status`,
          )
        : null;
      if (
        speculativeStatus === null &&
        (!wave.speculative.state.startsWith("cancelled-") ||
          wave.speculative.executionEvidence?.complete !== false)
      ) {
        fail("non-cancelled speculative round is missing its pair status");
      }
      if (
        wave.speculative.state.startsWith("cancelled-") &&
        speculativeStatus !== null &&
        !speculativeStatus.attempts.some(
          (attempt) => attempt.interrupted === true,
        )
      ) {
        fail("cancelled speculative round is missing interrupted evidence");
      }
      if (
        wave.speculative.state !== "promoted" &&
        existsSync(path.join(speculativeDirectory, "adjudication.json"))
      ) {
        fail("non-promoted speculative round must not be adjudicated");
      }
    }
  }
  const expectedRounds = roundRows.map((cells) => Number(cells[0]));
  if (!isDeepStrictEqual(actualRounds, expectedRounds)) {
    fail("Phase 4 status directories do not match the report rounds");
  }
  return roundRows.map((cells) => {
    const round = Number(cells[0]);
    const status = validatePairStatus(
      statusRoot,
      context,
      "convergence",
      round,
    );
    const claudeState = reviewerState(status.canonical.claude);
    const codexState = reviewerState(status.canonical.codex);
    if (cells[2] !== claudeState || cells[3] !== codexState) {
      fail(`round ${round} reviewer states do not match status.json`);
    }
    if (!status.complete) {
      fail(`round ${round} requires successful canonical results from both reviewers`);
    }
    return status;
  });
}

function validateRoundAndConvergence(
  lines,
  context,
  artifactDirectory,
  primaryAdjudication,
) {
  const rounds = sectionBody(lines, "ラウンド別集計").lines;
  requireText(
    rounds,
    "| Round | 視点 | Claude状態 | Codex状態 | Claude新規 | Codex新規 | 重複 | 撤回 | 降格 | 昇格 | 据置 | 最終集合変化 |",
    "round table header",
  );
  const roundRows = tableDataRows(rounds)
    .map(parseTableCells)
    .filter((cells) => /^\d+$/u.test(cells[0] ?? ""));
  if (roundRows.length === 0)
    fail("round table must contain at least one round");
  if (roundRows.length > MAX_CONVERGENCE_ROUNDS) {
    fail(`round table must not exceed ${MAX_CONVERGENCE_ROUNDS} rounds`);
  }
  roundRows.forEach((cells, index) => {
    if (cells.length !== 12) fail("round table row must contain 12 columns");
    if (Number(cells[0]) !== index + 1) {
      fail("round table numbering is not contiguous");
    }
    if (!REVIEWER_STATES.has(cells[2]) || !REVIEWER_STATES.has(cells[3])) {
      fail("round table reviewer state is invalid");
    }
    for (const column of [4, 5, 6, 7, 8, 9, 10]) {
      if (!/^\d+$/u.test(cells[column])) {
        fail(`round table column ${column + 1} must be numeric`);
      }
    }
    assertMeaningfulValue(cells[1], "round viewpoint");
    assertMeaningfulValue(cells[11], "round final-set change");
  });
  const roundStatuses = validateRoundStatusArtifacts(
    roundRows,
    context,
    artifactDirectory,
  );
  let previous = primaryAdjudication;
  const adjudications = context
    ? roundStatuses.map((status, index) => {
        const statusRoot = artifactDirectory ?? context.reviewArtifactDir;
        const adjudication = validateAdjudication(statusRoot, status, previous);
        previous = adjudication;
        const cells = roundRows[index];
        const summary = adjudication.summary;
        const expected = [
          String(summary.claudeNew),
          String(summary.codexNew),
          String(summary.duplicates),
          String(summary.withdrawn),
          String(summary.downgraded),
          String(summary.upgraded),
          String(summary.unchanged),
          summary.finalSetChanged ? "あり" : "なし",
        ];
        if (!isDeepStrictEqual(cells.slice(4), expected)) {
          fail(`round ${status.round} aggregate does not match adjudication.json`);
        }
        return adjudication;
      })
    : roundRows.map((cells) => ({
        summary: {
          reviewersSucceeded: cells[2] === "成功" && cells[3] === "成功",
          claudeNew: Number(cells[4]),
          codexNew: Number(cells[5]),
          withdrawn: Number(cells[7]),
          downgraded: Number(cells[8]),
          upgraded: Number(cells[9]),
          finalSetChanged: cells[11] !== "なし",
        },
      }));
  const convergence = sectionBody(lines, "収束判定").lines;
  const decision = fieldValue(convergence, "判定", {
    kind: "convergence field",
  });
  for (const label of ["安定round", "終了条件", "未収束の懸念", "撤回候補"]) {
    fieldValue(convergence, label, { kind: "convergence field" });
  }
  if (!new Set(["収束", "未収束"]).has(decision)) {
    fail("convergence decision is invalid");
  }
  const convergenceEndIndex = firstConvergenceEndIndex(adjudications);
  if (
    convergenceEndIndex >= 0 &&
    convergenceEndIndex !== adjudications.length - 1
  ) {
    fail("report contains rounds after convergence was first reached");
  }
  const stableTail = stableTailLength(adjudications);
  if (decision === "収束") {
    if (stableTail < 2) {
      fail("converged report requires two consecutive stable rounds");
    }
  } else {
    if (stableTail >= 2) {
      fail("non-converged report contradicts two consecutive stable rounds");
    }
    if (roundRows.length !== MAX_CONVERGENCE_ROUNDS) {
      fail(
        `non-converged report must complete all ${MAX_CONVERGENCE_ROUNDS} rounds`,
      );
    }
  }
  return { roundStatuses, adjudications };
}

const PR_COMMENT_SOURCES = new Map([
  ["Issue comments", "issueComments"],
  ["Reviews", "reviews"],
  ["Inline comments", "inlineComments"],
  ["Review threads", "reviewThreads"],
]);

function validatePrReviewContextFile(
  context,
  expectedPath,
  label,
  expectedRole,
  expectedSupersedesSha256,
) {
  let artifacts;
  try {
    artifacts = readPrReviewContextArtifacts(expectedPath);
  } catch (error) {
    fail(`${label} fetch receipt is invalid: ${error.message}`);
  }
  const { reviewContext } = artifacts;
  if (
    reviewContext.schema !== "deep-review-pr-review-context/v1" ||
    reviewContext.snapshotRole !== expectedRole ||
    reviewContext.supersedesSha256 !== expectedSupersedesSha256 ||
    reviewContext.reviewRunId !== context.reviewRunId ||
    reviewContext.repositoryHost !== context.repositoryHost ||
    reviewContext.repository !== context.repository ||
    String(reviewContext.prNumber) !== context.prNumber ||
    reviewContext.expectedHeadSha !== context.headSha ||
    !new Set(["checked", "not-checked"]).has(reviewContext.status) ||
    !Array.isArray(reviewContext.reasons) ||
    !Array.isArray(reviewContext.unfetched) ||
    !reviewContext.counts ||
    !reviewContext.records
  ) {
    fail(`${label} identity does not match the fixed review target`);
  }
  for (const source of PR_COMMENT_SOURCES.values()) {
    const counts = reviewContext.counts[source];
    const records = reviewContext.records[source];
    if (
      !counts ||
      ![counts.pages, counts.raw, counts.nonBot, counts.deduped].every(
        (value) => Number.isSafeInteger(value) && value >= 0,
      ) ||
      counts.raw < counts.nonBot ||
      counts.nonBot < counts.deduped ||
      !Array.isArray(records) ||
      records.length !== counts.deduped
    ) {
      fail(`${label} counts are invalid for ${source}`);
    }
  }
  if (reviewContext.status === "checked") {
    if (
      reviewContext.reasons.length !== 0 ||
      reviewContext.unfetched.length !== 0 ||
      reviewContext.headShaBefore !== context.headSha ||
      reviewContext.headShaAfter !== context.headSha
    ) {
      fail(`checked ${label} is not bound to the fixed HEAD`);
    }
  } else if (
    reviewContext.reasons.length === 0 ||
    reviewContext.reasons.some(
      (reason) => typeof reason !== "string" || reason.length === 0,
    )
  ) {
    fail(`not-checked ${label} must record a failure reason`);
  }
  return artifacts;
}

function validatePrReviewContext(context, artifactDirectory) {
  if (!context || context.reviewMode !== "pr") return null;
  const statusRoot = artifactDirectory ?? context.reviewArtifactDir;
  const initialPath = path.join(statusRoot, "pr-review-context.json");
  if (
    normalizePortablePath(context.prReviewContextPath) !==
    normalizePortablePath(initialPath)
  ) {
    fail("PR review context path does not match the review artifact directory");
  }
  const initialArtifacts = validatePrReviewContextFile(
    context,
    initialPath,
    "initial PR review context",
    "initial",
    null,
  );
  return validatePrReviewContextFile(
    context,
    path.join(statusRoot, "phase5", "pr-review-context.json"),
    "final PR review context",
    "final",
    initialArtifacts.receipt.sha256,
  );
}

function validateFinalFindingSet(
  context,
  artifactDirectory,
  finalAdjudication,
  prReviewContext,
  prReviewContextReceipt,
) {
  if (!context) return null;
  const statusRoot = artifactDirectory ?? context.reviewArtifactDir;
  const finalFindingSetPath = path.join(
    statusRoot,
    "phase5",
    "final-findings.json",
  );
  try {
    return validateFinalFindingSetFile({
      finalFindingSetPath,
      context,
      adjudication: finalAdjudication,
      prReviewContext,
      prReviewContextReceipt,
    });
  } catch (error) {
    fail(`final finding-set artifact is invalid: ${error.message}`);
  }
}

function validateHandlingAgainstFinalArtifact(
  finalFindingSet,
  reportTreatments,
  handlingCounts,
  excludedCandidates,
  finalAdjudication,
) {
  if (!finalFindingSet) return;
  const retained = new Set(
    finalFindingSet.final.findings.map((finding) => finding.id),
  );
  const decisions = new Map(
    finalFindingSet.decisions.map((decision) => [
      decision.findingId,
      decision,
    ]),
  );
  for (const [findingId, treatment] of reportTreatments) {
    const decision = decisions.get(findingId);
    if (
      !retained.has(findingId) ||
      !decision ||
      decision.handlingLabel !== treatment.handling ||
      normalizeMarkdownValue(decision.handlingRationale) !==
        treatment.handlingRationale ||
      (decision.userDecisionRequest === undefined
        ? null
        : normalizeMarkdownValue(decision.userDecisionRequest)) !==
        treatment.userDecisionRequest ||
      (decision.userDecisionImpact === undefined
        ? null
        : normalizeMarkdownValue(decision.userDecisionImpact)) !==
        treatment.userDecisionImpact ||
      (decision.verificationRequest === undefined
        ? null
        : normalizeMarkdownValue(decision.verificationRequest)) !==
        treatment.verificationRequest
    ) {
      fail(
        `report handling does not match the final finding artifact: ${findingId}`,
      );
    }
    const expectedPriorDecisionComparison = decision.rechallengeEvidence
      ? normalizeMarkdownValue(
          `再提起: ${decision.rechallengeEvidence.kindLabel} — ${decision.rechallengeEvidence.detail}`,
        )
      : null;
    if (
      expectedPriorDecisionComparison !== null
        ? treatment.priorDecisionComparison !== expectedPriorDecisionComparison
        : treatment.priorDecisionComparison.startsWith("再提起:")
    ) {
      fail(
        `report prior-decision comparison does not match the final finding artifact: ${findingId}`,
      );
    }
  }
  const phase4ById = new Map(
    finalAdjudication.after.findings.map((finding) => [finding.id, finding]),
  );
  const expectedExcluded = finalFindingSet.decisions.filter(
    (decision) => !retained.has(decision.findingId),
  );
  if (excludedCandidates.length !== expectedExcluded.length) {
    fail("excluded candidate count does not match the final finding artifact");
  }
  expectedExcluded.forEach((decision, index) => {
    const finding = phase4ById.get(decision.findingId);
    const actual = excludedCandidates[index];
    if (
      !finding ||
      actual.findingId !== decision.findingId ||
      actual.title !== normalizeMarkdownValue(finding.title) ||
      actual.severity !== finding.severity ||
      actual.handling !== decision.handlingLabel ||
      actual.handlingRationale !==
        normalizeMarkdownValue(decision.handlingRationale)
    ) {
      fail(
        `excluded candidate does not match the final finding artifact: ${decision.findingId}`,
      );
    }
  });
  for (const [key, label] of Object.entries(HANDLING_LABELS)) {
    if (handlingCounts.get(label) !== finalFindingSet.summary.handling[key]) {
      fail(`handling count does not match the final finding artifact: ${label}`);
    }
  }
}

function validateEarlierCandidatesAgainstAdjudication(
  reportRows,
  primaryAdjudication,
  roundAdjudications,
) {
  if (!primaryAdjudication) return;
  const expected = [];
  for (const adjudication of [primaryAdjudication, ...roundAdjudications]) {
    const scope =
      adjudication.phase === "primary"
        ? "Phase 2"
        : `round ${adjudication.round}`;
    for (const decision of adjudication.decisions) {
      if (decision.outcome === "rejected") {
        expected.push({
          scope,
          id: decision.candidateId,
          outcome: "棄却",
          rationale: normalizeMarkdownValue(decision.rationale),
        });
      }
    }
    for (const change of adjudication.changes) {
      if (change.action === "withdrawn") {
        expected.push({
          scope,
          id: change.findingId,
          outcome: "撤回",
          rationale: normalizeMarkdownValue(change.rationale),
        });
      }
    }
  }
  if (!isDeepStrictEqual(reportRows, expected)) {
    fail("earlier rejected candidates do not match the adjudication chain");
  }
}

function validatePrComments(
  lines,
  expectedFinalTotal,
  expectedPhase4Total,
  prMode,
  reviewContext,
  finalFindingSet,
) {
  const body = sectionBody(lines, "PRコメント照合結果").lines;
  const nonEmpty = body.filter((line) => line.trim() !== "");
  if (nonEmpty.some((line) => line.trim() === "PR未作成のため不適用")) {
    if (prMode) fail("PR report cannot skip PR comment reconciliation");
    if (expectedPhase4Total !== expectedFinalTotal) {
      fail("branch report final count does not match the Phase 4 finding set");
    }
    if (
      nonEmpty.length !== 1 ||
      nonEmpty[0].trim() !== "PR未作成のため不適用"
    ) {
      fail("branch PR comment marker must be the only section content");
    }
    return;
  }
  if (!prMode) fail("branch report must use the PR-not-created marker");
  requireText(
    body,
    "| 情報源 | 取得件数 | 状態・未取得範囲 |",
    "PR comment source table",
  );
  const sourceRows = tableDataRows(body).map(parseTableCells);
  const acquisitionStatus = fieldValue(body, "取得状態", {
    kind: "PR comment acquisition status",
  });
  if (!new Set(["checked", "not-checked"]).has(acquisitionStatus)) {
    fail("PR comment acquisition status is invalid");
  }
  if (reviewContext && acquisitionStatus !== reviewContext.status) {
    fail("PR comment acquisition status does not match its artifact");
  }
  for (const [source, artifactSource] of PR_COMMENT_SOURCES) {
    const matches = sourceRows.filter((cells) => cells[0] === source);
    if (matches.length !== 1 || matches[0].length !== 3) {
      fail(
        `expected exactly one three-column PR comment source row: ${source}`,
      );
    }
    if (!/^\d+$/u.test(matches[0][1])) {
      fail(`PR comment source count must be numeric: ${source}`);
    }
    if (
      reviewContext &&
      Number(matches[0][1]) !== reviewContext.counts[artifactSource].deduped
    ) {
      fail(`PR comment source count does not match its artifact: ${source}`);
    }
    assertMeaningfulValue(matches[0][2], `PR comment source state: ${source}`);
  }
  fieldValue(body, "照合", { kind: "PR comment reconciliation" });
  fieldValue(body, "判定内訳", { kind: "PR comment decision breakdown" });
  fieldValue(body, "件数集計", { kind: "PR comment count summary" });
  fieldValue(body, "件数式", { kind: "PR comment count equation" });
  fieldValue(body, "UI状態だけで除外した候補", {
    kind: "PR comment UI-state guard",
  });
  const normalized = body.map((line) => line.replaceAll("`", ""));
  const summaryLine = normalized.find((line) => line.startsWith("- 件数集計:"));
  const summary = summaryLine?.match(
    /^- 件数集計:\s*Phase4=(\d+),\s*除外=(\d+),\s*継続=(\d+),\s*最終=(\d+)\s*$/u,
  );
  if (!summary) fail("PR comment count summary has an invalid format");
  const [phase4, excluded, retained, finalTotal] = summary.slice(1).map(Number);
  if (phase4 !== excluded + retained || finalTotal !== retained) {
    fail("PR comment count summary arithmetic is inconsistent");
  }
  if (phase4 !== expectedPhase4Total) {
    fail("PR comment Phase4 count does not match the adjudicated final set");
  }
  if (finalTotal !== expectedFinalTotal) {
    fail(
      `PR comment final count mismatch: expected ${expectedFinalTotal}, got ${finalTotal}`,
    );
  }
  if (acquisitionStatus === "not-checked" && excluded !== 0) {
    fail("not-checked PR comments cannot exclude findings");
  }
  const breakdownLine = normalized.find((line) =>
    line.startsWith("- 判定内訳:"),
  );
  const breakdown = breakdownLine?.match(
    /^- 判定内訳:\s*addressed=(\d+),\s*dismissed-valid=(\d+),\s*dismissed-but-rechallenge=(\d+),\s*not-judged=(\d+)\s*$/u,
  );
  if (!breakdown) fail("PR comment decision breakdown has an invalid format");
  const [addressed, dismissedValid, dismissedButRechallenge, notJudged] =
    breakdown.slice(1).map(Number);
  if (
    addressed + dismissedValid !== excluded ||
    dismissedButRechallenge + notJudged !== retained
  ) {
    fail("PR comment decision breakdown is inconsistent");
  }
  if (finalFindingSet) {
    const expected = finalFindingSet.summary;
    if (
      addressed !== expected.addressed ||
      dismissedValid !== expected.dismissedValid ||
      dismissedButRechallenge !== expected.dismissedButRechallenge ||
      notJudged !== expected.notJudged ||
      phase4 !== expected.phase4 ||
      excluded !== expected.excluded ||
      retained !== expected.retained ||
      finalTotal !== expected.final
    ) {
      fail(
        "PR comment accounting does not match the final finding-set artifact",
      );
    }
  }
  const equationLine = normalized.find((line) => line.startsWith("- 件数式:"));
  const equation = equationLine?.match(
    /^- 件数式:\s*(\d+)\s*=\s*(\d+)\s*\+\s*(\d+)、\s*(\d+)\s*=\s*(\d+)\s*$/u,
  );
  if (!equation) fail("PR comment count equation has an invalid format");
  const [
    equationPhase4,
    equationExcluded,
    equationRetained,
    equationFinal,
    equationRetainedAgain,
  ] = equation.slice(1).map(Number);
  if (
    equationPhase4 !== phase4 ||
    equationExcluded !== excluded ||
    equationRetained !== retained ||
    equationFinal !== finalTotal ||
    equationRetainedAgain !== retained
  ) {
    fail("PR comment count equation does not match the count summary");
  }
  if (
    !normalized.some((line) => /UI状態だけで除外した候補:\s*0件/u.test(line))
  ) {
    fail("PR comments excluded by UI state alone must be zero");
  }
}

function normalizePortablePath(value) {
  const slashes = value.replaceAll("\\", "/").replace(/\/{2,}/gu, "/");
  const drive = slashes.match(/^([A-Za-z]):\/(.*)$/u);
  return drive ? `/${drive[1].toLowerCase()}/${drive[2]}` : slashes;
}

function expectedHeader(context) {
  if (context.reviewMode === "pr") {
    return `# Deep Review: PR #${context.prNumber}`;
  }
  if (context.reviewMode === "branch") {
    return `# Deep Review: branch ${context.headRef}`;
  }
  fail("context reviewMode must be pr or branch");
}

function validateHeader(lines, context) {
  if (context) {
    const expected = expectedHeader(context);
    if (lines[0] !== expected) {
      fail(`report header does not match context: expected ${expected}`);
    }
    return;
  }
  if (!lines[0].startsWith("# Deep Review:")) {
    fail("report is missing the expected deep-review header");
  }
  assertMeaningfulValue(
    lines[0].slice("# Deep Review:".length),
    "report header",
  );
}

function executionScope(status) {
  return status.phase === "primary" ? "Phase 2" : `round ${status.round}`;
}

function expectedRetryResumeFailureTrace(statuses) {
  const events = [];
  for (const status of statuses) {
    const scope = executionScope(status);
    for (const attempt of status.attempts) {
      if (attempt.interrupted) {
        events.push(`${scope} attempt ${attempt.attempt} 中断`);
      }
      for (const [reviewer, reviewerLabel] of [
        ["claude", "Claude"],
        ["codex", "Codex"],
      ]) {
        const record = attempt[reviewer];
        if (
          record.requested &&
          (attempt.attempt > 1 || reviewerState(record) !== "成功")
        ) {
          events.push(
            `${scope} ${reviewerLabel} attempt ${attempt.attempt} ` +
              `${record.execution} ${reviewerState(record)}`,
          );
        }
      }
    }
  }
  return events.length === 0 ? "なし" : events.join("; ");
}

function validateTrace(
  lines,
  context,
  primaryStatus,
  roundStatuses,
  finalFindingSetSha256,
  handlingSha256,
) {
  const body = sectionBody(lines, "実行証跡").lines;
  const labels = [
    "対象",
    "BASE / HEAD / merge-base",
    "オーケストレーター",
    "Claude reviewer",
    "Codex reviewer",
    "review run ID",
    "tooling digest",
    "diff digest",
    "snapshot metadata digest",
    "BASE guidance digest",
    "final finding-set digest",
    "handling digest",
    "初回review",
    "retry / resume / 失敗",
    "run固有report",
  ];
  const values = new Map(
    labels.map((label) => [
      label,
      fieldValue(body, label, { kind: "execution trace field" }),
    ]),
  );
  if (!/^(?:pr:\d+|branch:.+)$/u.test(values.get("対象"))) {
    fail("execution trace target has an invalid format");
  }
  const shas = values
    .get("BASE / HEAD / merge-base")
    .split("/")
    .map((value) => value.trim());
  if (shas.length !== 3 || shas.some((sha) => !GIT_SHA_PATTERN.test(sha))) {
    fail("execution trace BASE / HEAD / merge-base has an invalid format");
  }
  if (
    !new Set(["Claude Code", "Codex"]).has(values.get("オーケストレーター"))
  ) {
    fail("execution trace orchestrator is invalid");
  }
  if (!UUID_PATTERN.test(values.get("review run ID"))) {
    fail("execution trace review run ID is invalid");
  }
  for (const label of [
    "tooling digest",
    "diff digest",
    "snapshot metadata digest",
    "BASE guidance digest",
    "final finding-set digest",
    "handling digest",
  ]) {
    if (!SHA256_PATTERN.test(values.get(label))) {
      fail(`execution trace ${label} must be a SHA-256 digest`);
    }
  }
  if (values.get("final finding-set digest") !== finalFindingSetSha256) {
    fail("execution trace final finding-set digest does not match report findings");
  }
  if (
    handlingSha256 &&
    values.get("handling digest") !== handlingSha256
  ) {
    fail("execution trace handling digest does not match Phase 5 decisions");
  }
  const reportPath = values.get("run固有report");
  if (!path.isAbsolute(reportPath) && !/^[A-Za-z]:[\\/]/u.test(reportPath)) {
    fail("execution trace run-specific report must be an absolute path");
  }

  if (context) {
    const expected = new Map([
      ["対象", context.target],
      [
        "BASE / HEAD / merge-base",
        `${context.baseSha} / ${context.headSha} / ${context.mergeBaseSha}`,
      ],
      ["review run ID", context.reviewRunId],
      ["tooling digest", context.toolingDigest],
      ["diff digest", context.diffSha256],
      ["snapshot metadata digest", context.snapshotMetadataSha256],
      ["BASE guidance digest", context.baseGuidanceSha256],
    ]);
    for (const [label, expectedValue] of expected) {
      if (values.get(label) !== expectedValue) {
        fail(`execution trace ${label} does not match context`);
      }
    }
    const expectedReportPath = normalizePortablePath(
      `${context.reviewArtifactDir}/report.md`,
    );
    if (normalizePortablePath(reportPath) !== expectedReportPath) {
      fail("execution trace run-specific report does not match context");
    }
    if (primaryStatus) {
      const primary = values
        .get("初回review")
        .match(
          /^Claude\s+(成功|失敗|未起動)\s*\/\s*Codex\s+(成功|失敗|未起動)$/u,
        );
      if (!primary) {
        fail("execution trace initial review has an invalid format");
      }
      const initialStates = {
        claude: reviewerState(primaryStatus.attempts[0].claude),
        codex: reviewerState(primaryStatus.attempts[0].codex),
      };
      if (
        primary[1] !== initialStates.claude ||
        primary[2] !== initialStates.codex
      ) {
        fail("execution trace initial review does not match Phase 2 status");
      }
      const expectedDetails = expectedRetryResumeFailureTrace([
        primaryStatus,
        ...roundStatuses,
      ]);
      if (values.get("retry / resume / 失敗") !== expectedDetails) {
        fail(
          "execution trace retry / resume / failure does not match " +
            "the attempt history",
        );
      }
    }
  }
}

export function validateReviewReport(reportPath, options = {}) {
  assertRegularReport(reportPath);
  const content = readFileSync(reportPath, "utf8");
  const layout = normalizeDialogueLayout(content.split(/\r?\n/u));
  const { lines } = layout;
  validateHeader(lines, options.context);
  validateRequiredSections(lines);
  assertMeaningfulValue(
    sectionBody(lines, "結論").lines.join("\n"),
    "conclusion",
  );
  validateReviewScope(lines);
  const preliminaryCountLines = sectionBody(
    lines,
    "Claude／Codexクロスチェック",
  ).lines;
  const countHeading = preliminaryCountLines.indexOf("### 最終重要度件数");
  if (countHeading < 0) fail("missing final severity count heading");
  const handlingHeading = preliminaryCountLines.indexOf(
    "### 今回の取扱い件数",
  );
  if (handlingHeading < 0 || handlingHeading <= countHeading) {
    fail("missing or misplaced handling count heading");
  }
  requireText(
    preliminaryCountLines.slice(countHeading + 1, handlingHeading),
    "| 重要度 | 件数 | 意味 |",
    "severity count table header",
  );
  requireText(
    preliminaryCountLines.slice(handlingHeading + 1),
    "| 今回の取扱い | 件数 | 意味 |",
    "handling count table header",
  );
  const tableCounts = parseSeverityCounts(
    preliminaryCountLines.slice(countHeading + 1, handlingHeading),
  );
  const handlingCounts = parseHandlingCounts(
    preliminaryCountLines.slice(handlingHeading + 1),
  );
  validateConclusionHandlingSummary(lines, handlingCounts);
  const { findings: reportFindings, treatments: reportTreatments } =
    validateFindings(lines, tableCounts);
  validateUserDecisionSummary(lines, reportTreatments);
  const total = reportFindings.length;
  validateCrossCheck(
    lines,
    tableCounts,
    reportFindings,
    reportTreatments,
    handlingCounts,
  );
  const excludedCandidateSections = validateExcludedCandidates(lines);
  const primaryStatus = validatePrimaryExecution(
    options.context,
    options.artifactDirectory,
  );
  const statusRoot = options.artifactDirectory ?? options.context?.reviewArtifactDir;
  const primaryAdjudication = options.context
    ? validateAdjudication(statusRoot, primaryStatus)
    : null;
  const { roundStatuses, adjudications } = validateRoundAndConvergence(
    lines,
    options.context,
    options.artifactDirectory,
    primaryAdjudication,
  );
  const finalAdjudication = adjudications.at(-1);
  validateEarlierCandidatesAgainstAdjudication(
    excludedCandidateSections.earlierRows,
    primaryAdjudication,
    adjudications,
  );
  const prMode = options.context
    ? options.context.reviewMode === "pr"
    : options.target
      ? /^[0-9]+$/u.test(options.target)
      : /^# Deep Review:\s*PR\s+#\d+/u.test(lines[0]);
  const prReviewArtifacts = validatePrReviewContext(
    options.context,
    options.artifactDirectory,
  );
  const prReviewContext = prReviewArtifacts?.reviewContext ?? null;
  const prReviewContextReceipt = prReviewArtifacts?.receipt ?? null;
  const finalFindingSet = validateFinalFindingSet(
    options.context,
    options.artifactDirectory,
    finalAdjudication,
    prReviewContext,
    prReviewContextReceipt,
  );
  const reportFindingSetSha256 = findingSetSha256(reportFindings);
  if (
    finalFindingSet &&
    finalFindingSet.final.sha256 !== reportFindingSetSha256
  ) {
    fail("report findings do not match the final finding-set artifact");
  }
  validateHandlingAgainstFinalArtifact(
    finalFindingSet,
    reportTreatments,
    handlingCounts,
    excludedCandidateSections.phase5Rows,
    finalAdjudication,
  );
  validateDialogueAccounting(
    layout,
    reportFindings,
    excludedCandidateSections.phase5Rows,
    primaryAdjudication,
    adjudications,
    finalFindingSet,
    reportTreatments,
  );
  validatePrComments(
    lines,
    total,
    finalAdjudication?.after?.findings.length ?? total,
    prMode,
    prReviewContext,
    finalFindingSet,
  );
  validateTrace(
    lines,
    options.context,
    primaryStatus,
    roundStatuses,
    reportFindingSetSha256,
    finalFindingSet?.handling.sha256 ?? null,
  );
  assertMeaningfulValue(
    sectionBody(lines, "未検証事項").lines.join("\n"),
    "unverified items section",
  );
  return {
    counts: Object.fromEntries(tableCounts),
    handlingCounts: Object.fromEntries(handlingCounts),
    total,
  };
}

function parseArgs(argv) {
  if (argv.length !== 2 || argv[0] !== "--report" || !argv[1]) {
    fail("usage: validate-review-report.mjs --report <path>");
  }
  return argv[1];
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    const reportPath = parseArgs(process.argv.slice(2));
    const result = validateReviewReport(reportPath);
    process.stdout.write(`REPORT_OK: ${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
