#!/usr/bin/env bash
# Get an Entra ID access token for a client app.
# Usage: source scripts/get-token.sh <client-id> <client-secret>
# Needs TENANT_ID and API_CLIENT_ID exported. Sets $TOKEN.
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "client_id=$1" \
  --data-urlencode "client_secret=$2" \
  --data-urlencode "scope=api://${API_CLIENT_ID}/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r .access_token)
export TOKEN
node -e 'const c=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url"));console.log("roles:",c.roles,"| aud:",c.aud,"| iss:",c.iss)' "$TOKEN"