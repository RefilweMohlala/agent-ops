# Synthetic traffic generator: keeps the agent busy so it can be operated over time,
# and doubles as an end-to-end canary.
data "archive_file" "traffic" {
  type        = "zip"
  source_dir  = "${path.module}/../traffic"
  output_path = "${path.module}/.build/traffic-${local.env}.zip"
}
resource "aws_cloudwatch_log_group" "traffic" {
  name              = "/aws/lambda/${local.name}-traffic"
  retention_in_days = var.log_retention_days
}
# Holds the generator's own Entra client credentials (filled in on Day 7).
resource "aws_secretsmanager_secret" "traffic" {
  name                    = "agent-ops/${local.env}/traffic"
  description             = "Entra client credentials for the synthetic traffic generator"
  recovery_window_in_days = 0
}
resource "aws_iam_role" "traffic" {
  name = "${local.name}-traffic"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy" "traffic" {
  name = "${local.name}-traffic"
  role = aws_iam_role.traffic.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.traffic.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.traffic.arn
      },
    ]
  })
}
resource "aws_lambda_function" "traffic" {
  function_name    = "${local.name}-traffic"
  role             = aws_iam_role.traffic.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.traffic.output_path
  source_code_hash = data.archive_file.traffic.output_base64sha256
  timeout          = 120
  memory_size      = 128
  environment {
    variables = {
      ENV               = local.env
      API_URL           = aws_apigatewayv2_api.this.api_endpoint
      AUTH_MODE         = local.auth_enabled ? "entra" : "none"
      TRAFFIC_SECRET_ID = aws_secretsmanager_secret.traffic.name
      TENANT_ID         = var.entra_tenant_id
      API_CLIENT_ID     = var.entra_api_client_id
    }
  }
  depends_on = [aws_cloudwatch_log_group.traffic, aws_iam_role_policy.traffic]
}
resource "aws_cloudwatch_event_rule" "traffic" {
  name                = "${local.name}-traffic"
  description         = "Synthetic member traffic every 20 minutes"
  schedule_expression = "rate(20 minutes)"
  state               = var.traffic_enabled ? "ENABLED" : "DISABLED"
}
resource "aws_cloudwatch_event_target" "traffic" {
  rule = aws_cloudwatch_event_rule.traffic.name
  arn  = aws_lambda_function.traffic.arn
}
resource "aws_lambda_permission" "traffic" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.traffic.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.traffic.arn
}