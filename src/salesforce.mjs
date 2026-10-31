
// Salesforce integration: OAuth 2.0 client credentials flow + Case creation.
const API_VERSION = "v62.0";
const TIMEOUT_MS = 5_000;

let token = null; // cached across warm Lambda invocations

async function getToken(s) {
  const res = await fetch(`${s.SF_LOGIN_URL}/services/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: s.SF_CLIENT_ID,
      client_secret: s.SF_CLIENT_SECRET,
    }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`sf_token_http_${res.status}: ${(await res.text()).slice(0, 200)}`);

  const data = await res.json();
  token = { accessToken: data.access_token, instanceUrl: data.instance_url };
  return token;
}

export async function createCase(s, fields) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    const t = token ?? (await getToken(s));
    const res = await fetch(`${t.instanceUrl}/services/data/${API_VERSION}/sobjects/Case`, {
      method: "POST",
      headers: { authorization: `Bearer ${t.accessToken}`, "content-type": "application/json" },
      body: JSON.stringify(fields),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });

    if (res.status === 401 && attempt === 1) {
      token = null; // token expired or revoked: get a fresh one and retry once
      continue;
    }
    if (!res.ok) throw new Error(`sf_case_http_${res.status}: ${(await res.text()).slice(0, 200)}`);

    const data = await res.json();
    return data.id;
  }
}