#!/usr/bin/env zsh
# Generates every lab secret once, seals it into the component directories.
# Raw values live in ~/.kc-lab-ca/secrets.env (mode 600) so re-runs reseal the same values.
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
for c in kubeseal yq kubectl openssl; do
  command -v $c >/dev/null || { echo "Missing $c. Run: brew install kubeseal yq kubectl openssl"; exit 1; }
done
kubectl get deploy sealed-secrets-controller --namespace kube-system >/dev/null 2>&1 \
  || { echo "Sealed Secrets controller not found. Run 02-bootstrap.sh first."; exit 1; }
ENVF=~/.kc-lab-ca/secrets.env
rnd() { openssl rand -hex "$1"; }

# Create the env file once; add any keys introduced later (e.g. the demo app) without changing existing values
umask 077; touch $ENVF
ensure() { grep -q "^$1=" $ENVF || echo "$1=$2" >> $ENVF; }
ensure KEYCLOAK_ADMIN_PASSWORD     "$(rnd 12)"
ensure ARGOCD_CLIENT_SECRET        "$(rnd 32)"
ensure GRAFANA_CLIENT_SECRET       "$(rnd 32)"
ensure OAUTH2_PROXY_CLIENT_SECRET  "$(rnd 32)"
ensure OAUTH2_PROXY_COOKIE_SECRET  "$(rnd 16)"
ensure DEMO_USER_PASSWORD          "$(rnd 8)"
ensure DEMO_WEB_CLIENT_SECRET      "$(rnd 32)"
ensure DEMO_WEB_SESSION_SECRET     "$(rnd 32)"
ensure DEMO_API_CLIENT_SECRET      "$(rnd 32)"
ensure DEMO_CLI_CLIENT_SECRET      "$(rnd 32)"
ensure GRAFANA_ADMIN_PASSWORD      "$(rnd 12)"
source $ENVF

seal() { kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml; }
# Build a Secret manifest without touching the cluster: name, namespace, then key=value pairs
secret() {
  local name=$1 ns=$2; shift 2
  kubectl create secret generic "$name" --dry-run=client -o yaml "${@/#/--from-literal=}" \
    | yq ".metadata.namespace = \"$ns\""
}

# Lab CA for cert-manager
kubectl create secret tls lab-root-ca --cert ~/.kc-lab-ca/ca.crt --key ~/.kc-lab-ca/ca.key --dry-run=client -o yaml \
  | yq '.metadata.namespace = "cert-manager"' | seal > components/platform-config/lab-root-ca.sealed.yaml

# Keycloak bootstrap admin (Operator reads keys username/password)
secret keycloak-bootstrap-admin keycloak username=admin password=$KEYCLOAK_ADMIN_PASSWORD \
  | seal > components/keycloak/keycloak-bootstrap-admin.sealed.yaml

# Values substituted into the realm file by keycloak-config-cli: $(env:VAR)
secret keycloak-config-env keycloak \
  ARGOCD_CLIENT_SECRET=$ARGOCD_CLIENT_SECRET \
  GRAFANA_CLIENT_SECRET=$GRAFANA_CLIENT_SECRET \
  OAUTH2_PROXY_CLIENT_SECRET=$OAUTH2_PROXY_CLIENT_SECRET \
  DEMO_USER_PASSWORD=$DEMO_USER_PASSWORD \
  DEMO_WEB_CLIENT_SECRET=$DEMO_WEB_CLIENT_SECRET \
  DEMO_API_CLIENT_SECRET=$DEMO_API_CLIENT_SECRET \
  DEMO_CLI_CLIENT_SECRET=$DEMO_CLI_CLIENT_SECRET \
  | seal > components/keycloak-config/keycloak-config-env.sealed.yaml

# ArgoCD reads $argocd-oidc-keycloak:clientSecret; the label is required for that lookup
secret argocd-oidc-keycloak argocd clientSecret=$ARGOCD_CLIENT_SECRET \
  | yq '.metadata.labels."app.kubernetes.io/part-of" = "argocd"' \
  | seal > components/argocd/argocd-oidc-keycloak.sealed.yaml

# Grafana generic_oauth client secret
secret grafana-oidc monitoring client_secret=$GRAFANA_CLIENT_SECRET \
  | seal > components/monitoring/extras/grafana-oidc.sealed.yaml

# Grafana local admin (break-glass); fixed so ArgoCD does not see a new random password on every render
secret grafana-admin monitoring admin-user=admin admin-password=$GRAFANA_ADMIN_PASSWORD \
  | seal > components/monitoring/extras/grafana-admin.sealed.yaml

# oauth2-proxy (keys expected by the chart's config.existingSecret)
secret oauth2-proxy monitoring client-id=oauth2-proxy client-secret=$OAUTH2_PROXY_CLIENT_SECRET \
  cookie-secret=$OAUTH2_PROXY_COOKIE_SECRET \
  | seal > components/monitoring/extras/oauth2-proxy.sealed.yaml

# Demo app (web client secret, session signing key, API introspection secret)
secret demo-app demo-app web-client-secret=$DEMO_WEB_CLIENT_SECRET session-secret=$DEMO_WEB_SESSION_SECRET \
  api-client-secret=$DEMO_API_CLIENT_SECRET \
  | seal > components/demo-app/demo-app.sealed.yaml

# Public CA cert for Grafana, oauth2-proxy and the demo app (ConfigMaps, not secrets)
cp ~/.kc-lab-ca/ca.crt components/monitoring/extras/lab-ca.crt
cp ~/.kc-lab-ca/ca.crt components/demo-app/lab-ca.crt

# Commit and push. gitea.localtest.me is not routable yet (its certificate needs the CA sealed above),
# so push through a temporary port-forward.
git add -A components
git diff --cached --quiet || git commit -m "lab: sealed secrets"
kubectl config set-context --current --namespace=gitea >/dev/null
kubectl port-forward svc/gitea-http 3000:3000 >/dev/null & PF=$!
trap 'kill $PF 2>/dev/null; kubectl config set-context --current --namespace=argocd >/dev/null' EXIT
sleep 3
git push "http://lab:$(cat ~/.kc-lab-ca/gitea-admin-password)@localhost:3000/lab/keycloak-gitops.git" main

echo "Sealed and pushed. Keycloak admin: admin / $KEYCLOAK_ADMIN_PASSWORD   demo users: $DEMO_USER_PASSWORD"
