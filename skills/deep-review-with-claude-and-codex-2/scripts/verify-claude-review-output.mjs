#!/usr/bin/env node

import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function fail(message) {
  throw new Error(message);
}

function sha256(content) {
  return createHash("sha256").update(content).digest("hex");
}

function usage() {
  process.stderr.write(
    "Usage: verify-claude-review-output.mjs --control <path> --input <path> --output <path>\n",
  );
}

function parseArgs(argv) {
  if (
    argv.length !== 6 ||
    argv[0] !== "--control" ||
    argv[2] !== "--input" ||
    argv[4] !== "--output"
  ) {
    usage();
    process.exit(2);
  }
  return { control: argv[1], input: argv[3], output: argv[5] };
}

function assertRegularFile(filePath, label) {
  const stat = lstatSync(filePath);
  if (stat.isSymbolicLink() || !stat.isFile()) {
    fail(`${label} must be a regular non-symlink file`);
  }
}

function parseRunnerOutput(raw) {
  const lines = raw.replaceAll("\r\n", "\n").split("\n");
  const separatorIndex = lines.indexOf("---");
  if (separatorIndex < 1) fail("Claude runner output is missing separator");

  const headerLines = lines.slice(0, separatorIndex);
  const sessionLines = headerLines.filter((line) =>
    line.startsWith("SESSION_ID: "),
  );
  if (
    sessionLines.length !== 1 ||
    sessionLines[0].slice("SESSION_ID: ".length).trim().length === 0
  ) {
    fail("Claude runner output is missing a unique nonempty SESSION_ID");
  }
  for (const line of headerLines) {
    if (
      !line.startsWith("SESSION_ID: ") &&
      !line.startsWith("COST_USD: ") &&
      !line.startsWith("DENIALS: ")
    ) {
      fail(`unexpected Claude runner header: ${line}`);
    }
  }
  return {
    headerLines,
    bodyLines: lines.slice(separatorIndex + 1),
  };
}

export function normalizedFindingText(value) {
  return value
    .trim()
    .replace(/^(?:[-+*]|\d+[.)]|#{1,6})[ \t]+/u, "")
    .replace(/^(?:\*\*|__)(.*)(?:\*\*|__)$/u, "$1")
    .trim();
}

export function withoutFencedCodeBlocks(body) {
  const lines = body.replaceAll("\r\n", "\n").split("\n");
  let fenceCharacter = "";
  let fenceLength = 0;
  let fenceContainerIndent = 0;
  const listContainerIndents = [];

  function indentationColumns(value) {
    let columns = 0;
    for (const character of value) {
      if (character === " ") {
        columns += 1;
      } else if (character === "\t") {
        columns += 4 - (columns % 4);
      } else {
        columns += 1;
      }
    }
    return columns;
  }

  function leadingIndentColumns(line) {
    const indentation = /^[ \t]*/u.exec(line)[0];
    return indentationColumns(indentation);
  }

  function contentAfterIndent(line, targetColumns) {
    let columns = 0;
    let offset = 0;
    while (
      offset < line.length &&
      columns < targetColumns &&
      (line[offset] === " " || line[offset] === "\t")
    ) {
      columns =
        line[offset] === " " ? columns + 1 : columns + 4 - (columns % 4);
      offset += 1;
    }
    if (columns < targetColumns) return line;
    return `${" ".repeat(columns - targetColumns)}${line.slice(offset)}`;
  }

  function fenceOpening(content) {
    const opening = /^ {0,3}(`{3,}|~{3,})(.*)$/u.exec(content);
    if (
      !opening ||
      (opening[1][0] === "`" && opening[2].includes("`"))
    ) {
      return null;
    }
    return opening[1];
  }

  function listItem(content) {
    const item =
      /^( {0,3})((?:[-+*]|\d{1,9}[.)]))([ \t]{1,4})(.*)$/u.exec(content);
    if (!item) return null;
    return {
      content: item[4],
      indent: indentationColumns(`${item[1]}${item[2]}${item[3]}`),
    };
  }

  function openFence(opening, containerIndent) {
    fenceCharacter = opening[0];
    fenceLength = opening.length;
    fenceContainerIndent = containerIndent;
  }

  function processOutsideFence(line) {
    if (line.trim() === "") return line;
    const lineIndent = leadingIndentColumns(line);
    while (
      listContainerIndents.length > 0 &&
      lineIndent > 0 &&
      lineIndent < listContainerIndents.at(-1)
    ) {
      listContainerIndents.pop();
    }
    if (lineIndent === 0) {
      listContainerIndents.length = 0;
    }

    let containerIndent = listContainerIndents.at(-1) ?? 0;
    let content =
      containerIndent > 0 ? contentAfterIndent(line, containerIndent) : line;
    let item = listItem(content);
    if (item) {
      do {
        containerIndent += item.indent;
      listContainerIndents.push(containerIndent);
        content = item.content;
        item = listItem(content);
      } while (item);
      const opening = fenceOpening(content);
      if (opening) {
        openFence(opening, containerIndent);
        return "";
      }
      return line;
    }

    const opening = fenceOpening(content);
    if (opening) {
      openFence(opening, containerIndent);
      return "";
    }
    return line;
  }

  return lines
    .map((line) => {
      if (fenceCharacter) {
        if (
          fenceContainerIndent > 0 &&
          line.trim() !== "" &&
          leadingIndentColumns(line) < fenceContainerIndent
        ) {
          fenceCharacter = "";
          fenceLength = 0;
          fenceContainerIndent = 0;
          return processOutsideFence(line);
        }
        const content =
          fenceContainerIndent > 0
            ? contentAfterIndent(line, fenceContainerIndent)
            : line;
        const closing = /^ {0,3}(`{3,}|~{3,})[ \t]*$/u.exec(content);
        if (
          closing &&
          closing[1][0] === fenceCharacter &&
          closing[1].length >= fenceLength
        ) {
          fenceCharacter = "";
          fenceLength = 0;
          fenceContainerIndent = 0;
        }
        return "";
      }
      return processOutsideFence(line);
    })
    .join("\n");
}

export function isSubstantiveFinding(value) {
  const normalized = normalizedFindingText(value);
  if (!/[\p{L}\p{N}]/u.test(normalized)) return false;
  const statusOnly =
    /^(?:(?:the[ \t]+)?review[ \t]+(?:(?:(?:is|was|has)[ \t]+)?(?:(?:been|now|successfully|fully|already)[ \t]+)*(?:complete|completed|finished|done|concluded))(?:[ \t]+(?:successfully|fully|already))?|reviewed|completed|done|ok|okay|all[ \t]+clear|no_findings|確認済み?|レビュー済み?|完了|レビュー完了)[.!。！]?\s*$/iu;
  const exactNoFinding =
    /^(?:なし|無し|特になし|ありません|見つかりません(?:でした)?|none(?:[ \t]+(?:found|identified))?|(?:no|zero)[ \t]+(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?)(?:[ \t]+(?:(?:were|was)[ \t]+)?(?:found|identified|detected|observed|reported|surfaced))?|nothing[ \t]+(?:found|identified)|n\/?a|not[ \t]+applicable)[.!。！]?\s*$/iu;
  const completionPrefix =
    /^(?:(?:the[ \t]+)?review[ \t]+(?:(?:(?:(?:is|was|has)[ \t]+)?(?:(?:been|now|successfully|fully|already)[ \t]+)*(?:complete|completed|finished|done|concluded))(?:[ \t]+(?:successfully|fully|already))?|found|identified|detected|reported|surfaced|noted|flagged|uncovered)|there[ \t]+(?:were|was|are|is|have[ \t]+been|has[ \t]+been)|reviewed|completed|done|ok|okay|all[ \t]+clear)(?=[ \t,.!:;—–-]|$)(?:[ \t]*[,.!:;—–-])?[ \t]*(?:(?:with|and|but|however)[ \t]+)?/iu;
  const vacuousNoFinding =
    /^(?:(?:no|zero)[ \t]+(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?)(?:[ \t]+(?:(?:(?:were|was|are|is|have[ \t]+been|has[ \t]+been)[ \t]+)?(?:found|identified|detected|observed|reported|surfaced|noted|flagged)|to[ \t]+(?:report|flag|note)|remain|exist))?|without[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?)|nothing[ \t]+(?:of[ \t]+note|found|identified|to[ \t]+(?:report|flag|note)))(?:[ \t]+(?:in|within|across|during|throughout|for|among)[ \t]+(?:the[ \t]+|this[ \t]+)?(?:(?:reviewed|current|provided|fixed)[ \t]+)?(?:changes?|diff|snapshot|code|files?|implementation|pull[ \t]+request|pr|review|analysis|inspection|repository|repo|codebase))?(?:[ \t]*(?:[,;—–-][ \t]*)?(?:but[ \t]+)?(?:flagging|noting)(?:[ \t]+it)?[ \t]+anyway)?[.!]?\s*$/iu;
  const withoutCompletionPrefix = normalized.replace(completionPrefix, "");
  const leadingNoFindingClaim =
    /^(?:(?:(?:no|zero)[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?|without[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?)(?:findings?|issues?|problems?|bugs?|concerns?|errors?|failures?)(?:(?:[ \t]*(?:,[ \t]*(?:(?:or|and)[ \t]+)?|(?:or|and)[ \t]+))(?:findings?|issues?|problems?|bugs?|concerns?|errors?|failures?))*|nothing[ \t]+(?:of[ \t]+note|found|identified|to[ \t]+(?:report|flag|note)))(?:[ \t]+(?:(?:(?:were|was|are|is|have[ \t]+been|has[ \t]+been)[ \t]+)?(?:found|identified|detected|observed|reported|surfaced|noted|flagged|shown|emerged|appeared)|to[ \t]+(?:report|flag|note)|remain(?:ed|s|ing)?|exist(?:ed|s|ing)?|emerge(?:d|s|ing)?|appear(?:ed|s|ing)?))?(?:[ \t]+(?:(?:in|within|across|during|throughout|for|among)[ \t]+(?:the[ \t]+|this[ \t]+)?(?:(?:reviewed|current|provided|fixed)[ \t]+)?(?:changes?|diff|snapshot|code|files?|implementation|pull[ \t]+request|pr|review|analysis|inspection|repository|repo|codebase|validation)|while[ \t]+(?:reviewing|inspecting|analyzing)[ \t]+(?:the[ \t]+|this[ \t]+)?(?:changes?|diff|snapshot|code|files?|implementation|pull[ \t]+request|pr|repository|repo|codebase)))?/iu;
  const negatedIssueClaim =
    /^(?:(?:no|zero)[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?|errors?|failures?)\b|without[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?|errors?|failures?)\b|(?:[\p{L}\p{N}'’_-]+[ \t]+){0,5}(?:review|reviewer|analysis|inspection)[ \t]+(?:(?:did|does|do|has|have|was|were|is|are|could|can|would|will)[ \t]+not|(?:didn['’]t|doesn['’]t|don['’]t|hasn['’]t|haven['’]t|wasn['’]t|weren['’]t|isn['’]t|aren['’]t|couldn['’]t|can['’]t|wouldn['’]t|won['’]t))[ \t]+(?:(?:successfully|actually|ultimately)[ \t]+)?(?:find|found|identify|identified|detect|detected|observe|observed|report|reported|surface|surfaced|note|noted|flag|flagged|uncover|uncovered)[ \t]+(?:any[ \t]+)?(?:actionable[ \t]+)?(?:findings?|issues?|problems?|bugs?|concerns?|errors?|failures?)\b)/iu;
  const leadingConnector =
    /^[ \t]*(?:[,;:—–-][ \t]*)?(?:(?:but|however|yet|and)[ \t]+)?/iu;
  let residualFindingText = withoutCompletionPrefix;
  let removedNoFindingClaim = false;
  while (true) {
    residualFindingText = residualFindingText
      .replace(leadingConnector, "")
      .trim();
    const noFindingMatch =
      leadingNoFindingClaim.exec(residualFindingText) ??
      negatedIssueClaim.exec(residualFindingText);
    if (noFindingMatch === null) break;
    residualFindingText = `${residualFindingText.slice(
      0,
      noFindingMatch.index,
    )} ${residualFindingText.slice(
      noFindingMatch.index + noFindingMatch[0].length,
    )}`;
    removedNoFindingClaim = true;
  }
  residualFindingText = residualFindingText
    .replace(leadingConnector, "")
    .trim();
  const nonFindingResidual =
    /^(?:(?:the[ \t]+)?review|(?:(?:because|since|as|when|after|once)[ \t]+)?(?:the[ \t]+)?review[ \t]+(?:(?:(?:is|was|has|had)[ \t]+)?(?:(?:been|now|successfully|fully|already)[ \t]+)*(?:complete|completed|finished|done|concluded|passed|successful|succeeded))(?:[ \t]+(?:successfully|fully|already))?|(?:just[ \t]+)?(?:flagging|noting)(?:[ \t]+it)?(?:[ \t]+anyway)?)[.!]?\s*$/iu;
  const japaneseNoFinding =
    /^(?=.*(?:該当|指摘|問題|課題|懸念|不具合|箇所|事項)).*(?:なし|ありません|見つかりません(?:でした)?|確認されません(?:でした)?|検出されません(?:でした)?)[.!。！]?\s*$/u;
  return (
    !statusOnly.test(normalized) &&
    !exactNoFinding.test(normalized) &&
    !vacuousNoFinding.test(withoutCompletionPrefix) &&
    !(
      removedNoFindingClaim &&
      (residualFindingText === "" ||
        statusOnly.test(residualFindingText) ||
        nonFindingResidual.test(residualFindingText) ||
        vacuousNoFinding.test(residualFindingText))
    ) &&
    !japaneseNoFinding.test(normalized)
  );
}

function normalizedSeverity(value) {
  const normalized = normalizedFindingText(value).toLowerCase();
  const map = new Map([
    ["critical", "Critical"],
    ["high", "High"],
    ["medium", "Medium"],
    ["low", "Low"],
    ["重大", "Critical"],
    ["高", "High"],
    ["中", "Medium"],
    ["低", "Low"],
  ]);
  return map.get(normalized) ?? null;
}

function inlineCandidates(lines) {
  const patterns = [
    /^[ \t]*(?:#{1,6}[ \t]+)?(?:(?:[-*]|\d+[.)])[ \t]+)?(?:\*\*|__)?(?<severity>Critical|High|Medium|Low)(?:\*\*|__)?[ \t]*(?:[:：—–.-][ \t]*|[ \t]+\d+[.:：)][ \t]*)(?<title>.+)$/iu,
    /^[ \t]*(?:#{1,6}[ \t]+)?(?:(?:[-*]|\d+[.)])[ \t]+)?\[(?<severity>Critical|High|Medium|Low)\][ \t]+(?<title>.+)$/iu,
    /^[ \t]*(?:#{1,6}[ \t]+)?(?:(?:[-*]|\d+[.)])[ \t]+)?(?<prefix>[CHML])\d+[.:：)][ \t]*(?<title>.+)$/iu,
  ];
  const prefixSeverity = { C: "Critical", H: "High", M: "Medium", L: "Low" };
  const candidates = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    for (const pattern of patterns) {
      const match = pattern.exec(line);
      if (!match || !isSubstantiveFinding(match.groups.title)) continue;
      const severity = match.groups.severity
        ? normalizedSeverity(match.groups.severity)
        : prefixSeverity[match.groups.prefix.toUpperCase()];
      candidates.push({
        severity,
        title: normalizedFindingText(match.groups.title),
        sourceLine: index + 1,
      });
      break;
    }
  }
  return candidates;
}

function fieldCandidates(lines) {
  const severityField =
    /^[ \t]*(?:[-*][ \t]+)?(?:\*\*|__)?(?:severity|重要度)(?:\*\*|__)?[ \t]*[:：][ \t]*(?<severity>critical|high|medium|low|重大|高|中|低)(?:[ \t]*(?:[:：—–-][ \t]*)?(?<title>.+))?$/iu;
  const contentField =
    /^[ \t]*(?:[-*][ \t]+)?(?:\*\*|__)?(?:finding|issue|title|claim|evidence|rationale|指摘|内容|タイトル|主張|根拠)(?:\*\*|__)?[ \t]*[:：][ \t]*(?<title>.+)$/iu;
  const heading = /^[ \t]*#{1,6}[ \t]+(?<title>.+)$/u;
  const candidates = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = severityField.exec(lines[index]);
    if (!match) continue;
    let title = match.groups.title;
    let sourceLine = index + 1;
    let hasContentField = false;
    if (title !== undefined && !isSubstantiveFinding(title)) continue;
    if (title === undefined) {
      title = null;
      for (let next = index + 1; next < lines.length; next += 1) {
        if (severityField.test(lines[next]) || heading.test(lines[next])) break;
        const content = contentField.exec(lines[next]);
        if (!content) continue;
        hasContentField = true;
        if (isSubstantiveFinding(content.groups.title)) {
          title = content.groups.title;
          sourceLine = next + 1;
          break;
        }
      }
    }
    if (!title && !hasContentField) {
      for (let previous = index - 1; previous >= 0; previous -= 1) {
        if (lines[previous].trim() === "") continue;
        const previousHeading = heading.exec(lines[previous]);
        if (
          previousHeading &&
          !/^(?:finding|issue|指摘|review[ \t]+results?|レビュー結果)[ \t]*\d*[.:：)]?$/iu.test(
            normalizedFindingText(previousHeading.groups.title),
          ) &&
          isSubstantiveFinding(previousHeading.groups.title)
        ) {
          title = previousHeading.groups.title;
          sourceLine = previous + 1;
        }
        break;
      }
    }
    if (title) {
      candidates.push({
        severity: normalizedSeverity(match.groups.severity),
        title: normalizedFindingText(title),
        sourceLine,
      });
    }
  }
  return candidates;
}

function indentationColumns(value) {
  let columns = 0;
  for (const character of value) {
    columns =
      character === "\t" ? columns + 4 - (columns % 4) : columns + 1;
  }
  return columns;
}

function groupedCandidates(lines) {
  const groupHeading =
    /^[ \t]*(?:(?<groupMarks>#{1,6})[ \t]+(?:\*\*|__)?(?<severity>Critical|High|Medium|Low)(?:\*\*|__)?|(?:\*\*|__)(?<plainSeverity>Critical|High|Medium|Low)(?:\*\*|__))[ \t]*$/iu;
  const listFinding =
    /^(?<indent>[ \t]*)(?<marker>[-+*]|\d+[.)])(?<spacing>[ \t]+)(?<title>.+)$/u;
  const headingFinding =
    /^(?<indent>[ \t]*)(?<marks>#{1,6})[ \t]+(?<title>.+)$/u;
  const emphasisFinding =
    /^(?<indent>[ \t]*)(?<marker>\*\*|__)(?<title>.+)$/u;
  const candidates = [];
  const ownedRanges = [];
  for (let index = 0; index < lines.length; index += 1) {
    const group = groupHeading.exec(lines[index]);
    if (!group) continue;
    const severity = normalizedSeverity(
      group.groups.severity ?? group.groups.plainSeverity,
    );
    const groupLevel = group.groups.groupMarks?.length ?? null;
    let ownershipEnd = lines.length - 1;
    for (let scan = index + 1; scan < lines.length; scan += 1) {
      if (groupHeading.test(lines[scan])) {
        ownershipEnd = scan - 1;
        break;
      }
      const sectionHeading = headingFinding.exec(lines[scan]);
      if (
        groupLevel !== null &&
        sectionHeading !== null &&
        sectionHeading.groups.marks.length <= groupLevel
      ) {
        ownershipEnd = scan - 1;
        break;
      }
    }
    const groupCandidates = [];
    let mode = null;
    let rootListContentIndent = null;
    let findingHeadingLevel = null;
    let emphasisIndent = null;
    let collectingCandidates = true;
    for (let next = index + 1; next <= ownershipEnd; next += 1) {
      if (lines[next].trim() === "") continue;

      const list = listFinding.exec(lines[next]);
      const heading = headingFinding.exec(lines[next]);
      const emphasis = emphasisFinding.exec(lines[next]);
      const headingLevel = heading?.groups.marks.length ?? null;

      const lineIndent = indentationColumns(/^[ \t]*/u.exec(lines[next])[0]);
      if (mode === null) {
        if (list && isSubstantiveFinding(list.groups.title)) {
          mode = "list";
          rootListContentIndent =
            indentationColumns(list.groups.indent) +
            list.groups.marker.length +
            indentationColumns(list.groups.spacing);
        } else if (heading && isSubstantiveFinding(heading.groups.title)) {
          mode = "heading";
          findingHeadingLevel = headingLevel;
        } else if (emphasis && isSubstantiveFinding(lines[next])) {
          mode = "emphasis";
          emphasisIndent = indentationColumns(emphasis.groups.indent);
        } else {
          break;
        }
      }

      if (mode === "list" && heading !== null) {
        if (groupLevel === null) {
          ownershipEnd = next - 1;
          break;
        }
        collectingCandidates = false;
        continue;
      }
      if (
        mode === "list" &&
        list === null &&
        lineIndent < rootListContentIndent
      ) {
        ownershipEnd = next - 1;
        break;
      }
      if (
        mode === "heading" &&
        headingLevel !== null &&
        headingLevel < findingHeadingLevel
      ) {
        if (groupLevel === null) {
          ownershipEnd = next - 1;
          break;
        }
        collectingCandidates = false;
        continue;
      }
      if (mode === "emphasis" && heading !== null) {
        if (groupLevel === null) {
          ownershipEnd = next - 1;
          break;
        }
        collectingCandidates = false;
        continue;
      }
      if (!collectingCandidates) continue;

      let title = null;
      if (
        mode === "list" &&
        list &&
        indentationColumns(list.groups.indent) < rootListContentIndent
      ) {
        title = list.groups.title;
      } else if (
        mode === "heading" &&
        headingLevel === findingHeadingLevel
      ) {
        title = heading.groups.title;
      } else if (
        mode === "emphasis" &&
        emphasis &&
        indentationColumns(emphasis.groups.indent) === emphasisIndent
      ) {
        title = lines[next];
      }
      if (!title || !isSubstantiveFinding(title)) {
        continue;
      }
      groupCandidates.push({
        severity,
        title: normalizedFindingText(title),
        sourceLine: next + 1,
      });
    }
    if (groupCandidates.length > 0) {
      candidates.push(...groupCandidates);
      ownedRanges.push({ startLine: index + 2, endLine: ownershipEnd + 1 });
    }
  }
  return { candidates, ownedRanges };
}

function markdownCells(line) {
  const trimmed = line.trim();
  if (!trimmed.includes("|")) return null;
  const withoutEdges = trimmed.replace(/^\|/, "").replace(/\|$/, "");
  return withoutEdges.split("|").map((cell) => cell.trim());
}

function normalizedTableCell(cell) {
  return cell.replace(/^(?:\*\*|__)(.*)(?:\*\*|__)$/u, "$1").trim();
}

function tableCandidates(lines) {
  const severityHeader = /^(?:severity|level|重要度)$/iu;
  const findingHeader = /^(?:findings?|issues?|problems?|指摘|内容)$/iu;
  const delimiter = /^:?-{3,}:?$/u;
  const candidates = [];

  for (let index = 0; index < lines.length - 2; index += 1) {
    const headers = markdownCells(lines[index]);
    const delimiters = markdownCells(lines[index + 1]);
    if (
      !headers ||
      !delimiters ||
      headers.length !== delimiters.length ||
      !delimiters.every((cell) => delimiter.test(cell))
    ) {
      continue;
    }
    const normalizedHeaders = headers.map(normalizedTableCell);
    const severityIndex = normalizedHeaders.findIndex((cell) =>
      severityHeader.test(cell),
    );
    const findingIndex = normalizedHeaders.findIndex((cell) =>
      findingHeader.test(cell),
    );
    if (severityIndex < 0 || findingIndex < 0) continue;

    for (let rowIndex = index + 2; rowIndex < lines.length; rowIndex += 1) {
      const cells = markdownCells(lines[rowIndex]);
      if (!cells || cells.length !== headers.length) break;
      const severity = normalizedSeverity(cells[severityIndex]);
      const title = normalizedFindingText(cells[findingIndex]);
      if (severity && isSubstantiveFinding(title)) {
        candidates.push({ severity, title, sourceLine: rowIndex + 1 });
      }
    }
  }
  return candidates;
}

export function parseReviewBody(body) {
  const contractBody = withoutFencedCodeBlocks(body);
  const lines = contractBody.split("\n");
  const grouped = groupedCandidates(lines);
  const groupedCandidateKeys = new Set(
    grouped.candidates.map(
      (candidate) =>
        `${candidate.sourceLine}\n${candidate.severity}\n${candidate.title}`,
    ),
  );
  const parserResults = [
    { candidates: inlineCandidates(lines), grouped: false },
    { candidates: fieldCandidates(lines), grouped: false },
    { candidates: grouped.candidates, grouped: true },
    { candidates: tableCandidates(lines), grouped: false },
  ];
  const candidates = [];
  const seen = new Set();
  for (const result of parserResults) {
    for (const candidate of result.candidates) {
      // Only merge overlapping parser interpretations of the same source
      // occurrence. Repeated titles on different lines are separate findings.
      const key = `${candidate.sourceLine}\n${candidate.severity}\n${candidate.title}`;
      const ownedByGroup = grouped.ownedRanges.some(
        (range) =>
          candidate.sourceLine >= range.startLine &&
          candidate.sourceLine <= range.endLine,
      );
      if (
        !result.grouped &&
        ownedByGroup &&
        !groupedCandidateKeys.has(key)
      ) {
        continue;
      }
      if (seen.has(key)) continue;
      seen.add(key);
      candidates.push(candidate);
    }
  }
  const noFindings =
    /^[ \t]*(?:\*\*|__)?NO_FINDINGS(?:\*\*|__)?[ \t]*$/mu.test(
      contractBody,
    );
  const scope =
    /(?:^|\n)[ \t]*(?:[-*][ \t]*)?(?:#{1,6}[ \t]*)?(?:\*\*|__)?scope(?:\*\*|__)?[ \t]*[:：][ \t]*\S/imu.test(
      contractBody,
    );
  const reason =
    /(?:^|\n)[ \t]*(?:[-*][ \t]*)?(?:#{1,6}[ \t]*)?(?:\*\*|__)?reason(?:\*\*|__)?[ \t]*[:：][ \t]*\S/imu.test(
      contractBody,
    );
  return { candidates, noFindings, scope, reason };
}

export function verifyReviewBody(body, reviewer = "Claude") {
  const parsed = parseReviewBody(body);
  if (parsed.noFindings && !(parsed.scope && parsed.reason)) {
    fail(`${reviewer} NO_FINDINGS body must include scope + reason`);
  }
  if (parsed.noFindings && parsed.candidates.length > 0) {
    fail(`${reviewer} output cannot contain both NO_FINDINGS and findings`);
  }
  if (!parsed.noFindings && parsed.candidates.length === 0) {
    fail(
      `${reviewer} review body must contain severity-tagged findings or NO_FINDINGS + scope + reason`,
    );
  }
  return parsed;
}

function verify(args) {
  assertRegularFile(args.control, "Claude review control");
  assertRegularFile(args.input, "raw Claude runner output");
  const control = JSON.parse(readFileSync(args.control, "utf8"));
  if (
    control.schema !== "deep-review-claude-input/v1" ||
    typeof control.receiptLine !== "string" ||
    typeof control.diffProbeSha256 !== "string" ||
    typeof control.runId !== "string" ||
    !["review", "followup"].includes(control.resultContract)
  ) {
    fail("invalid Claude review control");
  }

  const { headerLines, bodyLines } = parseRunnerOutput(
    readFileSync(args.input, "utf8"),
  );
  while (bodyLines.length > 0 && bodyLines[0].trim() === "") {
    bodyLines.shift();
  }
  if (bodyLines[0] !== control.receiptLine) {
    fail(
      "Claude input receipt is missing or does not match this review generation",
    );
  }
  bodyLines.shift();
  while (bodyLines.length > 0 && bodyLines[0].trim() === "") {
    bodyLines.shift();
  }
  if (
    sha256(Buffer.from(bodyLines[0] ?? "", "utf8")) !==
    control.diffProbeSha256
  ) {
    fail("Claude diff access probe is missing or does not match the fixed diff");
  }
  bodyLines.shift();
  while (bodyLines.length > 0 && bodyLines[0].trim() === "") {
    bodyLines.shift();
  }
  while (
    bodyLines.length > 0 &&
    bodyLines[bodyLines.length - 1].trim() === ""
  ) {
    bodyLines.pop();
  }
  const body = bodyLines.join("\n");
  if (body.trim().length === 0) fail("Claude produced an empty review body");
  if (control.resultContract === "review") verifyReviewBody(body);

  const verified = [
    ...headerLines,
    `RUN_ID: ${control.runId}`,
    "INPUT_ATTESTATION: verified",
    `TARGET: ${control.target}`,
    `HEAD_SHA: ${control.headSha}`,
    `DIFF_SHA256: ${control.diffSha256}`,
    `SNAPSHOT_METADATA_SHA256: ${control.snapshotMetadataSha256}`,
    "---",
    body,
    "",
  ].join("\n");
  writeFileSync(args.output, verified, { flag: "wx", mode: 0o600 });
  chmodSync(args.output, 0o600);
}

const invokedPath = process.argv[1];
if (
  invokedPath &&
  import.meta.url === pathToFileURL(path.resolve(invokedPath)).href
) {
  try {
    verify(parseArgs(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exit(1);
  }
}
