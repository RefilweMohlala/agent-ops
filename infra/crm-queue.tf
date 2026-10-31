# Where Cases go when Salesforce is down. Retried automatically; never silently lost.
resource "aws_sqs_queue" "crm_dlq" {
  name                      = "${local.name}-crm-dlq"
  message_retention_seconds = 1209600 # 14 days: time for a human to investigate and replay
  sqs_managed_sse_enabled   = true    # encrypted at rest
}

resource "aws_sqs_queue" "crm_retry" {
  name                       = "${local.name}-crm-retry"
  delay_seconds              = 60     # first retry after 1 minute, not instantly
  visibility_timeout_seconds = 300    # then every ~5 minutes (must be >= the Lambda timeout)
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.crm_dlq.arn
    maxReceiveCount     = 6 # ~30 minutes of retries, then park it in the DLQ
  })
}

# The agent Lambda (live alias) is also the retry worker.
resource "aws_lambda_event_source_mapping" "crm_retry" {
  event_source_arn        = aws_sqs_queue.crm_retry.arn
  function_name           = aws_lambda_alias.live.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.lambda]
}