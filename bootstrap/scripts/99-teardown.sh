#!/usr/bin/env zsh
# Tears down the Keycloak lab.
#   99-teardown.sh           cluster and per-cluster local state. Keeps the CA (and its keychain trust),
#                            secrets.env and the Gitea password, so a rebuild reuses the same values.
#   99-teardown.sh --purge   everything: also the CA and keychain trust, secrets.env, Gitea password,
#                            the git credential, sealed files and CA copies in the repo, and demo-app images.
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
PURGE=false; [[ ${1:-} == --purge ]] && PURGE=true

echo "== cluster"
kind delete cluster --name keycloak-lab || true          # also removes the kind-keycloak-lab kube context

echo "== kubeconfig personas and token caches"
for u in alice bob carol; do
  kubectl config delete-context oidc-$u@keycloak-lab 2>/dev/null || true
  kubectl config delete-user oidc-$u 2>/dev/null || true
done
rm -rf ~/.kube/cache/oidc-login/keycloak-lab

echo "== argocd CLI contexts"
for c in argocd.localtest.me localhost:8080; do argocd context --delete $c 2>/dev/null || true; done

echo "== repo-local state"
rm -rf bootstrap/.rendered
git remote remove lab 2>/dev/null || true
git config --unset http.https://gitea.localtest.me/.sslCAInfo 2>/dev/null || true

if $PURGE; then
  echo "== purge: credentials, CA, secrets, generated files, images"
  printf 'protocol=https\nhost=gitea.localtest.me\n\n' | git credential-osxkeychain erase 2>/dev/null || true
  sudo security delete-certificate -c "keycloak-lab root CA" /Library/Keychains/System.keychain || true
  rm -rf ~/.kc-lab-ca
  find components -name '*.sealed.yaml' -delete
  rm -f components/monitoring/extras/lab-ca.crt components/demo-app/lab-ca.crt
  for img in $(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep '^demo-app:' || true); do
    docker image rm "$img"
  done
fi

echo "== check"
kind get clusters | grep -x keycloak-lab && echo "cluster still present!" || echo "cluster gone"
lsof -nP -iTCP:443 -sTCP:LISTEN >/dev/null && echo "something still holds :443" || echo ":443 free"
$PURGE && { [[ -d ~/.kc-lab-ca ]] && echo "~/.kc-lab-ca still present!" || echo "~/.kc-lab-ca removed"; }
echo "teardown complete"
