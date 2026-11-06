# Service level objectives

| SLO | Target | Measured over | Why this number |
|---|---|---|---|
| **Availability** | 99% of valid triage requests succeed (no 5xx) | 6-hour windows | Failed triage means a member waits longer; 99% leaves room for upstream (Claude) blips |
| **Latency** | 90% of triage requests finish within 10 seconds | 5-minute windows, 2 in a row | Support agents and calling systems should not wait noticeably |

## Error budget

99% availability allows **1 failed request in every 100**. During the operating period
(~100 requests/day) that is about 1 failure per day. If the budget is spent, stop
shipping changes and fix reliability first.

## Not SLOs, but watched

| Signal | Alarm when |
|---|---|
| Live accuracy (reviewer feedback) | below 80% over 6 hours (min 10 reviews) |
| Human-review rate | above 50% over 6 hours |
| Estimated AI cost | above the daily limit for the environment |

## Out of scope

- Salesforce availability: a Salesforce outage queues Cases (no data loss) and has its own alarm.
- Time for a human to review a [REVIEW] Case: that's a support-team SLA, not this service.