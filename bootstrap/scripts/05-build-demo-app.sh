#!/usr/bin/env zsh
# Builds the demo app image and loads it into the kind node (no registry needed).
# Run any time after 01-cluster.sh; running it before 02 means demo-app never waits for its image.
# Bump TAG here AND in components/demo-app/*.yaml together, then commit, so ArgoCD rolls the pods.
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
TAG=${1:-0.1.0}
docker build --tag demo-app:$TAG apps/demo-app            # arm64 on an M3; matches the kind node
kind load docker-image demo-app:$TAG --name keycloak-lab
docker exec keycloak-lab-control-plane crictl images | grep demo-app

# If the Deployments already exist and are waiting on the image, restart them instead of waiting for backoff
if kubectl get deployment demo-web --namespace demo-app >/dev/null 2>&1; then
  kubectl config set-context --current --namespace=demo-app >/dev/null
  kubectl rollout restart deployment demo-web demo-api
  kubectl rollout status deployment demo-web --timeout=120s
  kubectl config set-context --current --namespace=argocd >/dev/null
fi
