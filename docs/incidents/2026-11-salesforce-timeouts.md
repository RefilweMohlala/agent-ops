# Finding: recurring Salesforce timeouts caused 18 extra alarms (alarm noise)

| | |
|---|---|
| **Date range** | 2026-11-07 to 2026-11-13 |
| **Environment** | prod (dev shares the same Salesforce org) |
| **Type** | Recurring, self-healing |
| **Severity** | Low (no member impact) |

## Summary
Over six days, 19 Salesforce calls exceeded the client's 5-second timeout ("The operation was aborted due to timeout"). Every failed Case went to the retry queue and was created on a retry, and the dead-letter queue stayed empty. The `salesforce-failures` alarm fires on a single failure in 5 minutes, so it fired 19 times in total (1 from the 7 Nov drill and 18 from these timeouts). Each cycle cleared about 15 minutes later.

## Evidence
- 21 `salesforce_failed` log lines: 19 timeouts and 2 validation-rule errors from the 7 Nov drill.
- `crmStatus`: 559 created, 21 queued, 48 disabled (before Salesforce was switched on).
- On 13 Nov the dead-letter queue and the retry queue both held 0 messages.
- Alarm history shows 19 OK to ALARM transitions on `agent-ops-prod-salesforce-failures`, each followed by ALARM to OK about 15 minutes later. They came in the minutes after generator runs, spread across day and night.

## Likely cause
Occasional slow responses from the Salesforce Developer Edition org (shared infrastructure). I did not collect Salesforce-side evidence, so this is not confirmed.

## Impact
None for members: every Case was created within a few minutes. The cost is alert fatigue. Eighteen emails about harmless blips teach people to ignore the alarm.

## What went well
- The retry queue absorbed every failure with no human action.
- No Case was lost.

## What didn't go well
- The alarm measures a dependency's blips and not member impact.
- I only noticed the pattern when reviewing the alarm history for the operations report.

## Follow-ups
| Action | Owner | Status |
|---|---|---|
| Alert on persistent problems (failed retries, or a non-empty dead-letter queue) instead of a single failure | Refilwe | Open |
| Log Salesforce response times, and decide the timeout from the p99 | Refilwe | Open |
| Use a Salesforce sandbox for dev so dev traffic cannot add to this | Refilwe | Open |
| Add a "timeouts are usually harmless if the DLQ is empty" note to runbook 02 | Refilwe | Open |
