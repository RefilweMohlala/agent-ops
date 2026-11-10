# Dependency map

What the agent depends on, what happens when each one fails, and where to look.

| Dependency | Used for | If it fails | Detected by | Runbook |
|---|---|---|---|---|
| **Anthropic Claude API** (one key per environment, plus a CI key) | Triage and draft reply | Invalid output: retried once, then routed to human review. **Provider down or key rejected: `POST /triage` returns 500 and the request is not queued** (the kill switch is the manual response) | `triage-errors`, `invalid-ai-output`, SLO alarms, canary | 01 |
| **Salesforce** (External Client App, OAuth client credentials). **Dev and prod share one org** | Case creation | Cases are queued and retried (about 30 minutes), then parked in the DLQ. Nothing is lost. A change in Salesforce hits both environments | `salesforce-failures`, `crm-dlq-not-empty` | 02 |
| **AWS SQS** (retry queue and DLQ) | Holding Cases while Salesforce is down | If SQS AND Salesforce both fail: API returns 502 | `triage-errors`, Lambda errors | 02 |
| **Microsoft Entra ID** (app registrations: `agent-ops-api`, operator, viewer, traffic generator) | Issues JWTs and app roles | Callers cannot get tokens. API returns 401. Expired client secrets (90 days) cause the same | API access logs, smoke test, canary | 04 |
| **AWS API Gateway JWT authorizer** | Validates tokens before the Lambda | Bad or missing tokens get 401 and never reach the Lambda, so only the canary and the access log notice a generator failure | Canary, API access logs | 04 |
| **AWS Secrets Manager** `agent-ops/<env>/app`, `/traffic` | Claude, Salesforce and generator credentials. Cached for 5 minutes | Every request returns 500 / the generator cannot log in | `triage-errors`, canary | 01, 04 |
| **AWS SSM Parameter Store** `/agent-ops/<env>/*` | Kill switch, Salesforce switch, threshold, model ID, prices. Cached for 30 seconds | Every request returns 500 | `triage-errors` | 01 |
| **AWS Lambda** `agent-ops-<env>:live` | Runs the agent and the retry worker | API returns 5xx | `lambda-errors` | 03 |
| **AWS API Gateway** (HTTP API) | Endpoint, throttling | Endpoint unreachable | Smoke test, canary | 03 |
| **EventBridge and the traffic Lambda** | Synthetic traffic, simulated reviewer and canary (every 20 minutes, prod only during the operating period) | No traffic: dashboards go quiet, quality metrics stop | Dashboard (no data), manual daily check | 04 |
| **CloudWatch and SNS** | Logs, metrics, alarms, email. SNS email subscriptions must be confirmed | We stop seeing problems (silent failure) | Manual daily check | none |
| **GitHub Actions and AWS OIDC** | Deployments, rollback. Trust is tied to the repository's identity (owner and repository IDs, GitHub's immutable format) | Cannot deploy (the running service is unaffected). If the repository is renamed or recreated the IDs change and the trust rule must be updated | Failed workflow run | 03 |
| **Terraform state** (S3, versioned) | Source of truth for infrastructure | Cannot plan or apply | Failed workflow run | Restore a previous S3 object version |

## Things that are shared between environments

- One Salesforce org for dev and prod.
- One Entra traffic-generator client (each environment holds its own copy of the secret).
- One AWS account and one Terraform state bucket (separate workspaces and state files).

## Data flow and data protection

- Member text is **redacted** (emails, card numbers, phone numbers) before it goes to Claude, Salesforce, the retry queue or the logs.
- Logs record decisions and metadata only, never the message text.
- The retry queue holds redacted messages for up to 4 days (DLQ: 14 days), encrypted at rest, only while Salesforce is unavailable.
- Secrets are only in Secrets Manager. Terraform manages the containers but never the values.
- Region: eu-west-2 (London).
