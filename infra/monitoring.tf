resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]

  # Simple "count >= threshold" alarms on custom metrics from the Lambda's structured logs.
  custom_alarms = {
    triage-errors = {
      metric    = "TriageErrors"
      threshold = 1
      period    = 300
      runbook   = "runbooks/01-claude-api-outage.md"
    }
    invalid-ai-output = {
      metric    = "InvalidAIOutput"
      threshold = 3
      period    = 900
      runbook   = "runbooks/03-bad-release-rollback.md"
    }
    salesforce-failures = {
      metric    = "SalesforceFailures"
      threshold = 1
      period    = 300
      runbook   = "runbooks/02-salesforce-integration-down.md"
    }
    access-denied-spike = {
      metric    = "AccessDenied"
      threshold = 5
      period    = 300
      runbook   = "runbooks/04-access-requests-and-denials.md"
    }
    kill-switch-active = {
      metric    = "KillSwitchActive"
      threshold = 1
      period    = 3600
      runbook   = "runbooks/01-claude-api-outage.md (section: turning AI back on)"
    }
    synthetic-canary = {
      metric    = "SyntheticFailures"
      threshold = 2
      period    = 3600
      runbook   = "docs/DEPENDENCIES.md (find which dependency failed, then its runbook)"
    }
  }

  # Ratio alarms: one metric divided by another, expressed as a percentage.
  ratio_alarms = {
    slo-success-rate = {
      expression  = "IF(a > 0, 100 * (a - FILL(b, 0)) / a)"
      a           = "Requests"
      b           = "TriageErrors"
      comparison  = "LessThanThreshold"
      threshold   = var.slo_success_pct
      description = "SLO breach: success rate below ${var.slo_success_pct}% over 6h. Runbook: runbooks/01-claude-api-outage.md"
    }
    human-review-rate = {
      expression  = "IF(a > 0, 100 * FILL(b, 0) / a)"
      a           = "Requests"
      b           = "HumanReview"
      comparison  = "GreaterThanThreshold"
      threshold   = var.human_review_alarm_pct
      description = "More than ${var.human_review_alarm_pct}% of messages going to human review over 6h. Runbook: runbooks/06-ai-quality-and-cost.md"
    }
    live-accuracy = {
      expression  = "IF(a >= 10, 100 * (a - FILL(b, 0)) / a)"
      a           = "FeedbackReceived"
      b           = "AIOverride"
      comparison  = "LessThanThreshold"
      threshold   = var.live_accuracy_alarm_pct
      description = "Live accuracy below ${var.live_accuracy_alarm_pct}% over 6h (min 10 reviews). Runbook: runbooks/06-ai-quality-and-cost.md"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "custom" {
  for_each            = local.custom_alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = "${each.value.metric} >= ${each.value.threshold} in ${each.value.period}s. Runbook: ${each.value.runbook}"
  namespace           = "AgentOps"
  metric_name         = each.value.metric
  dimensions          = { Env = local.env }
  statistic           = "Sum"
  period              = each.value.period
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "ratio" {
  for_each            = local.ratio_alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "result"
    expression  = each.value.expression
    label       = each.key
    return_data = true
  }

  metric_query {
    id = "a"
    metric {
      namespace   = "AgentOps"
      metric_name = each.value.a
      dimensions  = { Env = local.env }
      stat        = "Sum"
      period      = 21600 # 6 hours
    }
  }

  metric_query {
    id = "b"
    metric {
      namespace   = "AgentOps"
      metric_name = each.value.b
      dimensions  = { Env = local.env }
      stat        = "Sum"
      period      = 21600
    }
  }
}

# Latency SLO: p90 above target for two 5-minute periods in a row.
resource "aws_cloudwatch_metric_alarm" "latency_p90" {
  alarm_name          = "${local.name}-slo-latency-p90"
  alarm_description   = "SLO breach: p90 triage latency above ${var.slo_latency_p90_ms}ms. Runbook: runbooks/01-claude-api-outage.md"
  namespace           = "AgentOps"
  metric_name         = "LatencyMs"
  dimensions          = { Env = local.env }
  extended_statistic  = "p90"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.slo_latency_p90_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Cost: estimated Claude spend per day.
resource "aws_cloudwatch_metric_alarm" "daily_cost" {
  alarm_name          = "${local.name}-daily-ai-cost"
  alarm_description   = "Estimated Claude spend above USD ${var.daily_cost_alarm_usd} in 24h. Runbook: runbooks/06-ai-quality-and-cost.md"
  namespace           = "AgentOps"
  metric_name         = "EstimatedCostUSD"
  dimensions          = { Env = local.env }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.daily_cost_alarm_usd
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Catches crashes the code itself didn't handle.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "Lambda runtime errors. Runbook: runbooks/03-bad-release-rollback.md"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.agent.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# A Case gave up retrying and was parked in the dead-letter queue: a human must replay it.
resource "aws_cloudwatch_metric_alarm" "crm_dlq" {
  alarm_name          = "${local.name}-crm-dlq-not-empty"
  alarm_description   = "Cases waiting in the dead-letter queue. Runbook: runbooks/02-salesforce-integration-down.md (step 6)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.crm_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 24, height = 4
        properties = {
          title                = "SLOs, quality and cost (for the selected time range)"
          region               = var.region
          view                 = "singleValue"
          setPeriodToTimeRange = true
          stat                 = "Sum"
          metrics = [
            [{ expression = "100 * (req - FILL(err, 0)) / req", label = "Success % (SLO ${var.slo_success_pct})", id = "succ" }],
            ["AgentOps", "Requests", "Env", local.env, { id = "req", visible = false }],
            ["AgentOps", "TriageErrors", "Env", local.env, { id = "err", visible = false }],
            ["AgentOps", "LatencyMs", "Env", local.env, { stat = "p90", label = "p90 latency ms (SLO ${var.slo_latency_p90_ms})" }],
            [{ expression = "100 * (fb - FILL(ov, 0)) / fb", label = "Live accuracy %", id = "acc" }],
            ["AgentOps", "FeedbackReceived", "Env", local.env, { id = "fb", visible = false }],
            ["AgentOps", "AIOverride", "Env", local.env, { id = "ov", visible = false }],
            ["AgentOps", "EstimatedCostUSD", "Env", local.env, { label = "AI cost (USD)" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 4, width = 12, height = 6
        properties = {
          title  = "Volume and routing"
          region = var.region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AgentOps", "Requests", "Env", local.env],
            ["AgentOps", "TriageSuccess", "Env", local.env],
            ["AgentOps", "HumanReview", "Env", local.env],
            ["AgentOps", "SalesforceCaseCreated", "Env", local.env],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 4, width = 12, height = 6
        properties = {
          title  = "Problems"
          region = var.region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AgentOps", "TriageErrors", "Env", local.env],
            ["AgentOps", "InvalidAIOutput", "Env", local.env],
            ["AgentOps", "SalesforceFailures", "Env", local.env],
            ["AgentOps", "SyntheticFailures", "Env", local.env],
            ["AgentOps", "KillSwitchActive", "Env", local.env],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 10, width = 12, height = 6
        properties = {
          title       = "Latency (ms)"
          region      = var.region
          period      = 3600
          annotations = { horizontal = [{ label = "SLO", value = var.slo_latency_p90_ms }] }
          metrics = [
            ["AgentOps", "LatencyMs", "Env", local.env, { stat = "p50" }],
            ["AgentOps", "LatencyMs", "Env", local.env, { stat = "p90" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 10, width = 12, height = 6
        properties = {
          title  = "Quality: human-review rate % and live accuracy %"
          region = var.region
          period = 21600
          stat   = "Sum"
          yAxis  = { left = { min = 0, max = 100 } }
          metrics = [
            [{ expression = "100 * FILL(hr, 0) / req2", label = "Human-review rate %", id = "hrr" }],
            [{ expression = "100 * (fb2 - FILL(ov2, 0)) / fb2", label = "Live accuracy %", id = "acc2" }],
            ["AgentOps", "Requests", "Env", local.env, { id = "req2", visible = false }],
            ["AgentOps", "HumanReview", "Env", local.env, { id = "hr", visible = false }],
            ["AgentOps", "FeedbackReceived", "Env", local.env, { id = "fb2", visible = false }],
            ["AgentOps", "AIOverride", "Env", local.env, { id = "ov2", visible = false }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 16, width = 12, height = 6
        properties = {
          title  = "AI cost per day (USD) and tokens"
          region = var.region
          stat   = "Sum"
          period = 86400
          metrics = [
            ["AgentOps", "EstimatedCostUSD", "Env", local.env],
            ["AgentOps", "ClaudeInputTokens", "Env", local.env, { yAxis = "right" }],
            ["AgentOps", "ClaudeOutputTokens", "Env", local.env, { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 16, width = 12, height = 6
        properties = {
          title  = "CRM reliability: queued, retried, dead-lettered"
          region = var.region
          period = 3600
          metrics = [
            ["AgentOps", "CrmQueued", "Env", local.env, { stat = "Sum" }],
            ["AgentOps", "CrmRetrySucceeded", "Env", local.env, { stat = "Sum" }],
            ["AgentOps", "CrmRetryFailed", "Env", local.env, { stat = "Sum" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.crm_dlq.name, { stat = "Maximum", label = "In dead-letter queue" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 22, width = 24, height = 6
        properties = {
          title  = "Access patterns: calls by Entra role, and denied requests"
          region = var.region
          stat   = "Sum"
          period = 3600
          metrics = [
            ["AgentOps", "CallsByRole", "Env", local.env, "Role", "Agent.Operator"],
            ["AgentOps", "CallsByRole", "Env", local.env, "Role", "Agent.Viewer"],
            ["AgentOps", "CallsByRole", "Env", local.env, "Role", "unauthenticated"],
            ["AgentOps", "AccessDenied", "Env", local.env],
          ]
        }
      },
    ]
  })
}