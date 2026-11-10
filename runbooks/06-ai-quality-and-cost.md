# Runbook 06: AI quality drop or cost anomaly

**Triggered by:** `agent-ops-<env>-live-accuracy`, `agent-ops-<env>-human-review-rate`, `agent-ops-<env>-daily-ai-cost`
**Severity:** Medium. Members are still served (risky or uncertain messages go to humans), but quality or budget is at risk.

## First: is the sample big enough?

The `human-review-rate` alarm has **no minimum volume** today, so a handful of messages can trip it. On 2026-11-07 the dev alarm fired at 60% on a sample of 5 messages (3 to humans) while prod was healthy at 19% (6 of 32). Always check the volume per environment before treating it as real:

```
filter message = "triage_complete"
| stats count() as total, sum(route = "human_review") as to_humans by env
```

Run it on `/aws/lambda/agent-ops-dev` and `/aws/lambda/agent-ops-prod` with the alarm's 6-hour window (in UTC). If `total` is small, it is noise: note it and move on. Planned fix: make the ratio alarm ignore windows with fewer than 10 requests, as the live-accuracy alarm already does.

## Part A: quality (live accuracy down, or human-review rate up)

### 1. What changed?

- **A deploy?** GitHub, Actions, Deploy. Did `promptVersion`, `model_id` or `confidence_threshold` change recently? (`GET /status` shows them.)
- **The model?** Check the Anthropic changelog and status page.
- **The traffic?** A new kind of complaint the prompt does not cover (a new product, a new airport).

### 2. Where is it wrong?

```
filter message = "feedback" and override = 1
| stats count() as mistakes by aiCategory, correctCategory
| sort mistakes desc
```

```
filter message = "triage_complete"
| stats count() as total, sum(route = "human_review") as to_humans, avg(confidence) as avg_conf by env, category, reason
| sort to_humans desc
```

- Mistakes concentrated in one pair (for example `other` for `refund_or_billing`) point to a prompt wording problem.
- Many `low_confidence` means the threshold may be too strict, or the messages are genuinely ambiguous.
- Many `invalid_ai_output` means an output format problem (also see runbook 03).
- Most human-review cases should show a risk flag reason (legal threat, safety, vulnerable customer, data request, media threat). Those are working as designed.

**Known edge case:** eval case E09 (a request for an invoice) is labelled `refund_or_billing` but the model says `account_or_data_request`. It is genuinely ambiguous and was deliberately left as is (the eval scores 95%, 19 of 20) to avoid overfitting the prompt to a single example.

### 3. Contain

- If a recent prompt or model change caused it, **roll back** (runbook 03).
- If quality is bad enough to harm members (wrong draft replies being sent), use the **kill switch** (runbook 01, step 2). Everything goes to humans.
- If it is only "more goes to human review", that is the safe failure mode. Tell the support team to expect more `[REVIEW]` Cases while you fix it.

### 4. Fix through the normal process

1. Add the failing examples to `evals/cases.json` (labelled correctly).
2. Create a new prompt version (`triage-v2.txt`) and update `PROMPT_VERSION`.
3. PR: the eval gate must pass on the old **and** the new examples, then deploy.
4. Watch live accuracy for 24 hours after the release.

The eval gate has been proven: a deliberately sabotaged prompt failed CI and the merge stayed blocked.

## Part B: cost (daily AI cost alarm)

Normal cost is about $0.0014 per triage, so around $0.15 to $0.25 a day at the generator's volume (roughly 100 messages a day in prod).

### 1. Is it volume or cost per request?

```
filter message = "triage_complete"
| stats count() as requests, sum(costUsd) as cost, avg(costUsd) as cost_per_request by bin(1h), env, source
```

- **More requests:** is the traffic real? Check `source` (synthetic vs api) and the API access logs for an unusual caller or IP. If it is abuse, lower the API Gateway throttle or remove that caller's access (runbook 04).
- **Higher cost per request:** more self-correction retries (look for `invalid_ai_output`), longer messages, or a more expensive model. Check `model_id` and the prices in the tfvars.

### 2. Contain

- Lower `throttle_rate_limit` in the tfvars (PR), or
- As a last resort, the kill switch: messages go to humans and cost drops to zero.

### 3. Afterwards

Write an incident report. If the alarm threshold was simply too low for normal traffic, change `daily_cost_alarm_usd` through a PR and record why. Other cost guards: the AWS budget alert and the spend limit on each Anthropic key.
