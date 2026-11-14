# Operations report: agent-ops prod, 7 Nov 2026 to 13 Nov 2026

> Synthetic traffic and simulated reviewer feedback. Real infrastructure, real failures, real responses.

## Summary

Production ran for about six days (7 Nov, about 08:15 SAST, to 13 Nov 13:19 SAST) and triaged 628 requests. It met both service levels: 99.84% success against a 99% target, and a p90 latency of 4.75 s against a 10 s target. The most important thing I learned is that the retry queue made a flaky dependency invisible to members (21 Cases were queued and all were created, none dead-lettered), but my alarms were tuned to the dependency's blips and not to member impact, so a harmless problem produced 19 alarm emails.

I planned two weeks and stopped after six days, so there is no second-week change-management story in this report.

## Service level

| SLO | Target | Achieved | Error budget used |
|---|---|---|---|
| Success rate | 99% | 99.84% (628 of 629) | About 16% (1 failure of about 6.3 allowed) |
| p90 latency | under 10 s | 4.75 s overall, worst day 6.1 s | Not used up |

## Volume, quality and cost

| | Total / average |
|---|---|
| Requests triaged | 628 (about 100 a day) |
| Sent to human review | 123 (19.6%). Every one was a risk flag: legal threat, vulnerable customer, safety, data request |
| Live accuracy | 95.9% (627 reviews, 26 corrected) |
| Cases created / queued / dead-lettered | 559 created at once, 21 queued and then created, 0 dead-lettered. 48 requests came before Salesforce was switched on in prod |
| Total AI cost | $0.90 (Claude Console usage for all keys: about $1.13) |
| Cost per triage | about $0.0014, about $0.14 a day |
| Latency | p50 3.71 s, p90 4.75 s |

## Incidents

| Date | Type | Summary | Detection time | Time to recover | Report |
|---|---|---|---|---|---|
| 2026-11-07 | Planned drill | A Salesforce validation rule rejected every Case. Cases were queued and created automatically after the rule was deactivated | 2 min | 12 min | `docs/incidents/2026-11-07-salesforce-validation-rule.md` |
| 2026-11-09 | Unplanned | One request got an HTTP 503 from Anthropic and the agent returned a 500 | 1 min 22 s | Did not recur | `docs/incidents/2026-11-09-claude-api-503.md` |
| 2026-11-07 to 13 | Recurring (alarm noise) | 19 Salesforce calls timed out at 5 s. Each Case was created on retry. 18 extra alarms, no member impact | Within minutes | Each cleared in about 15 min | `docs/incidents/2026-11-salesforce-timeouts.md` |

## Changes shipped during operation

| Date | Change | Effect measured |
|---|---|---|
| 7 Nov | Synthetic traffic moved from dev to prod, which started the period | Baseline |
| 7 Nov | Rollback drill (marker added, rolled back, then reverted) | None on prod metrics. Rollback took 1 min 8 s in dev |
| 7 Nov (afternoon) | Salesforce switched on in prod by an operational setting, outside the pipeline by design | Cases created for every request after that. 48 earlier requests have none |
| 9 Nov | Entra ID JWT authentication switched on through the pipeline | No change in success rate. The traffic generator kept working with its own identity |
| 10 Nov | Runbooks, dependency map and README | No runtime effect |

No prompt or threshold change was shipped. I left the prompt unchanged on purpose.

## What I learned

- **Alert on member impact, not on a dependency's blips.** `salesforce-failures` fires on one failed call, so 19 slow calls produced 19 alarm cycles even though every Case was created a minute later. That trains people to ignore the alarm.
- **The retry queue and dead-letter queue worked as designed.** 21 queued, 21 recovered, 0 dead-lettered, and both queues were empty at the end.
- **A short-window SLO alarm is fragile at low volume.** At about 25 requests per 6-hour window, one failure is a 4% failure rate, so one Anthropic 503 turned the success-rate alarm red for six hours while the real month-level success rate was 99.84%.
- **A provider error is a real gap.** One 503 meant one lost request. With a longer outage, every request would return a 500 until someone switched the kill switch on.
- **Review routing behaved as intended.** All human reviews came from risk flags, and none came from low confidence or invalid AI output.
- **Cost is predictable.** About 100 triages a day cost about $0.14.

## What I'd do differently in a real deployment

- Alarm on error-budget burn rate and on persistent CRM problems, not single events.
- Fall back to human review automatically when the AI provider fails.
- Measure Salesforce latency and decide the timeout from data. Move the CRM write behind the queue if needed.
- Use a Salesforce sandbox for dev and a dedicated integration user in prod.
- Run for the full two weeks and ship one measured change, such as a prompt or threshold tweak, with before and after numbers.
- Add a staging environment and a minimum-volume rule on the ratio alarms.
