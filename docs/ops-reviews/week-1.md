# Weekly ops review: week 1 (7 Nov 2026 to 13 Nov 2026)

> Production, synthetic traffic and simulated reviewer feedback. Period: 7 Nov (about 08:15 SAST) to 13 Nov 13:19 SAST, about six days. I planned two weeks and stopped after six days, so this is the only weekly review.

## Numbers (prod)

| Metric | This period | Target | Notes |
|---|---|---|---|
| Requests | 628 triaged (629 including 1 failed) | | About 100 a day, quieter at night |
| Success rate | 99.84% (628 of 629) | 99% or better | One failure: an Anthropic 503 on 9 Nov. About 16% of the error budget used (1 of about 6.3 allowed) |
| p90 latency | 4.75 s (worst day 6.1 s) | under 10 s | p50 was 3.71 s |
| Live accuracy | 95.9% (627 reviews, 26 corrected) | 80% or better | Simulated reviewer |
| Human-review rate | 19.6% (123 messages) | under 50% | Every one was a risk flag. None for low confidence or invalid AI output. Daily range 15.6% to 23.3% |
| AI cost | $0.90 | under $7 | About $0.0014 per triage, about $0.14 a day |
| Cases created / queued / dead-lettered | 559 created at once, 21 queued and then created, 0 dead-lettered | 0 dead-lettered | A further 48 requests came before Salesforce was switched on in prod, so they have no Case |
| Alarms fired | 21 | | 19 `salesforce-failures`, 1 `triage-errors`, 1 `slo-success-rate` |

## Daily numbers (UTC days)

| Day | Requests | To humans | p90 latency | AI cost |
|---|---|---|---|---|
| 7 Nov (from about 08:15 SAST) | 88 | 20 | 4.21 s | $0.1256 |
| 8 Nov | 94 | 21 | 4.91 s | $0.1358 |
| 9 Nov | 96 | 19 | 5.24 s | $0.1373 |
| 10 Nov | 107 | 17 | 5.02 s | $0.1526 |
| 11 Nov | 96 | 15 | 6.09 s | $0.1369 |
| 12 Nov | 103 | 24 | 4.67 s | $0.1485 |
| 13 Nov (partial, to 13:19 SAST) | 44 | 7 | about 4.4 s | $0.0635 |

## Incidents

- 2026-11-07, planned drill: Salesforce validation rule. See `docs/incidents/2026-11-07-salesforce-validation-rule.md`.
- 2026-11-09, unplanned: one Claude API 503. See `docs/incidents/2026-11-09-claude-api-503.md`.
- 2026-11-07 to 13, recurring: 19 Salesforce timeouts caused 18 extra alarms with no member impact. See `docs/incidents/2026-11-salesforce-timeouts.md`.

## Where the AI got it wrong

26 corrections out of 627 reviews (4.1%). Top 3 mistake pairs from the "Where the AI gets it wrong" query:

| AI category | Correct category | Count |
|---|---|---|
| card_or_membership_issue | denied_entry | 26 |

## Decisions

- **Prompt: deliberately not changed.** The remaining mistakes are on messages that sit between two categories (for example an invoice request, which is both billing and a records request). Tuning `triage-v1` around single examples risks overfitting, and 95.9% is well above the 80% target.
- **Change next:** make the `salesforce-failures` alarm fire on problems that persist (failed retries or a non-empty dead-letter queue), not on one slow call.
- **Change next:** replace the 6-hour success-rate alarm, which breaches on a single failure at about 25 requests per window, with an error-budget burn-rate alarm.
- **Change next:** add an automatic fallback to human review when the AI provider fails, so one provider error does not turn into a lost request.
- **Investigate:** measure Salesforce response times to decide whether the 5-second timeout is too tight.
