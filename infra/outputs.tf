output "api_url" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "function_name" {
  value = aws_lambda_function.agent.function_name
}

output "live_version" {
  value = aws_lambda_alias.live.function_version
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}

output "crm_dlq_arn" {
  value = aws_sqs_queue.crm_dlq.arn
}

output "auth_mode" {
  value = local.auth_enabled ? "entra" : "none"
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${local.name}"
}