# dev: where changes are tried first. alert_email comes from TF_VAR_alert_email (kept out of git).
confidence_threshold  = 0.75
log_retention_days    = 7
throttle_rate_limit   = 2
throttle_burst_limit  = 5
model_id              = "claude-haiku-4-5"
price_input_per_mtok  = 1
price_output_per_mtok = 5
daily_cost_alarm_usd  = 0.5

# Day 3: switched on here first. Day 5: switched off here and on in prod.
traffic_enabled = false

# Day 7: fill these in to switch on Entra ID authentication
entra_tenant_id     = ""
entra_api_client_id = ""