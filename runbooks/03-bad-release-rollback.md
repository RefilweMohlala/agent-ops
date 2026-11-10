# Runbook 03: Bad release (code or prompt), rollback and pipeline problems

**Triggered by:** `agent-ops-<env>-lambda-errors`, `agent-ops-<env>-invalid-ai-output`, reports of bad triage after a deploy, or a failed pipeline run.
**Last drilled:** 2026-11-07 (rollback in dev took 1 min 8 s, of which moving the alias took about 6 s).

## 1. Was it the last deploy?

- GitHub, Actions, Deploy: when did the last run finish?
- `GET /status` shows `functionVersion` and `promptVersion` (it needs a token, see runbook 01, "Calling the API").
- If the problems started right after the deploy, assume the release is the cause.

## 2. Roll back (under 2 minutes)

**Option A: GitHub (preferred, leaves an audit trail)**
Actions, **Rollback**, Run workflow, choose the environment, leave the version blank for "previous". The log shows the move, for example "Rolled back agent-ops-dev: live alias moved from v2 to v1". It refuses to run if there is no earlier version.

**Option B: CLI (if GitHub is unavailable)**

```bash
FN=agent-ops-<env>
aws lambda get-alias --function-name $FN --name live --query FunctionVersion --output text
aws lambda update-alias --function-name $FN --name live --function-version <previous-version>
```

## 3. Verify

- `GET /status` shows the older `functionVersion`.
- Send a test message. Alarms return to OK within about 10 minutes (the 1-hour and 6-hour alarms take longer).

## 4. Make it permanent

The rollback only moves the alias. Git still contains the bad commit, and the next deploy from `main` would ship it again, so:

1. `git revert <bad-commit>` on a branch, then a PR.
2. Let CI (unit tests, eval gate, plan) pass, merge, approve prod, and let the pipeline redeploy.
3. Add a test or eval case that would have caught the problem.

Lambda version numbers only go up and are never reused. After rolling back from v2 to v1, the revert deploy creates v3 with the old code. Confirm version numbers from logs, not memory.

## Prompt-specific problems

If triage quality dropped but nothing is crashing, it is usually the prompt. See runbook 06. The eval gate blocks a prompt that breaks categories (drilled on Day 7 with a deliberately sabotaged refund category).

## Pipeline troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No Deploy run after a merge | The PR is not merged (green checks only make it mergeable) | `gh pr list`, then `gh pr merge <number> --squash --delete-branch` |
| A new Deploy run stays queued | An older run is waiting for prod approval, and only one Deploy runs at a time | Actions, Deploy: approve or reject the older run |
| No approval prompt for prod | No required reviewer on the `prod` environment | Settings, Environments, prod, Required reviewers, add yourself, Save |
| `gh pr checks` says "no checks reported" right after a push | Checks have not registered yet | Wait about 20 seconds and run it again |
| Merge refused: base branch policy | Required checks have not passed | Wait for green checks. Do not use `--admin`, it defeats the gate |
| Only some files reached the PR | `git add .` was run from a subfolder | Run `git add .` from `~/agent-ops` and check `git status` |
| CI eval fails with `claude_http_401` | The CI key (GitHub secret `ANTHROPIC_API_KEY`) is invalid | Create a key and run `gh secret set ANTHROPIC_API_KEY` |
| Smoke test fails with 401 | The viewer secret changed or expired | `gh secret set SMOKE_CLIENT_SECRET` |
| "Not authorized to perform sts:AssumeRoleWithWebIdentity" | The role's trust rule does not match the token GitHub sends | See below |

### If the pipeline cannot assume its AWS role

This repository uses GitHub's immutable identity format, which includes numeric account and repository IDs, for example `repo:<owner>@<owner-id>/<repo>@<repo-id>`. The trust rule must match it exactly.

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
aws iam get-role --role-name agent-ops-gha-plan --query 'Role.AssumeRolePolicyDocument' --output json
```

Compare the `sub_claim_prefix` with the `sub` condition in the role. If they differ (for example the repository was renamed or recreated, so the IDs changed), update the `github_repo` default in `bootstrap/main.tf`, then:

```bash
cd bootstrap
terraform plan
terraform apply
```

The plan should show only the two role trust policies changing. Then re-run the failed job: `gh run rerun <run-id> --failed`.
