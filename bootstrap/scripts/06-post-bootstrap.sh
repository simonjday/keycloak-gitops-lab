#!/usr/bin/env zsh
# Run after 03-secrets.sh. Waits for the platform and Keycloak waves, switches git to Gitea's HTTPS route
# (CA + keychain credential), then enables ArgoCD SSO against the platform realm and pushes it.
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
CA=~/.kc-lab-ca/ca.crt
kubectl config set-context --current --namespace=argocd >/dev/null

wait_app() {   # name [timeout-seconds]
  local n=$1 t=${2:-900} s=0
  printf "waiting for %-18s" "$n"
  until [[ "$(kubectl get application "$n" -o jsonpath='{.status.health.status}' 2>/dev/null)" == Healthy ]]; do
    (( s += 10 )); (( s > t )) && { echo " TIMEOUT (kubectl get application $n -o json | jq -f jq/app-conditions.jq)"; exit 1; }
    printf "."; sleep 10
  done
  echo " Healthy"
}

# 1. Platform layer: Gateway, wildcard cert, gitea.localtest.me route
wait_app platform-config 900
until curl -sf -o /dev/null --cacert $CA https://gitea.localtest.me/; do sleep 5; done

# 2. Git remote over HTTPS. The credential is stored per hostname, and the authentik lab uses the same
#    hostname with a different password, so always replace it.
git config http.https://gitea.localtest.me/.sslCAInfo $CA
git config credential.helper osxkeychain
git remote get-url lab >/dev/null 2>&1 || git remote add lab https://gitea.localtest.me/lab/keycloak-gitops.git
printf 'protocol=https\nhost=gitea.localtest.me\n\n' | git credential-osxkeychain erase 2>/dev/null || true
printf 'protocol=https\nhost=gitea.localtest.me\nusername=lab\npassword=%s\n\n' \
  "$(cat ~/.kc-lab-ca/gitea-admin-password)" | git credential approve
git fetch lab && git branch --set-upstream-to=lab/main main >/dev/null

# 3. Keycloak and the realm
wait_app keycloak 1500
wait_app keycloak-config 900
until curl -sf -o /dev/null --cacert $CA https://keycloak.localtest.me/realms/platform/.well-known/openid-configuration; do sleep 10; done
echo "realm 'platform' is live"

# 4. ArgoCD SSO (idempotent: only commits if the value changes)
export CA_PEM="$(cat $CA)"
yq -i '.configs.cm."oidc.config" = "name: Keycloak\nissuer: https://keycloak.localtest.me/realms/platform\nclientID: argocd\nclientSecret: $argocd-oidc-keycloak:clientSecret\nrequestedScopes: [openid, profile, email, groups]\nrootCA: |\n" + (strenv(CA_PEM) | sub("(?m)^"; "  "))' \
  bootstrap/argocd-values.yaml
if ! git diff --quiet bootstrap/argocd-values.yaml; then
  git commit -m "argocd: enable Keycloak SSO" bootstrap/argocd-values.yaml
  git push lab main
fi

# 5. Everything else
for a in monitoring oidc-rbac oauth2-proxy demo-app; do wait_app $a 900; done
echo
kubectl get applications -o json | jq -r -f jq/apps-status.jq | column -t
