# One-time setup: Terraform state bucket, GitHub OIDC trust, CI/CD roles, budget.
# Run locally with your admin credentials. State for THIS folder stays local.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "github_repo" {
  description = "owner/repo that is allowed to deploy"
  type        = string
  default     = "RefilweMohlala/agent-ops"
}

variable "alert_email" {
  description = "Where budget alerts go"
  type        = string
}

variable "monthly_budget_usd" {
  type    = string
  default = "20"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "agent-ops"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "agent-ops-tfstate-${local.account_id}"
}

# ---------- Terraform remote state ----------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- GitHub Actions -> AWS via OIDC (no stored AWS keys) ----------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
}

# Plan role: read-only. Used by pull requests.
resource "aws_iam_role" "gha_plan" {
  name = "agent-ops-gha-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:pull_request"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Deploy role: can change agent-ops resources only. Only usable from GitHub
# jobs that run inside the dev / prod environments.
resource "aws_iam_role" "gha_deploy" {
  name = "agent-ops-gha-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repo}:environment:dev",
            "repo:${var.github_repo}:environment:prod",
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_deploy" {
  name = "agent-ops-deploy"
  role = aws_iam_role.gha_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TerraformStateList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Sid      = "TerraformStateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        # v2 adds SQS (retry queue) and EventBridge (traffic schedule)
        Sid    = "AgentServices"
        Effect = "Allow"
        Action = [
          "lambda:*", "apigateway:*", "logs:*", "cloudwatch:*", "sns:*", "sqs:*", "events:*"
        ]
        Resource = "*"
      },
      {
        Sid      = "AgentParameters"
        Effect   = "Allow"
        Action   = ["ssm:*"]
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/agent-ops/*"
      },
      {
        Sid      = "DescribeParameters"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
      {
        Sid      = "AgentSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:*"]
        Resource = "arn:aws:secretsmanager:*:${local.account_id}:secret:agent-ops/*"
      },
      {
        Sid    = "AgentRoles"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/agent-ops-*",
          "arn:aws:iam::${local.account_id}:policy/agent-ops-*",
        ]
      },
      {
        Sid      = "ApiGatewayServiceLinkedRole"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "ops.apigateway.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------- Cost guardrail ----------
resource "aws_budgets_budget" "monthly" {
  name              = "agent-ops-monthly"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "plan_role_arn" {
  value = aws_iam_role.gha_plan.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.gha_deploy.arn
}
