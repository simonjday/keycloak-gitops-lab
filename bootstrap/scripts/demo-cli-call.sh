#!/usr/bin/env zsh
# Use case 11: machine-to-machine. Gets a client-credentials token for demo-cli and calls the demo API.
# Usage: demo-cli-call.sh [user|admin|public]
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
source ~/.kc-lab-ca/secrets.env
CA=~/.kc-lab-ca/ca.crt
ENDPOINT=${1:-user}
RESP=$(curl -s --cacert $CA \
  -d grant_type=client_credentials -d client_id=demo-cli --data-urlencode "client_secret=$DEMO_CLI_CLIENT_SECRET" \
  https://keycloak.localtest.me/realms/platform/protocol/openid-connect/token)
echo "--- token claims"
echo "$RESP" | jq -f jq/token-claims.jq
echo "--- GET /api/$ENDPOINT"
curl -s --cacert $CA -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer $(echo "$RESP" | jq -r .access_token)" https://api.localtest.me/api/$ENDPOINT
