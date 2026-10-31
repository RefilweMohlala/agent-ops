variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarms. Set via TF_VAR_alert_email, not in git."
  type        = string
}

variable "model_id" {
  description = "Claude model used for triage"
  type        = string
  default     = "claude-haiku-4-5"
}

variable "price_input_per_mtok" {
  description = "Claude price in USD per million INPUT tokens (check anthropic.com/pricing)"
  type        = number
  default     = 1
}

variable "price_output_per_mtok" {
  description = "Claude price in USD per million OUTPUT tokens (check anthropic.com/pricing)"
  type        = number
  default     = 5
}

variable "confidence_threshold" {
  description = "Below this confidence a case is sent for human review"
  type        = number
  default     = 0.75

  validation {
    condition     = var.confidence_threshold >= 0 && var.confidence_threshold <= 1
    error_message = "confidence_threshold must be between 0 and 1."
  }
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second allowed by API Gateway"
  type        = number
  default     = 2
}

variable "throttle_burst_limit" {
  type    = number
  default = 5
}

# ----- Day 3: SLOs and alarm thresholds -----
variable "slo_success_pct" {
  description = "SLO: % of triage requests that must succeed (measured over 6 hours)"
  type        = number
  default     = 99
}

variable "slo_latency_p90_ms" {
  description = "SLO: 90% of triage requests must finish within this many milliseconds"
  type        = number
  default     = 10000
}

variable "daily_cost_alarm_usd" {
  description = "Alarm if estimated Claude spend in one day goes above this"
  type        = number
  default     = 1
}

variable "human_review_alarm_pct" {
  description = "Alarm if more than this % of messages go to human review (over 6 hours)"
  type        = number
  default     = 50
}

variable "live_accuracy_alarm_pct" {
  description = "Alarm if live accuracy from reviewer feedback drops below this % (over 6 hours, min 10 reviews)"
  type        = number
  default     = 80
}

variable "traffic_enabled" {
  description = "Run the synthetic traffic generator in this environment (Day 3)"
  type        = bool
  default     = false
}

# ----- Day 7: Entra ID -----
variable "entra_tenant_id" {
  description = "Microsoft Entra tenant ID. Leave empty until Day 7 (API stays unauthenticated)."
  type        = string
  default     = ""
}

variable "entra_api_client_id" {
  description = "Application (client) ID of the agent-ops-api app registration in Entra"
  type        = string
  default     = ""
}