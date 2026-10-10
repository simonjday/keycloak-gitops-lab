#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h}/../.."   # repo root, from the script location
unset KIND_EXPERIMENTAL_PROVIDER     # kind's default provider is Docker
R=bootstrap/.rendered && mkdir -p "$R"

# Render the authn config with the lab CA indented under certificateAuthority
CA="$(sed 's/^/        /' ~/.kc-lab-ca/ca.crt)" \
  awk '/__CA_PEM__/{print ENVIRON["CA"]; next} {print}' \
  bootstrap/authn-config.yaml.tmpl > "$R/authn-config.yaml"

# kubeadm patch for the API server static pod. The API server is hostNetwork, and kubelet gives it a snapshot of
# the node's /etc/hosts taken when the pod is created, so an entry added to the node afterwards is never seen.
# hostAliases puts the issuer hostname into the pod spec itself, pointing at Envoy's pinned ClusterIP.
mkdir -p "$R/patches"
cat > "$R/patches/kube-apiserver+strategic.yaml" <<'EOF'
spec:
  hostAliases:
    - ip: "10.96.0.250"
      hostnames: ["keycloak.localtest.me"]
EOF

sed "s|__RENDERED_DIR__|$PWD/$R|" bootstrap/kind-config.yaml > "$R/kind-config.yaml"
kind create cluster --config "$R/kind-config.yaml"

# Verify the kubeadm patches landed: OIDC flag on the API server, and the issuer hostname in its own hosts file
N=keycloak-lab-control-plane
docker exec $N grep -q -- '--authentication-config=/etc/kubernetes/authn/authn-config.yaml' /etc/kubernetes/manifests/kube-apiserver.yaml \
  || { echo "API server has no --authentication-config: kubeadm patches not applied (check apiVersion vs /kind/kubeadm.conf)"; exit 1; }
P=$(docker exec $N pgrep -f '^kube-apiserver' | head -1)
docker exec $N grep keycloak.localtest.me /proc/$P/root/etc/hosts \
  || { echo "API server hosts file lacks keycloak.localtest.me: hostAliases patch not applied"; exit 1; }
echo "API server: OIDC authentication config and issuer hostAlias present"

kubectl config use-context kind-keycloak-lab
kubectl get --raw='/readyz?verbose' | tail -n 2
