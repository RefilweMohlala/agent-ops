# prod: the environment you OPERATE. alert_email comes from TF_VAR_alert_email (kept out of git).
confidence_threshold  = 0.80
log_retention_days    = 30
throttle_rate_limit   = 5
throttle_burst_limit  = 10
model_id              = "claude-haiku-4-5"
price_input_per_mtok  = 1
price_output_per_mtok = 5
daily_cost_alarm_usd  = 1

# Day 5: switched on once prod has its secret.
traffic_enabled = false

# Day 7: fill these in to switch on Entra ID authentication
entra_tenant_id     = ""
entra_api_client_id = ""