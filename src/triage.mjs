

// Pure triage logic: no AWS dependencies, so the eval script can run it in CI.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const PROMPT_VERSION = "triage-v1";

const here = dirname(fileURLToPath(import.meta.url));
const SYSTEM_PROMPT = readFileSync(join(here, "prompts", `${PROMPT_VERSION}.txt`), "utf8");

export const CATEGORIES = [
  "denied_entry",
  "card_or_membership_issue",
  "refund_or_billing",
  "lounge_experience",
  "account_or_data_request",
  "other",
];
export const URGENCIES = ["low", "medium", "high"];
export const RISK_FLAGS = [
  "legal_threat",
  "safety",
  "media_threat",
  "vulnerable_customer",
  "data_request",
];

const CLAUDE_TIMEOUT_MS = 10_000;

// Turns raw model text into a validated object, or explains why it can't.
export function parseAndValidate(raw) {
  let text = String(raw ?? "").trim();

  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) text = fenced[1];

  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) return { ok: false, error: "no_json_object" };

  let obj;
  try {
    obj = JSON.parse(text.slice(start, end + 1));
  } catch {
    return { ok: false, error: "invalid_json" };
  }

  const bad = [];
  if (!CATEGORIES.includes(obj.category)) bad.push("category");
  if (!URGENCIES.includes(obj.urgency)) bad.push("urgency");
  if (typeof obj.confidence !== "number" || obj.confidence < 0 || obj.confidence > 1)
    bad.push("confidence");
  if (!Array.isArray(obj.risk_flags) || !obj.risk_flags.every((f) => RISK_FLAGS.includes(f)))
    bad.push("risk_flags");
  if (typeof obj.summary !== "string" || obj.summary.trim() === "") bad.push("summary");
  if (typeof obj.draft_reply !== "string" || obj.draft_reply.trim().length < 20)
    bad.push("draft_reply");

  if (bad.length) return { ok: false, error: `invalid_fields:${bad.join(",")}` };

  return {
    ok: true,
    value: {
      category: obj.category,
      urgency: obj.urgency,
      confidence: obj.confidence,
      risk_flags: obj.risk_flags,
      summary: obj.summary.trim(),
      draft_reply: obj.draft_reply.trim(),
    },
  };
}

// Estimated cost of one triage in USD. Prices are per million tokens.
export function estimateCostUsd(usage, { inputPerMTok, outputPerMTok }) {
  const cost =
    ((usage.input_tokens ?? 0) * inputPerMTok + (usage.output_tokens ?? 0) * outputPerMTok) /
    1_000_000;
  return Math.round(cost * 1_000_000) / 1_000_000; // round to 6 decimal places
}

async function callClaude({ apiKey, model, messages, deadline }) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    if (Date.now() + CLAUDE_TIMEOUT_MS > deadline) {
      throw Object.assign(new Error("deadline_exceeded"), { status: 504 });
    }

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        max_tokens: 800,
        temperature: 0,
        system: SYSTEM_PROMPT,
        messages,
      }),
      signal: AbortSignal.timeout(CLAUDE_TIMEOUT_MS),
    });

    if (res.ok) {
      const data = await res.json();
      const text = (data.content ?? [])
        .filter((b) => b.type === "text")
        .map((b) => b.text)
        .join("");
      return { text, usage: data.usage ?? {} };
    }

    const retryable = res.status === 429 || res.status >= 500;
    const detail = (await res.text()).slice(0, 300);
    if (!retryable || attempt === 2) {
      throw Object.assign(new Error(`claude_http_${res.status}`), { status: res.status, detail });
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

// Classify one (already redacted) member message.
// Returns { ok: true, result, attempts, usage } or { ok: false, error, attempts, usage }.
export async function triage(message, { apiKey, model, deadline = Date.now() + 25_000 }) {
  const messages = [{ role: "user", content: `<message>\n${message}\n</message>` }];
  const usage = { input_tokens: 0, output_tokens: 0 };
  let lastError = "not_attempted";

  for (let attempt = 1; attempt <= 2; attempt++) {
    const reply = await callClaude({ apiKey, model, messages, deadline });
    usage.input_tokens += reply.usage.input_tokens ?? 0;
    usage.output_tokens += reply.usage.output_tokens ?? 0;

    const parsed = parseAndValidate(reply.text);
    if (parsed.ok) return { ok: true, result: parsed.value, attempts: attempt, usage };

    // Self-correction: show the model its bad output and ask again once.
    lastError = parsed.error;
    if (Date.now() + CLAUDE_TIMEOUT_MS > deadline) break;
    messages.push(
      { role: "assistant", content: reply.text || "(empty)" },
      {
        role: "user",
        content: `That reply was not valid (${parsed.error}). Respond again with ONLY the JSON object, exactly matching the required fields and allowed values.`,
      },
    );
  }

  return { ok: false, error: lastError, attempts: 2, usage };
}
