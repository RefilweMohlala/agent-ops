# Runbook 02: Salesforce integration degraded

**Triggered by:** `agent-ops-<env>-salesforce-failures`, `agent-ops-<env>-crm-dlq-not-empty`
**Impact:** Cases are **delayed, not lost**. Failed Cases go to the retry queue, are retried for about 30 minutes (first retry after about 1 minute, then roughly every 5 minutes, 6 tries), then parked in the dead-letter queue (DLQ). The caller still gets HTTP 200 with `crmStatus: queued`.
**Last drilled:** 2026-11-07 (a validation rule added to Case). Alarm fired in 2 min in both dev and prod, cause found in 2 min, rule deactivated 5 min later, queued Cases appeared 3 min after that. See `docs/incidents/2026-11-07-salesforce-validation-rule.md`.

**Remember:** dev and prod share one Salesforce org in this project, so a Salesforce-side problem hits **both** environments and both send alarms.

## 1. Confirm

Logs Insights on `/aws/lambda/agent-ops-<env>` (set the time range in UTC, South Africa is UTC+2):

```
fields @timestamp, message, error, attempt
| filter message in ["salesforce_failed", "crm_retry_failed", "crm_retry_ok"]
| sort @timestamp desc
| limit 30
```

| Error | Likely cause | Fix |
|---|---|---|
| `sf_token_http_400` with `invalid_client` | Consumer key or secret changed | Step 2 |
| `sf_token_http_400` with `invalid_grant` / user errors | The "Run As" user is inactive, locked or lost its permissions | Step 3 |
| `sf_case_http_400` with `FIELD_CUSTOM_VALIDATION_EXCEPTION` (for example "Type is required") | A validation rule or required field was added on Case | Step 4 |
| `sf_case_http_400` with `STORAGE_LIMIT_EXCEEDED` | The org is full | Setup, Mass Delete Records, Cases |
| `sf_case_http_403` | The integration user lost access to Case | Step 3 |
| `sf_case_http_5xx` / timeouts | Salesforce degraded | Check https://status.salesforce.com, wait or escalate |
| Token errors right after changing `SF_LOGIN_URL` | The URL is wrong: it must be the My Domain URL starting with `https://` and ending in `.my.salesforce.com`, with no trailing slash. A redirect (HTTP 302) means `https://` is missing or the address is a `lightning.force.com` or setup address | Step 2 |

The code already retries once on 401 with a fresh token, so expired tokens fix themselves.

## 2. Rotate or correct the client credentials

1. Salesforce, Setup, External Client App Manager, click `Agent Ops`, Settings tab, OAuth Settings, **Consumer Key and Secret**. Salesforce emails a verification code first.
2. Update `SF_CLIENT_ID`, `SF_CLIENT_SECRET` and `SF_LOGIN_URL` in the secret for **each** environment, keeping the Claude key. Run the `read` line on its own:
   ```bash
   export SF_LOGIN_URL="https://<your-domain>.my.salesforce.com"
   export SF_CLIENT_ID="<consumer key>"
   ```
   ```bash
   read -rsp "Consumer secret: " SF_CLIENT_SECRET; echo
   ```
   ```bash
   for ENV in dev prod; do
     CURRENT=$(aws secretsmanager get-secret-value --secret-id agent-ops/$ENV/app --query SecretString --output text)
     aws secretsmanager put-secret-value --secret-id agent-ops/$ENV/app --secret-string "$(echo "$CURRENT" | jq --arg i "$SF_CLIENT_ID" --arg s "$SF_CLIENT_SECRET" --arg u "$SF_LOGIN_URL" '.SF_CLIENT_ID=$i | .SF_CLIENT_SECRET=$s | .SF_LOGIN_URL=$u')"
   done
   unset CURRENT SF_CLIENT_SECRET
   ```
3. Wait about 6 minutes for the secret cache to expire.
4. To test credentials by hand, request a token from `$SF_LOGIN_URL/services/oauth2/token` with `grant_type=client_credentials`. Use `curl -sS -w "\nHTTP status: %{http_code}\n"` so errors are visible: a silent `-s` call hides failures.

## 3. Check the integration user

Setup, Users, the "Run As" user (currently the admin who created the app): active, not locked, with a profile or permission set that has API Enabled and Create/Read on Case.

## 4. Field or validation changes

1. Find the rule: Setup, Object Manager, Case, Validation Rules. The drill rule was `Type_Required`.
2. To fix it quickly, open the rule, click Edit, untick **Active**, Save. You do not need to delete it.
3. Then agree the change with the Salesforce admin: either roll it back, or update `buildCase()` in `src/index.mjs` through a normal PR so the field is set.

## 5. Watch the queue drain

Once the cause is fixed, queued Cases are created automatically within about 5 minutes. On the dashboard, **CRM reliability** should show `CrmRetrySucceeded` going up and nothing new in the DLQ. Check the Cases appear in Salesforce (App Launcher, Cases, All Open Cases). The alarm returns to OK after a full evaluation window with no failures (8 minutes after the fix in the drill).

## 6. Replay the dead-letter queue

*Documented but not yet drilled.* If the `crm-dlq-not-empty` alarm fired, some Cases gave up retrying. **After** the cause is fixed:

```bash
cd infra && terraform workspace select <env>
aws sqs start-message-move-task --source-arn "$(terraform output -raw crm_dlq_arn)"
```

This moves them back to the retry queue. Check the Cases appear in Salesforce and the alarm returns to OK. Messages stay in the DLQ for 14 days, so there is time, but do not leave them.

## 7. Last resort

If Salesforce will be down for days, switch the integration off so the queue does not fill with messages that will expire:

```bash
aws ssm put-parameter --name /agent-ops/<env>/salesforce_enabled --value false --overwrite
```

Triage results are then only in the API response. Tell the support team which period has no Cases, and turn it back on afterwards (`--value true`). This setting is an operational toggle: Terraform ignores its value, so a deploy will not reset it.

## 8. Afterwards

Write an incident report in `docs/incidents/` with real times and the number of messages queued. Follow-ups worth checking: a dedicated integration user, a Salesforce sandbox for dev, and agreeing Case schema changes with the org admin.
