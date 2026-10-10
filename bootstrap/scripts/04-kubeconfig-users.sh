#!/usr/bin/env zsh
# Use case 3: one kubeconfig user + context per persona. Local kubeconfig only; nothing is created in the cluster.
set -euo pipefail
kubectl oidc-login --version >/dev/null 2>&1 || {
  echo "kubectl oidc-login plugin not found. Install it: brew install int128/kubelogin/kubelogin"
  echo "(if Azure kubelogin is installed, use krew instead: brew install krew && kubectl krew install oidc-login)"; exit 1; }
ISSUER=https://keycloak.localtest.me/realms/platform
for u in alice bob carol; do
  kubectl config set-credentials oidc-$u \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-interactive-mode=IfAvailable \
    --exec-command=kubectl \
    --exec-arg=oidc-login --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url=$ISSUER \
    --exec-arg=--oidc-client-id=kubernetes \
    --exec-arg=--oidc-extra-scope=profile \
    --exec-arg=--oidc-extra-scope=email \
    --exec-arg=--certificate-authority=$HOME/.kc-lab-ca/ca.crt \
    --exec-arg=--token-cache-dir=$HOME/.kube/cache/oidc-login/keycloak-lab/$u \
    --exec-arg=--skip-open-browser       # paste the printed URL into that persona's private window
  kubectl config set-context oidc-$u@keycloak-lab --cluster=kind-keycloak-lab --user=oidc-$u
done
kubectl config set-context oidc-bob@keycloak-lab --namespace=demo   # bob works in demo
echo "Contexts: oidc-alice@keycloak-lab, oidc-bob@keycloak-lab, oidc-carol@keycloak-lab"
