// Synthetic member traffic. Runs every 20 minutes (EventBridge) and plays two parts:
// 1. Members: sends realistic complaints through the REAL API (API Gateway, auth, agent, Claude, CRM).
// 2. A QA reviewer: it knows the true category of each message, so it sends feedback
//    the same way a human reviewer would. That's what produces the live accuracy metric.
import { readFileSync } from "node:fs";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const MESSAGES = JSON.parse(readFileSync(new URL("./messages.json", import.meta.url), "utf8"));
const secrets = new SecretsManagerClient({});

function emit(metrics) {
  console.log(
    JSON.stringify({
      _aws: {
        Timestamp: Date.now(),
        CloudWatchMetrics: [
          {
            Namespace: "AgentOps",
            Dimensions: [["Env"]],
            Metrics: Object.keys(metrics).map((Name) => ({ Name, Unit: "Count" })),
          },
        ],
      },
      Env: process.env.ENV,
      ...metrics,
    }),
  );
}

// Before Day 7 the API is open. After Day 7 the generator logs in to Entra like any other system.
async function getToken() {
  if (process.env.AUTH_MODE !== "entra") return null;

  const res = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.TRAFFIC_SECRET_ID }));
  const s = JSON.parse(res.SecretString);

  const r = await fetch(`https://login.microsoftonline.com/${process.env.TENANT_ID}/oauth2/v2.0/token`, {
    method: "POST",
    body: new URLSearchParams({
      client_id: s.CLIENT_ID,
      client_secret: s.CLIENT_SECRET,
      scope: `api://${process.env.API_CLIENT_ID}/.default`,
      grant_type: "client_credentials",
    }),
    signal: AbortSignal.timeout(5000),
  });
  if (!r.ok) throw new Error(`token_http_${r.status}`);
  return (await r.json()).access_token;
}

// Busier during South African business hours (07:00-21:00 SAST), quiet at night.
function howManyThisRun() {
  const hourSast = (new Date().getUTCHours() + 2) % 24;
  const busy = hourSast >= 7 && hourSast < 21;
  return busy ? 1 + Math.floor(Math.random() * 3) : Math.floor(Math.random() * 2);
}

async function post(path, body, token) {
  const res = await fetch(`${process.env.API_URL}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });

  let data = null;
  try {
    data = await res.json();
  } catch {
    // non-JSON body (e.g. API Gateway "Unauthorized"): keep data = null
  }
  return { status: res.status, data };
}

export const handler = async () => {
  const count = howManyThisRun();
  if (count === 0) return;

  let token = null;
  try {
    token = await getToken();
  } catch (err) {
    console.log(JSON.stringify({ level: "error", message: "synthetic_token_failed", error: err.message }));
    emit({ SyntheticRequests: count, SyntheticFailures: count });
    return;
  }

  for (let i = 0; i < count; i++) {
    const m = MESSAGES[Math.floor(Math.random() * MESSAGES.length)];
    let ok = false;
    try {
      const r = await post(
        "/triage",
        { message: m.message, member_ref: `SYN-${m.id}`, source: "synthetic" },
        token,
      );
      ok = r.status === 200;

      const aiCategory = r.data?.triage?.category; // null when the kill switch is on or AI output was invalid
      if (ok && aiCategory) {
        const fb = await post(
          "/feedback",
          { request_id: r.data.requestId, ai_category: aiCategory, correct_category: m.expected_category },
          token,
        );
        if (fb.status !== 202) ok = false;
      }

      console.log(
        JSON.stringify({
          level: ok ? "info" : "warn",
          message: "synthetic_request",
          id: m.id,
          status: r.status,
          route: r.data?.route,
          aiCategory,
          expected: m.expected_category,
        }),
      );
    } catch (err) {
      console.log(
        JSON.stringify({ level: "error", message: "synthetic_request_failed", id: m.id, error: err.message }),
      );
    }
    emit({ SyntheticRequests: 1, SyntheticFailures: ok ? 0 : 1 });
  }
};