import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAndValidate, estimateCostUsd } from "../src/triage.mjs";
import { redact } from "../src/redact.mjs";

const good = {
  category: "denied_entry",
  urgency: "high",
  confidence: 0.9,
  risk_flags: [],
  summary: "Member refused entry despite a valid card.",
  draft_reply: "We're sorry you were refused entry. Our team is reviewing this now and will be in touch.",
};

test("accepts a valid response", () => {
  const r = parseAndValidate(JSON.stringify(good));
  assert.equal(r.ok, true);
  assert.equal(r.value.category, "denied_entry");
});

test("accepts JSON wrapped in code fences or extra text", () => {
  assert.equal(parseAndValidate("```json\n" + JSON.stringify(good) + "\n```").ok, true);
  assert.equal(parseAndValidate("Here you go: " + JSON.stringify(good)).ok, true);
});

test("rejects text with no JSON", () => {
  assert.deepEqual(parseAndValidate("Sorry, I can't help with that."), {
    ok: false,
    error: "no_json_object",
  });
});

test("rejects broken JSON", () => {
  assert.equal(parseAndValidate('{"category": "denied_entry",').error, "no_json_object");
  assert.equal(parseAndValidate('{"category": denied_entry}').error, "invalid_json");
});

test("rejects values outside the allowed lists", () => {
  const r = parseAndValidate(
    JSON.stringify({ ...good, category: "complaint", confidence: 7, risk_flags: ["angry"] }),
  );
  assert.equal(r.ok, false);
  assert.equal(r.error, "invalid_fields:category,confidence,risk_flags");
});

test("redacts email, card and phone numbers", () => {
  const out = redact("Mail me at jane.doe@example.com, card 4111 1111 1111 1111, call +27 82 555 1234.");
  assert.equal(out, "Mail me at [EMAIL], card [CARD_NUMBER], call [PHONE].");
});

test("leaves normal text alone", () => {
  const msg = "My flight leaves in 40 minutes from gate 12.";
  assert.equal(redact(msg), msg);
});

test("does not mistake dates for phone numbers", () => {
  const msg = "I was charged twice on 2026-10-03, and I've been a member from 2021-2025.";
  assert.equal(redact(msg), msg);
});

test("estimates cost from token usage", () => {
  // 1,000 input tokens at $1/M + 200 output tokens at $5/M = $0.001 + $0.001
  const cost = estimateCostUsd(
    { input_tokens: 1000, output_tokens: 200 },
    { inputPerMTok: 1, outputPerMTok: 5 },
  );
  assert.equal(cost, 0.002);
});