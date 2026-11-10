# Runbook 04: Access requests, access reviews and denied-access spikes

**Roles** (Entra ID app roles on the `agent-ops-api` app registration, single tenant):

| Role | Can do |
|---|---|
| `Agent.Operator` | `POST /triage`, `POST /feedback`, `GET /status` |
| `Agent.Viewer` | `GET /status` only |

**How a request is checked:** API Gateway validates the token (signature, issuer, audience, expiry) and returns **401** if it is missing, expired or wrong. It never reaches the Lambda, so 401s are not in the Lambda metrics. The Lambda then checks the role for the route and returns **403** if it is wrong. Only 403s count towards `AccessDenied` and the dashboard's **Access patterns** widget.

**Current clients:**

| Client app | Role | Used by | Secret stored in | Secret expires |
|---|---|---|---|---|
| `agent-ops-operator-client` | Operator | Manual operations | Private notes (not in the repo) | <YYYY-MM-DD> |
| `agent-ops-viewer-client` | Viewer | Pipeline smoke test | GitHub secret `SMOKE_CLIENT_SECRET` | <YYYY-MM-DD> |
| `agent-ops-traffic-generator` | Operator | Synthetic traffic (dev and prod use the same client) | Secrets Manager `agent-ops/<env>/traffic` | <2027-02-09> |

Secrets last 90 days. Set a calendar reminder 14 days before each expiry. The exact date is shown in Entra, App registrations, the client, Certificates & secrets.

## Getting a token (to test or operate)

Run from `~/agent-ops`. The secret is typed at a hidden prompt and never pasted into chat or files.

```bash
export TENANT_ID="<tenant id>"
export API_CLIENT_ID="<agent-ops-api client id>"
read -rsp "Client secret: " CLIENT_SECRET; echo
source scripts/get-token.sh "<client id>" "$CLIENT_SECRET"
```

It prints the roles, audience and issuer. The roles must match the client, the audience must equal the API client ID, and the issuer must end in `/v2.0`. If the audience starts with `api://` or the issuer contains `sts.windows.net`, the API is issuing v1 tokens: set `requestedAccessTokenVersion` to 2 in the `agent-ops-api` manifest.

## Granting access to a new system

1. Requester explains which system and why, and which role it needs. Default to **Viewer**.
2. The system owner registers a client app in Entra (or uses an existing one). One identity per system.
3. Entra admin center, App registrations, the client app, API permissions, Add a permission, APIs my organization uses, `agent-ops-api`, Application permissions, pick the role, **Grant admin consent**.
4. Record the grant (who, what, why, date) in the table above.

## Removing access

Same screen: remove the permission and revoke admin consent. Also delete the client app's secret if the app is being retired.

## Rotating a client secret (before it expires)

1. Client app, Certificates & secrets, New client secret (90 days). Copy the **Value** immediately, it is shown once.
2. Update where it is stored: `gh secret set SMOKE_CLIENT_SECRET` (viewer), or both environments for the generator:
   ```bash
   read -rp "Traffic generator client ID: " GEN_ID
   ```
   ```bash
   read -rsp "New generator secret: " GEN_SECRET; echo
   ```
   ```bash
   for ENV in dev prod; do
     aws secretsmanager put-secret-value --secret-id agent-ops/$ENV/traffic --secret-string "$(jq -n --arg i "$GEN_ID" --arg s "$GEN_SECRET" '{CLIENT_ID:$i, CLIENT_SECRET:$s}')"
   done
   unset GEN_ID GEN_SECRET
   ```
3. Wait about 6 minutes (secret cache), confirm the next smoke test or generator run succeeds, then delete the old secret.

## Monthly access review

Entra admin center, Enterprise applications, `agent-ops-api`, Users and groups / Permissions. Every assignment must still have an owner and a reason. Remove anything that does not.

## Alarm: `access-denied-spike`

1. Find out who is being denied (Logs Insights on `/aws/lambda/agent-ops-<env>`):
   ```
   fields @timestamp, caller, role, route
   | filter message = "access_denied"
   | stats count() by caller, role, route
   ```
   `caller` is the client app ID (`azp`). Look it up in Entra, Enterprise applications.
2. Then decide:
   - A known system with the wrong role: the owner raises an access request.
   - An unknown app ID: treat it as a security event, tell Security, and consider disabling that app in Entra.
3. Rejected tokens (expired, wrong audience, no token) never reach the Lambda. Check the API access logs (`/aws/apigateway/agent-ops-<env>`) for `status = 401`.
4. If the **traffic generator** is getting 401s, its secret has probably expired or was entered wrongly: rotate it (above). Only the synthetic canary alarm notices this, because 401s stop at API Gateway.

## Verified behaviour (Day 7)

- No token: 401. Viewer on `POST /triage`: 403 with `AccessDenied` recorded. Operator on `POST /triage`: 200.
- The pipeline smoke test logs in as the viewer, so CI has only read access.
