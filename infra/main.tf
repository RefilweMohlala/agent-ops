locals {
  env          = terraform.workspace
  name         = "agent-ops-${local.env}"
  param_path   = "/agent-ops/${local.env}"
  account_id   = data.aws_caller_identity.current.account_id
  auth_enabled = var.entra_tenant_id != "" && var.entra_api_client_id != ""
}

data "aws_caller_identity" "current" {}

# Stops anyone applying to the "default" workspace by mistake.
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = contains(["dev", "prod"], terraform.workspace)
      error_message = "Select a workspace first: terraform workspace select dev|prod"
    }
  }
}

# ---------- Lambda package ----------
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/.build/lambda-${local.env}.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

# ---------- Least-privilege execution role ----------
resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.name}-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid    = "ReadOwnConfig"
        Effect = "Allow"
        Action = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${var.region}:${local.account_id}:parameter${local.param_path}",
          "arn:aws:ssm:${var.region}:${local.account_id}:parameter${local.param_path}/*",
        ]
      },
      {
        Sid      = "ReadOwnSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.app.arn
      },
      {
        # Send failed Cases to the retry queue, and consume it as the retry worker
        Sid    = "CrmRetryQueue"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.crm_retry.arn
      },
    ]
  })
}

# ---------- The agent ----------
resource "aws_lambda_function" "agent" {
  function_name    = local.name
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 256
  publish          = true # every change creates a numbered version we can roll back to

  environment {
    variables = {
      ENV           = local.env
      PARAM_PATH    = local.param_path
      SECRET_ID     = aws_secretsmanager_secret.app.name
      AUTH_MODE     = local.auth_enabled ? "entra" : "none"
      CRM_QUEUE_URL = aws_sqs_queue.crm_retry.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# API Gateway and the retry queue always call the "live" alias.
# Rollback = point the alias at an older version.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.agent.function_name
  function_version = aws_lambda_function.agent.version
}