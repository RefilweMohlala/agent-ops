#!/usr/bin/env bash
# Send a test complaint. Usage: bash scripts/triage.sh "<message>" (uses $API_URL and optional $TOKEN)
set -euo pipefail

AUTH_HEADER=()
if [ -n "${TOKEN:-}" ]; then AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}"); fi

curl -s -X POST "${API_URL}/triage" \
  -H "content-type: application/json" \
  "${AUTH_HEADER[@]}" \
  -d "$(jq -n --arg m "$1" '{message: $m, member_ref: "TEST-001", source: "manual"}')" | jq .