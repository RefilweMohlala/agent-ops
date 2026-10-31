resource "aws_apigatewayv2_api" "this" {
  name          = local.name
  protocol_type = "HTTP"
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  # Access log = who called what, when, and with which result (access-pattern tracking)
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      time             = "$context.requestTime"
      ip               = "$context.identity.sourceIp"
      route            = "$context.routeKey"
      status           = "$context.status"
      latencyMs        = "$context.responseLatency"
      callerAppId      = "$context.authorizer.claims.azp"
      authError        = "$context.authorizer.error"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

# Entra ID JWT check. Only created once entra_* variables are set (Day 7).
resource "aws_apigatewayv2_authorizer" "entra" {
  count            = local.auth_enabled ? 1 : 0
  api_id           = aws_apigatewayv2_api.this.id
  name             = "entra-id"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [var.entra_api_client_id]
    issuer   = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0"
  }
}

resource "aws_apigatewayv2_route" "routes" {
  for_each           = toset(["POST /triage", "POST /feedback", "GET /status"])
  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = local.auth_enabled ? "JWT" : "NONE"
  authorizer_id      = local.auth_enabled ? aws_apigatewayv2_authorizer.entra[0].id : null
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}