# Runbook 01: Claude API outage or degraded AI service

**Triggered by:** `agent-ops-<env>-triage-errors`, `agent-ops-<env>-slo-success-rate`, `agent-ops-<env>-slo-latency-p90`, and the synthetic canary alarm
**Severity:** High in prod (members get no triage), Low in dev
**Owner:** AI Ops on-call
**Last drilled:** 2026-11-05 (invalid key). Detected in 37 s, diagnosed in 4 min 35 s, fixed in 2 min, service recovered 6 min 53 s after the fix. See `docs/incidents/2026-11-05-revoked-claude-key.md`.

## Read this first: how this failure behaves

- **Until the kill switch is on, failed requests are lost to the caller.** If the Claude call fails (for example HTTP 401), `POST /triage` returns HTTP 500. The request is **not** queued and **not** sent to human review. The caller has to retry. Invalid AI *output* is different: that is retried once and then routed to a human automatically. An AI *outage* is not, so containing it quickly (step 2) matters.
- **An OK email does not mean it is fixed.** `triage-errors` uses a 5-minute window and errors only happen when requests are sent, so it can return to OK between failures while the problem is still there. Always confirm recovery with a real test message (step 5).
- **Alarms clear slowly.** After a fix, `triage-errors` clears within minutes, the 1-hour canary alarm after about an hour, and `slo-success-rate` (6-hour window) can take hours. That is normal.
- **Caching delays both the failure and the fix.** The Lambda caches secrets for 5 minutes and settings (kill switch, threshold) for 30 seconds. After changing the key, wait about 6 minutes before testing.
- **Logs Insights shows UTC by default.** South Africa is UTC+2, so 20:16 local is 18:16 UTC. If a search comes back empty, check the time range and timezone first.
- **One alarm, several emails.** One cause usually triggers several alarms within seconds. That is alert noise, not several problems.

## 1. Confirm (5 min)

1. Open the CloudWatch dashboard `agent-ops-<env>` (region Europe London) and look at **Problems** and **Latency**.
2. Find the error in the logs (CloudWatch, Logs Insights, log group `/aws/lambda/agent-ops-<env>`):
   ```
   fields @timestamp, message, error, status, detail
   | filter level = "error"
   | sort @timestamp desc
   | limit 20
   ```
3. Read the `error` field:

   | Error | Meaning | Go to |
   |---|---|---|
   | `claude_http_401` | API key invalid, revoked or rotated | Step 3 |
   | `claude_http_429` | Rate limit or spend limit reached | Step 4 |
   | `claude_http_5xx` / `deadline_exceeded` | Anthropic is degraded | Step 2 |
   | `ResourceNotFoundException` / `AccessDenied` on SSM or Secrets Manager | Config or secret missing | Check the secret and parameters exist |

4. Check https://status.anthropic.com.

## 2. Contain: switch on the kill switch

Every message then goes to human review and is still recorded as a Salesforce Case marked `[REVIEW]` and untriaged. Nothing is lost from this point.

```bash
aws ssm put-parameter --name /agent-ops/<env>/ai_enabled --value false --overwrite
```

It takes effect within about 35 seconds (tested). Confirm with `GET /status`, which now needs a token (see "Calling the API" below): `"aiEnabled": false`.

## 3. Fix: invalid API key

1. Create a new key in the Anthropic Console. Each environment has its own key (`agent-ops-dev`, `agent-ops-prod`), and CI has a third (`agent-ops-ci`).
2. Update the secret, keeping the Salesforce values. Run the `read` line on its own:
   ```bash
   read -rsp "New Claude key: " KEY; echo
   ```
   ```bash
   CURRENT=$(aws secretsmanager get-secret-value --secret-id agent-ops/<env>/app --query SecretString --output text)
   aws secretsmanager put-secret-value --secret-id agent-ops/<env>/app --secret-string "$(echo "$CURRENT" | jq --arg k "$KEY" '.ANTHROPIC_API_KEY=$k')"
   unset KEY CURRENT
   ```
3. Wait about 6 minutes for the cache to expire (or redeploy).
4. If the CI eval gate fails with `claude_http_401`, the CI key is the problem, not the service: `gh secret set ANTHROPIC_API_KEY`.

## 4. Fix: rate or spend limit

1. Check usage and limits in the Anthropic Console.
2. Raise the limit if the traffic is real. If not, check the API access logs for an unusual caller or IP, and runbook 06 for cost.

## 5. Recover: turning AI back on

```bash
aws ssm put-parameter --name /agent-ops/<env>/ai_enabled --value true --overwrite
```

Wait about 35 seconds, then send a test message (see "Calling the API"). It should be triaged normally, with a category and a cost above zero. Watch the dashboard for 15 minutes and confirm the alarms return to OK. The slow alarms (canary, success rate) may take longer.

## 6. Afterwards

- Escalate to Anthropic support if the outage was on their side and lasted more than 30 minutes.
- Write an incident report in `docs/incidents/` using `TEMPLATE.md`: timeline, impact (failed requests, messages that went to humans), cause, follow-ups.
- Check the SLO: how much of the error budget did this use?
- Known gap: there is no automatic fallback to human review when the provider is down. Today the kill switch is the manual response.

## Calling the API (authentication is on)

Run from `~/agent-ops`. Each secret is typed at a hidden prompt.

```bash
export TENANT_ID="<tenant id>"
export API_CLIENT_ID="<agent-ops-api client id>"
API_URL=$(aws apigatewayv2 get-apis --query "Items[?Name=='agent-ops-<env>'].ApiEndpoint" --output text)
read -rsp "Operator secret: " OPERATOR_SECRET; echo
source scripts/get-token.sh "<operator client id>" "$OPERATOR_SECRET"
curl -s -H "Authorization: Bearer $TOKEN" "$API_URL/status" | jq '{env, aiEnabled, functionVersion, promptVersion}'
API_URL=$API_URL bash scripts/triage.sh "My card isn't working in the app"
```
