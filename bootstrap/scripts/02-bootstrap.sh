#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Not a git repo. Run: git init -b main && git add . && git commit -m init"; exit 1; }
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "No commits yet. Run: git add . && git commit -m init"; exit 1; }
[[ "$(git rev-parse --show-toplevel)" == "$PWD" ]] || {
  echo "Git repo root is $(git rev-parse --show-toplevel), not $PWD."
  echo "ArgoCD reads paths from the repo root, so root/ would not be found. Run 'git init -b main' in $PWD."; exit 1; }
ns() { kubectl config set-context --current --namespace="$1" >/dev/null; }   # helm follows the context namespace

helm repo add --force-update sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo add --force-update gitea-charts https://dl.gitea.com/charts/
helm repo add --force-update argo https://argoproj.github.io/argo-helm
helm repo update

# 1. Sealed Secrets: adopted later by root/00-sealed-secrets.yaml (same release name)
ns kube-system
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets --version 2.20.0 \
  --set fullnameOverride=sealed-secrets-controller --wait

# 2. Gitea
PWF=~/.kc-lab-ca/gitea-admin-password
[[ -f $PWF ]] || (umask 077; openssl rand -hex 16 > $PWF)
GITEA_PW=$(<$PWF)
ns gitea
helm upgrade --install gitea gitea-charts/gitea --create-namespace \
  -f bootstrap/gitea-values.yaml --set gitea.admin.password="$GITEA_PW" --wait --timeout 10m

# 3. Seed the repo through a temporary port-forward (Envoy is not up yet)
kubectl port-forward svc/gitea-http 3000:3000 >/dev/null & PF=$!
trap 'kill $PF' EXIT; sleep 3
curl -sf -u "lab:$GITEA_PW" -H 'Content-Type: application/json' \
  -d '{"name":"keycloak-gitops","private":false,"default_branch":"main"}' \
  http://localhost:3000/api/v1/user/repos >/dev/null || echo "repo exists"
# Local checkout is the source of truth; Gitea is a seed copy, so overwrite it on re-runs
git push --force "http://lab:${GITEA_PW}@localhost:3000/lab/keycloak-gitops.git" main

# 4. ArgoCD. A failed earlier attempt leaves a release Helm cannot upgrade, so remove it first.
ns argocd
if helm status argocd >/dev/null 2>&1 && [[ $(helm status argocd -o json | jq -r .info.status) != deployed ]]; then
  helm uninstall argocd --wait
fi
helm upgrade --install argocd argo/argo-cd --version 9.7.1 --create-namespace \
  -f bootstrap/argocd-values.yaml --wait

# 5. Root app-of-apps, as a separate release so the Application CRD already exists
helm upgrade --install root-app argo/argocd-apps -f bootstrap/root-app-values.yaml --wait

echo "ArgoCD admin password:"
kubectl get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
