# Incident: Salesforce validation rule blocks Case creation (planned drill)

| | |
|---|---|
| **Date** | 2026-11-07 |
| **Environment** | dev and prod (shared Salesforce org) |
| **Type** | Planned drill |
| **Severity** | Low (no member impact, Cases delayed not lost) |
| **Duration** | 12 min from rule activation to Cases appearing (17 min to the alarms clearing) |

## Summary
To rehearse a Salesforce-side change breaking the integration, a validation rule (`Type_Required`) was added to the Case object. Every Case the agent tried to create was rejected, so the Cases were routed to the SQS retry queue, and the `salesforce-failures` alarms fired in both dev and prod within 2 minutes, because the two environments share one Salesforce org. The cause was found in Logs Insights, the rule was deactivated, and the queued Cases were created automatically by the retry worker. Nothing was lost.

## Timeline (SAST)
| Time | Event |
|---|---|
| 16:14 | Validation rule `Type_Required` activated in Salesforce |
| 16:15 | First message queued (HTTP 200, `crmStatus: queued`) |
| 16:16 | Alarms fired in both dev and prod (2 minutes after the rule was activated) |
| 16:18 | Cause found in Logs Insights: `sf_case_http_400`, "Type is required" |
| 16:23 | Fix applied: rule deactivated in Salesforce |
| 16:26 | Queued Cases appeared in Salesforce on their own (`CrmRetrySucceeded`) |
| 16:31 | Alarms returned to OK |

## Response metrics
| Measure | Time |
|---|---|
| Time to detect (rule activated to alarm) | 2 min |
| Time to diagnose (alarm to cause found) | 2 min |
| Time to apply fix (cause found to rule deactivated) | 5 min |
| Time to recover (fix to Cases appearing) | 3 min |
| Alarm clearing (fix to OK) | 8 min |
| Total (rule activated to Cases appearing) | 12 min |

## Impact
Impact on members was zero. 3 messages were queued while the rule was active, and all of them became Cases after the rule was deactivated. Before the retry queue existed, each of these would have returned a 502 and the message would have been lost. Because dev and prod share one Salesforce org, one change in Salesforce affected both environments at once, and both sent alarms.

## Root cause
The validation rule required the Case `Type` field, and `buildCase()` does not set it, so Salesforce rejected every Case with HTTP 400. This is a change in a shared external dependency that the agent did not control.

## What went well
- The retry queue absorbed the failures: callers still got a 200, and no complaint was lost.
- Alarms fired in both environments within 2 minutes, and diagnosis took another 2 using the saved Errors query.
- Recovery needed no redeploy and no manual replay. Once the rule was deactivated, the queued Cases were created automatically.

## What didn't go well
- The fix took 5 minutes after the cause was known, because I had to look up where to deactivate a validation rule in Salesforce. A runbook with the exact steps would shorten this.
- The alarms took 8 minutes to clear after the fix. They only clear once a full evaluation window passes without a failure: the Cases were created at 16:26 and the 5-minute window ended at 16:31.
- Dev and prod share one Salesforce org, so a dev experiment reaches prod.

## Follow-ups
| Action | Owner | Status |
|---|---|---|
| Write runbook 02 with the validation-rule path and the exact Salesforce steps to deactivate a rule | Refilwe | Open (Day 8) |
| Use a separate Salesforce sandbox for dev, so dev experiments cannot affect prod | Refilwe | Open |
| Use a dedicated integration user with an API-only licence and a permission set limited to creating and reading Cases | Refilwe | Open |
| Agree Salesforce schema changes with the org admin, and update `buildCase()` when a field becomes required | Refilwe | Open |