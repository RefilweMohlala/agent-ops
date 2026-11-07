#!/usr/bin/env bash
# Post-deploy smoke test: GET /status must return 200.
# If SMOKE_CLIENT_ID is set, it first gets an Entra ID token (viewer role).
set -euo pipefail
API_URL="$1"
AUTH_HEADER=()
if [ -n "${SMOKE_CLIENT_ID:-}" ]; then
  TOKEN=$(curl -sf -X POST "https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${SMOKE_CLIENT_ID}" \
    --data-urlencode "client_secret=${SMOKE_CLIENT_SECRET}" \
    --data-urlencode "scope=api://${ENTRA_API_CLIENT_ID}/.default" \
    --data-urlencode "grant_type=client_credentials" | jq -r .access_token)
  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
fi
for attempt in 1 2 3; do
  if RESPONSE=$(curl -sf "${AUTH_HEADER[@]}" "${API_URL}/status"); then
    echo "Smoke test passed:"
    echo "$RESPONSE" | jq .
    exit 0
  fi
  echo "Attempt ${attempt} failed, retrying in 5s..."
  sleep 5
done
echo "Smoke test FAILED: ${API_URL}/status did not return 200"
exit 1