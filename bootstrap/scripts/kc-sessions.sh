#!/usr/bin/env zsh
# Use case 6: list a user's active Keycloak sessions via the admin API.
# Usage: kc-sessions.sh <username>
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
source ~/.kc-lab-ca/secrets.env
KC=https://keycloak.localtest.me
CA=~/.kc-lab-ca/ca.crt
TOKEN=$(curl -s --cacert $CA -d grant_type=password -d client_id=admin-cli \
  -d username=admin --data-urlencode "password=$KEYCLOAK_ADMIN_PASSWORD" \
  $KC/realms/master/protocol/openid-connect/token | jq -r .access_token)
UID_=$(curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/platform/users?username=$1&exact=true" | jq -r '.[0].id')
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/platform/users/$UID_/sessions" | jq -f jq/kc-sessions.jq
