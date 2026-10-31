
// Runtime config (SSM Parameter Store) and credentials (Secrets Manager), cached briefly.
import { SSMClient, GetParametersByPathCommand } from "@aws-sdk/client-ssm";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const ssm = new SSMClient({});
const secrets = new SecretsManagerClient({});

const PARAM_TTL_MS = 30_000; // kill switch takes effect within ~30 seconds
const SECRET_TTL_MS = 5 * 60_000; // rotated keys picked up within ~5 minutes

let paramCache = { at: 0, value: null };
let secretCache = { at: 0, value: null };

export async function getParams() {
  if (paramCache.value && Date.now() - paramCache.at < PARAM_TTL_MS) return paramCache.value;

  const path = process.env.PARAM_PATH;
  const raw = {};
  let NextToken;
  do {
    const res = await ssm.send(new GetParametersByPathCommand({ Path: path, NextToken }));
    for (const p of res.Parameters ?? []) raw[p.Name.slice(path.length + 1)] = p.Value;
    NextToken = res.NextToken;
  } while (NextToken);

  const value = {
    aiEnabled: raw.ai_enabled !== "false",
    salesforceEnabled: raw.salesforce_enabled === "true",
    confidenceThreshold: Number(raw.confidence_threshold ?? "0.75"),
    modelId: raw.model_id ?? "claude-haiku-4-5",
    prices: {
      inputPerMTok: Number(raw.price_input_per_mtok ?? "1"),
      outputPerMTok: Number(raw.price_output_per_mtok ?? "5"),
    },
  };
  paramCache = { at: Date.now(), value };
  return value;
}

export async function getSecrets() {
  if (secretCache.value && Date.now() - secretCache.at < SECRET_TTL_MS) return secretCache.value;

  const res = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.SECRET_ID }));
  const value = JSON.parse(res.SecretString);
  secretCache = { at: Date.now(), value };
  return value;
}