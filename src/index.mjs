
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { getParams, getSecrets } from "./config.mjs";
import { triage, estimateCostUsd, PROMPT_VERSION, CATEGORIES } from "./triage.mjs";
import { createCase } from "./salesforce.mjs";
import { redact } from "./redact.mjs";
import { emit, log } from "./metrics.mjs";

const sqs = new SQSClient({});

const json = (statusCode, body) => ({
  statusCode,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

function parseBody(event) {
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : event.body;
  return JSON.parse(raw ?? "");
}

// ---------- Access control (Entra ID app roles) ----------
function getRoles(event) {
  const raw = event.requestContext?.authorizer?.jwt?.claims?.roles;
  if (!raw) return [];
  if (Array.isArray(raw)) return raw;
  // API Gateway may pass array claims as a string like "[Agent.Operator]"
  return String(raw).replace(/^\[|\]$/g, "").split(/[\s,]+/).filter(Boolean);
}

function authorize(event, allowedRoles) {
  if (process.env.AUTH_MODE !== "entra") return { ok: true, role: "unauthenticated" };
  const roles = getRoles(event);
  const role = allowedRoles.find((r) => roles.includes(r));
  return role ? { ok: true, role } : { ok: false, role: roles[0] ?? "none" };
}

function callerOf(event) {
  return event.requestContext?.authorizer?.jwt?.claims?.azp ?? "anonymous";
}

// ---------- Salesforce Case shape ----------
function buildCase({ message, memberRef, outcome, requestId, modelId }) {
  const t = outcome.triage;
  const review = outcome.route === "human_review";
  const priority = t ? { high: "High", medium: "Medium", low: "Low" }[t.urgency] : "Medium";
  const subject = `${review ? "[REVIEW] " : ""}${t ? t.category : "untriaged"}: ${t ? t.summary : message.slice(0, 80)}`;
  const description = [
    `Member message:\n${message}`,
    memberRef ? `Member reference: ${memberRef}` : null,
    "--- AI triage ---",
    t
      ? `Category: ${t.category}\nUrgency: ${t.urgency}\nConfidence: ${t.confidence}\nRisk flags: ${t.risk_flags.join(", ") || "none"}\n\nDraft reply (review before sending):\n${t.draft_reply}`
      : `No AI triage (${outcome.reason})`,
    `Routing: ${outcome.route} (${outcome.reason})`,
    `Prompt: ${PROMPT_VERSION} | Model: ${modelId} | Request: ${requestId}`,
  ]
    .filter(Boolean)
    .join("\n\n");

  return {
    Subject: subject.slice(0, 255),
    Description: description.slice(0, 32000),
    Priority: priority,
    Origin: "Web",
    Status: "New",
  };
}

// ---------- GET /status ----------
async function handleStatus(event) {
  const auth = authorize(event, ["Agent.Viewer", "Agent.Operator"]);
  if (!auth.ok) {
    emit({ AccessDenied: 1 });
    return json(403, { error: "forbidden" });
  }

  const params = await getParams();
  return json(200, {
    env: process.env.ENV,
    functionVersion: process.env.AWS_LAMBDA_FUNCTION_VERSION,
    promptVersion: PROMPT_VERSION,
    modelId: params.modelId,
    aiEnabled: params.aiEnabled,
    salesforceEnabled: params.salesforceEnabled,
    confidenceThreshold: params.confidenceThreshold,
    callerRole: auth.role,
  });
}

// ---------- POST /triage ----------
async function handleTriage(event, requestId) {
  const started = Date.now();
  const caller = callerOf(event);
  const auth = authorize(event, ["Agent.Operator"]);
  emit({ CallsByRole: 1 }, { dimensions: { Role: auth.role } });

  if (!auth.ok) {
    emit({ AccessDenied: 1 });
    log("warn", "access_denied", { requestId, caller, role: auth.role, route: "POST /triage" });
    return json(403, { error: "forbidden", requestId });
  }

  let body;
  try {
    body = parseBody(event);
  } catch {
    return json(400, { error: "body must be JSON", requestId });
  }

  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (message.length < 10 || message.length > 4000) {
    return json(400, { error: "message must be 10-4000 characters", requestId });
  }

  const memberRef = typeof body.member_ref === "string" ? body.member_ref.slice(0, 50) : null;
  // "synthetic" for the traffic generator, "api" for everything else. Lets you split real vs test traffic.
  const source =
    typeof body.source === "string" && /^[a-z-]{1,20}$/.test(body.source) ? body.source : "api";
  const safeMessage = redact(message); // used everywhere below: AI, CRM, queue, logs

  emit({ Requests: 1 });

  try {
    const params = await getParams();
    const secrets = await getSecrets();

    // 1. Decide the outcome
    let outcome;
    let costUsd = 0;

    if (!params.aiEnabled) {
      outcome = { route: "human_review", reason: "kill_switch", triage: null };
      emit({ KillSwitchActive: 1 });
    } else {
      const t = await triage(safeMessage, {
        apiKey: secrets.ANTHROPIC_API_KEY,
        model: params.modelId,
        deadline: started + 22_000,
      });
      costUsd = estimateCostUsd(t.usage, params.prices);
      emit({
        ClaudeInputTokens: t.usage.input_tokens,
        ClaudeOutputTokens: t.usage.output_tokens,
        EstimatedCostUSD: costUsd,
      });

      if (!t.ok) {
        emit({ InvalidAIOutput: 1 });
        outcome = { route: "human_review", reason: `invalid_ai_output:${t.error}`, triage: null };
      } else {
        const r = t.result;
        const risky = r.risk_flags.length > 0;
        const lowConfidence = r.confidence < params.confidenceThreshold;
        outcome = {
          route: risky || lowConfidence ? "human_review" : "auto_case",
          reason: risky
            ? `risk_flags:${r.risk_flags.join("|")}`
            : lowConfidence
              ? "low_confidence"
              : "ok",
          triage: r,
        };
        emit({ TriageSuccess: 1 });
      }
    }
    if (outcome.route === "human_review") emit({ HumanReview: 1 });

    // 2. Record it in the CRM. If Salesforce fails, queue it for retry instead of losing it.
    let crm = { status: "disabled", caseId: null };
    if (params.salesforceEnabled) {
      const fields = buildCase({
        message: safeMessage,
        memberRef,
        outcome,
        requestId,
        modelId: params.modelId,
      });
      try {
        crm = { status: "created", caseId: await createCase(secrets, fields) };
        emit({ SalesforceCaseCreated: 1 });
      } catch (err) {
        emit({ SalesforceFailures: 1 });
        log("error", "salesforce_failed", { requestId, error: err.message });
        try {
          await sqs.send(
            new SendMessageCommand({
              QueueUrl: process.env.CRM_QUEUE_URL,
              MessageBody: JSON.stringify({ requestId, fields }),
            }),
          );
          emit({ CrmQueued: 1 });
          crm = { status: "queued", caseId: null };
        } catch (queueErr) {
          // Both Salesforce AND the queue failed: now we really can't record it. Tell the caller.
          log("error", "crm_queue_failed", { requestId, error: queueErr.message });
          return json(502, { error: "crm_unavailable", requestId, route: outcome.route });
        }
      }
    }

    // 3. Log the decision (never the message text itself)
    const latencyMs = Date.now() - started;
    emit({ LatencyMs: latencyMs });
    log("info", "triage_complete", {
      requestId,
      caller,
      role: auth.role,
      source,
      promptVersion: PROMPT_VERSION,
      model: params.modelId,
      route: outcome.route,
      reason: outcome.reason,
      category: outcome.triage?.category,
      urgency: outcome.triage?.urgency,
      confidence: outcome.triage?.confidence,
      crmStatus: crm.status,
      salesforceCaseId: crm.caseId,
      costUsd,
      messageLength: message.length,
      latencyMs,
    });

    return json(200, {
      requestId,
      route: outcome.route,
      reason: outcome.reason,
      triage: outcome.triage,
      crmStatus: crm.status,
      salesforceCaseId: crm.caseId,
      costUsd,
      promptVersion: PROMPT_VERSION,
    });
  } catch (err) {
    emit({ TriageErrors: 1 });
    log("error", "triage_failed", {
      requestId,
      error: err.message,
      status: err.status,
      detail: err.detail,
    });
    return json(500, { error: "internal_error", requestId });
  }
}

// ---------- POST /feedback ----------
// A reviewer (human, or the simulated reviewer in the traffic generator) records
// whether the AI's category was right. This produces a LIVE accuracy metric.
async function handleFeedback(event, requestId) {
  const caller = callerOf(event);
  const auth = authorize(event, ["Agent.Operator"]);
  if (!auth.ok) {
    emit({ AccessDenied: 1 });
    log("warn", "access_denied", { requestId, caller, role: auth.role, route: "POST /feedback" });
    return json(403, { error: "forbidden", requestId });
  }

  let body;
  try {
    body = parseBody(event);
  } catch {
    return json(400, { error: "body must be JSON", requestId });
  }

  const triageRequestId = typeof body.request_id === "string" ? body.request_id.slice(0, 100) : "";
  if (
    !triageRequestId ||
    !CATEGORIES.includes(body.ai_category) ||
    !CATEGORIES.includes(body.correct_category)
  ) {
    return json(400, {
      error: "need request_id, ai_category and correct_category (valid categories)",
      requestId,
    });
  }

  const override = body.ai_category === body.correct_category ? 0 : 1;
  emit({ FeedbackReceived: 1, AIOverride: override });
  log("info", "feedback", {
    requestId,
    triageRequestId,
    reviewer: caller,
    aiCategory: body.ai_category,
    correctCategory: body.correct_category,
    override,
  });
  return json(202, { recorded: true, override: override === 1, requestId });
}

// ---------- Salesforce retry worker (SQS) ----------
// Messages land here when Salesforce failed during /triage. SQS retries every ~5 minutes;
// after 6 attempts the message moves to the dead-letter queue and an alarm fires.
async function handleCrmRetry(event) {
  const secrets = await getSecrets();
  const failures = [];

  for (const record of event.Records) {
    const attempt = Number(record.attributes?.ApproximateReceiveCount ?? 1);
    try {
      const { requestId, fields } = JSON.parse(record.body);
      const caseId = await createCase(secrets, fields);
      emit({ CrmRetrySucceeded: 1 });
      log("info", "crm_retry_ok", { requestId, salesforceCaseId: caseId, attempt });
    } catch (err) {
      emit({ CrmRetryFailed: 1 });
      log("warn", "crm_retry_failed", { messageId: record.messageId, attempt, error: err.message });
      failures.push({ itemIdentifier: record.messageId });
    }
  }

  return { batchItemFailures: failures }; // only failed messages go back to the queue
}

// ---------- Entry point ----------
export const handler = async (event, context) => {
  // SQS events are handled OUTSIDE the try/catch on purpose: if something unexpected
  // breaks (e.g. secrets unreadable), the error must reach Lambda so SQS retries the
  // batch. Catching it and returning normally would silently delete the messages.
  if (Array.isArray(event.Records)) return handleCrmRetry(event);

  const requestId = context?.awsRequestId ?? "local";
  try {
    if (event.routeKey === "GET /status") return await handleStatus(event);
    if (event.routeKey === "POST /triage") return await handleTriage(event, requestId);
    if (event.routeKey === "POST /feedback") return await handleFeedback(event, requestId);
    return json(404, { error: "not_found" });
  } catch (err) {
    emit({ TriageErrors: 1 });
    log("error", "unhandled", { requestId, error: err.message });
    return json(500, { error: "internal_error", requestId });
  }
};