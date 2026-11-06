# Incident: Invalid Claude API key (planned drill)

| | |
|---|---|
| **Date** | 2026-11-05 |
| **Environment** | dev |
| **Type** | Planned drill |
| **Severity** | Low (dev environment, synthetic traffic only) |
| **Duration** | 14 min 05 s from first failed request to recovery (21 min 41 s from the key change) |

## Summary
The Claude API key stored in Secrets Manager was deliberately replaced with an invalid value to rehearse detection, diagnosis and recovery. Triage requests began failing with HTTP 500, alarms fired within 37 seconds of the first failure, the cause was found in Logs Insights as `claude_http_401`, and the service recovered after the real key was restored. No real members were affected.

## Timeline (SAST)
| Time | Event |
|---|---|
| 20:09:08 | Key broken: secret `agent-ops/dev/app` overwritten with an invalid Claude key |
| 20:16:44 | First failed request (HTTP 500 `internal_error`) |
| 20:17:21 | First alarm fired (detection time: 37 seconds) |
| 20:17:24 | Second alarm fired |
| 20:17:37 | Third alarm fired |
| 20:21:56 | Cause found in Logs Insights: `claude_http_401` (Errors query) |
| 20:23:56 | Fix applied: real key restored with `put-secret-value` |
| 20:30:49 | Service recovered: normal triage result returned |
| 20:32 | `triage-errors` returned to OK |
| 21:17 | `synthetic-canary` returned to OK |
| 02:17 (06 Nov) | `slo-success-rate` returned to OK |

## Response metrics
| Measure | Time |
|---|---|
| Time to detect (first failure to first alarm) | 37 s |
| Time to diagnose (first alarm to cause found) | 4 min 35 s |
| Time to apply fix (cause found to fix applied) | 2 min 00 s |
| Time to recover (fix applied to service recovered) | 6 min 53 s |
| Total outage (first failure to recovery) | 14 min 05 s |

## Impact
Dev environment only, with synthetic test traffic and my own manual requests. 3 requests returned HTTP 500 during the incident. Because the failure happened at the Claude call, these requests errored out before any routing decision: none were sent to human review, no CRM Case was created, and no `triage_complete` line was written, so they are visible only as `triage_failed` errors, in the API access log (status 500) and in the generator's logs. The callers could retry. No data was lost or exposed: logs contain decisions and numbers, never message text.

## Root cause
The Claude API key in Secrets Manager was replaced with an invalid value as part of the drill. Claude rejected every call with HTTP 401, and the agent returned 500 errors. The first failure came about 7.5 minutes after the change, which is consistent with the Lambda's 5-minute secret cache: the old key kept working until the cache expired.

## What went well
- Detection was fast: the first alarm fired 37 seconds after the first failure, before anyone looked.
- The saved Errors query pinpointed `claude_http_401` within about 4.5 minutes of the first alarm.
- The fix took about 2 minutes and needed no redeploy, because credentials live in Secrets Manager and not in code.
- The key never appeared in code, Terraform state or git, and the temporary key file was deleted straight after use.
- Logs let me diagnose the problem without exposing any message content.

## What didn't go well
- **Alert noise:** one root cause produced three alarms within 16 seconds (20:17:21 to 20:17:37).
- **Slow recovery:** it took 6 min 53 s from the fix to a working service, because of the 5-minute secret cache.
- **Alarms fire fast but clear slowly.** After recovery at 20:30:49, `triage-errors` (5-minute window) cleared at 20:32, but `synthetic-canary` (1-hour window) took until 21:17 (about 46 minutes) and `slo-success-rate` (6-hour window) until 02:17 on 06 Nov (about 5 h 46 min), because the failures stayed inside their windows. A short-window alarm can also show OK between failures while a problem persists, since errors only occur when requests are sent and the generator runs every 20 minutes, so an OK is not proof of a fix.
- **Runbook 01 did not exist yet.** The alarm descriptions point to it, but it is written on Day 8.

## Follow-ups
| Action | Owner | Status |
|---|---|---|
| Write runbook 01 with the 401 path and the line "after rotating a key, wait 5 minutes" | Refilwe | Open (Day 8) |
| Consider reducing alert noise (for example route the canary and SLO alarms to a lower-urgency channel) | Refilwe | Open |
| Record the OK times for the three alarms in the timeline above | Refilwe | Done |
| Keep the 5-minute secret cache, and document the trade-off: fewer Secrets Manager calls against slower key changes | Refilwe | Open |
| Decide how a Claude outage should behave: today a provider failure returns 500 and the request is not queued or sent to human review (the kill switch is the manual mitigation). Consider an automatic fallback to human review | Refilwe | Open |