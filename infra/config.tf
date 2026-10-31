# The secret container is managed by Terraform. The VALUE is set by hand with the
# AWS CLI so API keys never appear in code or Terraform state.
resource "aws_secretsmanager_secret" "app" {
  name                    = "agent-ops/${local.env}/app"
  description             = "Claude + Salesforce credentials for ${local.name}"
  recovery_window_in_days = local.env == "prod" ? 7 : 0
}

# ----- Operational toggles: flipped by operators at runtime, so Terraform ignores value changes -----
resource "aws_ssm_parameter" "ai_enabled" {
  name        = "${local.param_path}/ai_enabled"
  description = "KILL SWITCH. 'false' = skip AI, send every message to human review."
  type        = "String"
  value       = "true"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "salesforce_enabled" {
  name        = "${local.param_path}/salesforce_enabled"
  description = "'true' = create a Salesforce Case for every message"
  type        = "String"
  value       = "false"

  lifecycle {
    ignore_changes = [value]
  }
}

# ----- Change-controlled config: only changes through a reviewed PR -----
resource "aws_ssm_parameter" "confidence_threshold" {
  name  = "${local.param_path}/confidence_threshold"
  type  = "String"
  value = tostring(var.confidence_threshold)
}

resource "aws_ssm_parameter" "model_id" {
  name  = "${local.param_path}/model_id"
  type  = "String"
  value = var.model_id
}

resource "aws_ssm_parameter" "price_input" {
  name  = "${local.param_path}/price_input_per_mtok"
  type  = "String"
  value = tostring(var.price_input_per_mtok)
}

resource "aws_ssm_parameter" "price_output" {
  name  = "${local.param_path}/price_output_per_mtok"
  type  = "String"
  value = tostring(var.price_output_per_mtok)
}