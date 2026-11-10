# Runbook 05: Decommission an agent environment

Use this when an environment (or the whole agent) is being retired. Nothing here has been run yet: it is a documented procedure.

**Shared things to be careful with:** dev and prod share one Salesforce org and one Entra traffic-generator client (each environment has its own copy of the generator's secret, but it is the same Entra client). Anthropic keys are per environment (`agent-ops-dev`, `agent-ops-prod`), and CI has its own (`agent-ops-ci`).

## Before

- [ ] The business owner agrees and the retirement date is announced.
- [ ] Every system calling the API has been told and has stopped (check the access logs for the last 14 days).
- [ ] The retry queue and DLQ are empty (no Cases still waiting to be created).

## Steps

1. **Stop synthetic traffic:** set `traffic_enabled = false` for the environment through a PR so the generator stops calling the API.
2. **Stop AI processing:** `aws ssm put-parameter --name /agent-ops/<env>/ai_enabled --value false --overwrite` so nothing new goes to the model.
3. **Revoke access:** remove the Entra role assignments of callers that only used this environment.
4. **Revoke credentials:**
   - Delete this environment's Anthropic API key in the Anthropic Console.
   - Salesforce: revoke the client secret or deactivate the External Client App **only if no other environment uses it** (dev and prod share it).
   - Entra: delete client secrets that only this environment used. The traffic generator client is shared, so keep it while the other environment runs.
5. **Keep the evidence:** export the logs you need to keep (incident evidence, the operating-period record) before they are destroyed.
6. **Remove the infrastructure:**
   ```bash
   cd infra
   terraform workspace select <env>
   terraform destroy -var-file=env/<env>.tfvars
   ```
7. **Remove pipeline access:** delete the `<env>` environment in GitHub and remove it from the deploy role's trust policy in `bootstrap/` (the `environment:<env>` entry), then `terraform apply` in `bootstrap/`.
8. **Update the docs:** remove the environment from the README and `docs/DEPENDENCIES.md`.

## Done when

- `terraform state list` is empty for that workspace.
- The old API URL no longer resolves or returns 404.
- No active credentials for this environment remain in Anthropic, Salesforce or Entra.
