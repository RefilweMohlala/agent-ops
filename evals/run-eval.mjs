// AI eval gate: runs the current prompt against labelled examples.
// Exits with code 1 (fails the pipeline) if accuracy drops below the threshold
// or a risky message is not flagged.
import { readFileSync, appendFileSync } from "node:fs";
import { triage, PROMPT_VERSION } from "../src/triage.mjs";
import { redact } from "../src/redact.mjs";

const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) {
  console.error("ANTHROPIC_API_KEY is not set");
  process.exit(2);
}

const model = process.env.MODEL_ID || "claude-haiku-4-5";
const threshold = Number(process.env.EVAL_THRESHOLD || "0.85");
const cases = JSON.parse(readFileSync(new URL("./cases.json", import.meta.url), "utf8"));

let correct = 0;
let invalid = 0;
let missedRisk = 0;
const rows = [];

for (const c of cases) {
  const t = await triage(redact(c.message), { apiKey, model, deadline: Date.now() + 60_000 });

  if (!t.ok) {
    invalid++;
    rows.push(`| ${c.id} | ${c.expected_category} | INVALID (${t.error}) | - | - | ✘ |`);
    continue;
  }

  const r = t.result;
  const pass = r.category === c.expected_category;
  const riskOk = !c.expect_risk || r.risk_flags.length > 0;
  if (pass) correct++;
  if (!riskOk) missedRisk++;

  rows.push(
    `| ${c.id} | ${c.expected_category} | ${r.category} | ${r.confidence} | ${r.risk_flags.join(", ") || "-"} | ${pass && riskOk ? "✔" : "✘"} |`,
  );
}

const accuracy = correct / cases.length;
const passed = accuracy >= threshold && missedRisk === 0;

const report = [
  `## AI eval: ${PROMPT_VERSION} on ${model}`,
  "",
  `**Accuracy:** ${(accuracy * 100).toFixed(1)}% (threshold ${(threshold * 100).toFixed(0)}%) · **Invalid outputs:** ${invalid} · **Missed risk flags:** ${missedRisk}`,
  "",
  "| Case | Expected | Got | Confidence | Risk flags | |",
  "|---|---|---|---|---|---|",
  ...rows,
  "",
  passed ? "**EVAL GATE PASSED**" : "**EVAL GATE FAILED**",
].join("\n");

console.log(report);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, report + "\n");

process.exit(passed ? 0 : 1);