# Keycloak SSO on kind (M3 Mac, Docker Desktop) — Build & Demo Guide

Oct 10, 2026 · Simon Day · Keycloak 26.7.0 via the Keycloak Operator, CloudNativePG, keycloak-config-cli, ArgoCD

## Overview

This is a standalone lab with a purpose-built demo application (a Python web app and API) alongside the platform tools: its own kind cluster (`keycloak-lab`), lab CA (`~/.kc-lab-ca`), Gitea repo (`keycloak-gitops`) and secrets. It shares nothing with the authentik lab, so the two cannot run side by side: both bind host ports 80/443. Use cases 1–6 mirror the authentik lab so the results are directly comparable. Use case 7 shows a behaviour specific to Keycloak config-as-code, and use cases 8–12 use the demo app to show what an application developer sees: tokens, client roles, machine-to-machine access and revocation.

```mermaid
flowchart TB
  subgraph mac["macOS (M3, Docker Desktop)"]
    kubectl["kubectl + kubelogin"]
    browser["Browser: alice, bob, carol"]
    git["git push"]
  end
  subgraph kind["kind: keycloak-lab, single node"]
    envoy["Envoy (Contour) · 10.96.0.250 · TLS *.localtest.me"]
    api["API server · JWT authn"]
    kc["Keycloak 26.7 (Operator)"]
    pg[("CloudNativePG · keycloak-db")]
    cli["keycloak-config-cli Job (PostSync)"]
    argo["ArgoCD · OIDC client"]
    gitea["Gitea"]
    graf["Grafana · OIDC client"]
    o2p["oauth2-proxy"]
    prom["Prometheus · no built-in auth"]
    web["demo-web · OIDC client"]
    dapi["demo-api · validates JWTs"]
  end
  cliapp["demo-cli (client credentials)"]
  browser -- "host :443" --> envoy
  git --> envoy
  kubectl -- "API :6443" --> api
  api -. "JWKS via node /etc/hosts" .-> envoy
  envoy --> kc & argo & gitea & graf & o2p & web & dapi
  web -- "Bearer access token" --> dapi
  dapi -. "JWKS / introspection" .-> envoy
  mac --- cliapp
  cliapp -- "token, then API call" --> envoy
  kc --> pg
  argo -- pulls --> gitea
  argo -- "runs on realm change" --> cli
  cli -- "admin API" --> kc
  o2p -- "proxied after group check" --> prom
```

### What the demos prove

| # | Use case | Mechanism | What it shows |
| --- | --- | --- | --- |
| 1 | ArgoCD SSO + group RBAC | Confidential OIDC client, `groups` client scope | Admin vs developer vs read-only from Keycloak groups |
| 2 | Grafana role mapping | OIDC + PKCE | Admin / Editor / Viewer from groups; RP-initiated logout |
| 3 | kubectl via kubelogin | Public client + structured authn config | API server trusts Keycloak; RBAC on `oidc:` groups |
| 4 | Protect a no-auth UI | oauth2-proxy (`keycloak-oidc` provider) | Group-gated Prometheus with no app changes |
| 5 | MFA by Git commit | Custom `browser-mfa` flow, `browserFlow` switch | One-line realm change forces OTP enrolment |
| 6 | Leaver / time to lockout | Disable user; sessions; token lifetimes | What is cut off immediately and what lingers |
| 7 | Config drift | keycloak-config-cli runs only on sync | UI edits persist until the next commit; contrast with authentik blueprints |
| 8 | Demo app: login and token anatomy | demo-web (auth code + PKCE) | ID vs access vs refresh token, audiences, groups, roles, RP-initiated logout |
| 9 | Demo app: API authorisation | demo-api checks client roles | Same API, three users, three outcomes (200 / 403 / 403) |
| 10 | Demo app: role change by commit | Client role on a group | Tokens are snapshots: new roles appear only after refresh |
| 11 | Machine-to-machine | demo-cli client credentials | Service-account token with its own roles, no user |
| 12 | Revocation: JWT vs introspection | `INTROSPECT` flag on demo-api | Offline validation keeps accepting a disabled user's token until expiry; introspection cuts it off at once |

### Components

| Component | Version (pin) | Role |
| --- | --- | --- |
| kind / `kindest/node` | kind 0.30+, node v1.34.x | Cluster with `--authentication-config` |
| Docker Desktop | 4.x, 6 CPU / 12 GB | Container runtime |
| ArgoCD (argo-cd chart) | 9.7.1 (ArgoCD v3.4.4) | GitOps engine, OIDC client |
| Gitea (gitea chart) | latest at bootstrap, SQLite | In-cluster Git source |
| Sealed Secrets | chart 2.20.0 | Secrets in Git |
| cert-manager | v1.21.2 | Wildcard cert from the lab CA |
| Contour (Gateway API, static) | 1.33.7 (Envoy 1.38.4) | Envoy on hostPorts 80/443 |
| CloudNativePG | chart 0.29.1 (PostgreSQL 18) | PostgreSQL for Keycloak (non-root, PSS-friendly) |
| Keycloak Operator + Keycloak | 26.7.0 | IdP |
| keycloak-config-cli | `latest` (ran as v6.5.1) | Realm as code, run as an ArgoCD PostSync hook. Pin by digest, not by version tag |
| kube-prometheus-stack | chart 92.3.0 (Grafana 13.2.3, Prometheus 3.15.0) | Grafana (OIDC) and Prometheus (protected target) |
| oauth2-proxy | chart 10.7.1 (oauth2-proxy 7.15.5) | Authenticating proxy for Prometheus |
| demo-app (this repo) | 0.1.0, built locally | Flask + Authlib web client; Flask + PyJWT resource server |

Every version above was running together on a working build on 10 Oct 2026. The repo pins all of them except keycloak-config-cli, whose registry tags don't match its internal version numbers: pin it by digest. Keycloak 26.7.0 was released on 9 July 2026 [R1].

### Names used throughout

| Thing | Value |
| --- | --- |
| Cluster | `keycloak-lab` (node `keycloak-lab-control-plane`) |
| Issuer | `https://keycloak.localtest.me/realms/platform` |
| Envoy ClusterIP (pinned) | `10.96.0.250` |
| Git repo | `http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git` |
| Lab CA + secrets | `~/.kc-lab-ca/` |
| Demo users | `alice` (platform admin), `bob` (developer), `carol` (auditor) |
| Demo app URLs | `https://demo.localtest.me` (web), `https://api.localtest.me` (API) |

Every code block below starts with a `# file:` comment giving its path in this repository. Blocks without one are commands run on the Mac.

### How this differs from the authentik lab

| Concern | authentik lab | This lab |
| --- | --- | --- |
| IdP install | Helm chart, bundled Postgres | Keycloak Operator CR + CloudNativePG cluster |
| Config as code | Blueprints, watched and re-applied by the IdP itself | keycloak-config-cli Job, runs only when ArgoCD syncs |
| Groups in tokens | `profile` scope emits `groups` | Custom `groups` client scope with a group-membership mapper |
| No-auth UI protection | Embedded outpost (proxy provider) | oauth2-proxy deployment |
| MFA toggle | One field on the validation stage | Switch `browserFlow` to a custom flow defined in the realm file |

## Quick start: build in one pass

The full build is nine commands. Each is idempotent: re-running one after a failure is safe. The steps that follow explain every file in detail.

```bash
setopt interactive_comments                      # zsh: allow pasted commands with trailing # comments
mkdir -p ~/labs && cd ~/labs
git clone https://github.com/simonjday/keycloak-gitops-lab.git
cd keycloak-gitops-lab                           # the repo root MUST be your working directory

./bootstrap/scripts/00-lab-ca.sh                 # lab CA in ~/.kc-lab-ca, trusted in the System keychain (sudo)
./bootstrap/scripts/01-cluster.sh                # kind cluster; must print "API server: OIDC authentication config and issuer hostAlias present"
./bootstrap/scripts/05-build-demo-app.sh         # build + kind-load the demo image now, so wave 7 never waits
./bootstrap/scripts/02-bootstrap.sh              # Sealed Secrets, Gitea, ArgoCD, root app-of-apps (seeds Gitea)
./bootstrap/scripts/03-secrets.sh                # generate, seal, commit and push every secret
./bootstrap/scripts/06-post-bootstrap.sh         # waits for each wave, sets up git remote, enables ArgoCD SSO
./bootstrap/scripts/04-kubeconfig-users.sh       # kubectl contexts for alice, bob, carol
```

Expected timeline on an M3 with 6 CPU / 12 GB: 2–3 minutes for `01`, about 5 minutes for `02`, and 10–15 minutes for `06` to see every wave Healthy. Watch it with:

```bash
watch -n5 'kubectl get applications -o json | jq -r -f jq/apps-status.jq | column -t'
```

```jq
# file: jq/apps-status.jq
# ArgoCD Applications sorted by sync wave; a missing wave counts as 0 (ArgoCD's default).
.items
| map({ app: .metadata.name,
        wave: ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0") | tonumber),
        sync: (.status.sync.status // "-"),
        health: (.status.health.status // "-") })
| sort_by(.wave, .app)
| (["APP", "WAVE", "SYNC", "HEALTH"] | @tsv),
  (.[] | [.app, (.wave | tostring), .sync, .health] | @tsv)
```

When `06-post-bootstrap.sh` prints its table, every app is Synced/Healthy and the demos are ready. Logins:

```bash
grep -E 'DEMO_USER_PASSWORD|KEYCLOAK_ADMIN_PASSWORD|GRAFANA_ADMIN_PASSWORD' ~/.kc-lab-ca/secrets.env
```

| Where | Username | Password |
| --- | --- | --- |
| Demo users (ArgoCD, Grafana, Prometheus, demo app, kubectl) | `alice`, `bob`, `carol` | `DEMO_USER_PASSWORD` |
| Keycloak admin `https://keycloak.localtest.me/admin` | `admin` | `KEYCLOAK_ADMIN_PASSWORD` |
| ArgoCD local admin `https://argocd.localtest.me` | `admin` | `kubectl get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` (context namespace `argocd`) |
| Grafana break-glass | `admin` | `GRAFANA_ADMIN_PASSWORD` |
| Gitea `https://gitea.localtest.me` | `lab` | `cat ~/.kc-lab-ca/gitea-admin-password` |

### Fixes baked into this version

Each of these broke a real build on Docker Desktop/kind and is now fixed in the repo. They're listed so you recognise the symptom if you adapt the lab.

| Symptom on first build | Cause | Fix in the repo |
| --- | --- | --- |
| Sealed Secrets chart: `index.yaml 404` | Project moved from `bitnami-labs` to the `bitnami` GitHub org | `https://bitnami.github.io/sealed-secrets` in `02-bootstrap.sh` and `root/00` |
| ArgoCD install: `no matches for kind "Application"` | Root app in the chart's `extraObjects` was validated before the chart's CRDs existed | Root app is a separate `argocd-apps` release (`bootstrap/root-app-values.yaml`) |
| `root: app path does not exist` | Git repo initialised in the parent folder, so `root/` was really `keycloak-gitops/root/` | `02-bootstrap.sh` refuses to run unless the repo root is the lab folder |
| `git push` rejected (fetch first) after a re-init | New local history against an old Gitea seed | Bootstrap seed push uses `--force`; later pushes are normal |
| Gateway, HTTPRoutes and CRDs permanently OutOfSync | API-server defaults vs. client-side diff | `controller.diff.server.side: "true"` |
| `http-to-https` route `NoMatchingListenerHostname` | Hostname filter against the hostname-less HTTP listener | Redirect route has no `hostnames` |
| `contour` app stuck Progressing | Contour static mode never writes GatewayClass status | ArgoCD health check for GatewayClass (`argocd-values.yaml`) |
| Fresh build stalls at wave -8; Gateway `InvalidCertificateRef: Secret not found` | Gateway (wave -8) needed the certificate created in wave -7 | Gateway moved to `platform-config`, beside the certificate |
| `monitoring` Degraded; route `service "monitoring/oauth2-proxy" not found` | Prometheus route (wave 5) pointed at a Service created in wave 6 | Route moved into the `oauth2-proxy` app (`components/oauth2-proxy`) |
| Keycloak Operator CrashLoop: `keycloaksamlclients … Not Found` | 26.7 operator also watches the new OIDC/SAML client CRDs | Both CRDs added to `components/keycloak-operator` |
| Realm Job: `Cannot resolve variable 'env:VAR'` | A comment in the realm file contained the substitution syntax | Comment reworded; config-cli substitutes comments too |
| `monitoring` permanently OutOfSync, Grafana rolling | Chart generates a random admin password each render (no `lookup` under ArgoCD) | Fixed Grafana admin from `grafana-admin` SealedSecret |
| oauth2-proxy CrashLoop `Realm does not exist` | Later waves started before the realm Job (a PostSync hook) finished | App-of-apps health waits for child sync operations to finish |
| `git push lab` `Unauthorized` | Keychain held the authentik lab's credential for the same hostname | `06-post-bootstrap.sh` replaces the keychain entry |
| kubectl persona `Unauthorized`; API server logs `invalid bearer token` | Two causes. First, the kubeadm patches were written for `v1beta4`, but kind generates `v1beta3`, so they were silently ignored and the API server had no `--authentication-config`. Second, its own hosts file is a snapshot that never had the issuer entry | Patches rewritten as `v1beta3`; `hostAliases` via a kubeadm patch; `01-cluster.sh` verifies both and stops if either is missing |
| Realm Job `ImagePullBackOff` and `keycloak-config` never finishes | `keycloak-config-cli:6.5.1` is not a registry tag (6.5.1 is only the app's internal version) | Back to `:latest`; pin by digest if needed |

## Prerequisites

### Tooling

```bash
brew install kind helm kubectl argocd kubeseal int128/kubelogin/kubelogin jq yq openssl
```

If Microsoft's `kubelogin` (the Azure/AKS credential plugin) is already installed, Homebrew refuses the int128 formula: both use the same formula and binary name. Install the OIDC plugin through krew instead, which adds only `kubectl-oidc_login`:

```bash
brew install krew
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
kubectl krew install oidc-login
kubectl oidc-login --version
```

### Docker Desktop

```bash
# Docker Desktop → Settings → Resources: 6 CPUs, 12 GB memory, 100 GB disk → Apply & restart
docker context use desktop-linux
docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes, {{.Architecture}}'   # expect 6, ~12.5e9, aarch64
unset KIND_EXPERIMENTAL_PROVIDER
lsof -nP -iTCP:443 -sTCP:LISTEN || echo "443 free"      # stop any other lab (e.g. authentik-lab) first
```

- **Built-in Kubernetes:** leave Docker Desktop's built-in Kubernetes off.
- **File sharing:** `/Users` must be shared into the VM, which is the default. The kind `extraMounts` depend on it.

### Repo layout

```text
keycloak-gitops/
├── bootstrap/
│   ├── kind-config.yaml  authn-config.yaml.tmpl  gitea-values.yaml  argocd-values.yaml
│   └── scripts/
│       ├── 00-lab-ca.sh  01-cluster.sh  02-bootstrap.sh  03-secrets.sh
│       ├── 04-kubeconfig-users.sh  05-build-demo-app.sh  06-post-bootstrap.sh
│       └── kc-sessions.sh  demo-cli-call.sh  99-teardown.sh
├── apps/demo-app/              # demo app source: web.py, api.py, templates/, Dockerfile
├── root/                       # app-of-apps, ordered by sync wave
│   ├── 00-sealed-secrets 01-cert-manager 02-contour 03-coredns 04-platform-config
│   ├── 05-cnpg 06-keycloak-operator 10-argocd 20-keycloak 21-keycloak-config
│   └── 30-monitoring 40-oauth2-proxy 45-demo-app 50-oidc-rbac
├── components/
│   ├── contour/ coredns/ platform-config/ argocd/
│   ├── keycloak-operator/      # upstream Operator manifests, pinned
│   ├── keycloak/               # CNPG Cluster, Keycloak CR, route, admin secret
│   ├── keycloak-config/        # realms/platform.yaml + config-cli Job
│   ├── monitoring/             # kube-prometheus-stack + oauth2-proxy values, extras/
│   ├── oauth2-proxy/           # Prometheus HTTPRoute (chart values live in monitoring/)
│   ├── demo-app/               # Deployments, Services, HTTPRoutes, sealed secret
│   └── oidc-rbac/
└── jq/                         # externalised jq filters
```

## Step 1: Lab root CA

The CA exists before the cluster because the API server must trust Keycloak's issuer at boot. It is separate from the authentik lab's CA.

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/00-lab-ca.sh
# Idempotent: reuses an existing CA in ~/.kc-lab-ca
set -euo pipefail
CA_DIR=${CA_DIR:-$HOME/.kc-lab-ca}
mkdir -p "$CA_DIR" && chmod 700 "$CA_DIR" && cd "$CA_DIR"

[[ -f ca.key ]] || openssl genrsa -out ca.key 4096
[[ -f ca.crt ]] || openssl req -x509 -new -key ca.key -sha256 -days 825 \
  -subj "/CN=keycloak-lab root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.crt

# Trust it system-wide (Safari, Chrome, Apple-native tools)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ca.crt

openssl x509 -in ca.crt -noout -subject -enddate
```

| Consumer | Trust mechanism |
| --- | --- |
| macOS browsers | System keychain (Firefox: `security.enterprise_roots.enabled`) |
| kubelogin, Homebrew curl/git | `--certificate-authority` / `--cacert` / `http.sslCAInfo` |
| kube-apiserver | PEM inlined in `AuthenticationConfiguration` |
| cert-manager | `lab-ca` ClusterIssuer from a SealedSecret |
| ArgoCD | `rootCA` in `oidc.config` |
| Grafana, oauth2-proxy, demo app | `lab-ca` ConfigMap mounted at `/etc/ssl/lab` (demo app via `REQUESTS_CA_BUNDLE`) |
| keycloak-config-cli | Lab only: `KEYCLOAK_SSLVERIFY=false` (see Step 6) |

## Step 2: kind cluster

```yaml
# file: bootstrap/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: keycloak-lab
networking:
  serviceSubnet: 10.96.0.0/16          # 10.96.0.250 is pinned for Envoy
nodes:
  - role: control-plane
    image: kindest/node:v1.34.0        # pin the digest from the kind release notes
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
    extraMounts:
      - hostPath: __RENDERED_DIR__     # replaced by 01-cluster.sh; /Users is shared into the Docker Desktop VM
        containerPath: /etc/kubernetes/authn
        readOnly: true
    kubeadmConfigPatches:
      # kind (0.30, node v1.34) generates kubeadm.k8s.io/v1beta3, and patches only apply when the apiVersion matches.
      # v1beta4-style patches (list-form extraArgs) are silently ignored. Check with:
      #   docker exec <node> grep -n '^apiVersion' /kind/kubeadm.conf
      - |
        apiVersion: kubeadm.k8s.io/v1beta3
        kind: InitConfiguration
        patches:
          directory: /etc/kubernetes/authn/patches   # kube-apiserver+strategic.yaml: hostAliases for the issuer
      - |
        apiVersion: kubeadm.k8s.io/v1beta3
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            authentication-config: /etc/kubernetes/authn/authn-config.yaml
          extraVolumes:
            - name: authn
              hostPath: /etc/kubernetes/authn
              mountPath: /etc/kubernetes/authn
              readOnly: true
              pathType: Directory
```

```yaml
# file: bootstrap/authn-config.yaml.tmpl
# v1beta1 is accepted on 1.30-1.34; switch to apiserver.config.k8s.io/v1 once you move to a release where it is GA.
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://keycloak.localtest.me/realms/platform   # Keycloak issuers have no trailing slash
      audiences:
        - kubernetes                   # = clientId of the Keycloak client
      certificateAuthority: |
__CA_PEM__
    claimMappings:
      username:
        claim: preferred_username
        prefix: "oidc:"
      groups:
        claim: groups                  # from the realm's "groups" client scope (full.path=false)
        prefix: "oidc:"
```

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/01-cluster.sh
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
```

The issuer hostname must resolve to Envoy from three places:

| Caller | Resolves `keycloak.localtest.me` via | Lands on |
| --- | --- | --- |
| Browser, kubelogin | Public DNS → 127.0.0.1 | Docker Desktop port forward → node :443 → Envoy |
| kube-apiserver (hostNetwork) | Its own kubelet-managed hosts file, given the entry via `hostAliases` (kubeadm patch from `01-cluster.sh`) | 10.96.0.250 → Envoy |
| Pods (ArgoCD, Grafana, oauth2-proxy, config-cli, demo app) | CoreDNS `hosts` block (Step 4) | 10.96.0.250 → Envoy |

The Keycloak CR pins `hostname` to the public URL, so every token carries the same `iss` no matter which path the request took.

## Step 3: Bootstrap Gitea, Sealed Secrets and ArgoCD

These four Helm installs are the only imperative steps. ArgoCD then adopts itself and Sealed Secrets, and everything else arrives through the `root` app-of-apps.

### Gitea values

```yaml
# file: bootstrap/gitea-values.yaml
# PRODUCTION: chart defaults deploy postgresql-ha + valkey-cluster (HA, ~1.5 GB). This lab profile is SQLite + in-memory.
postgresql-ha: { enabled: false }
postgresql: { enabled: false }
valkey-cluster: { enabled: false }
valkey: { enabled: false }
persistence:
  enabled: true
  size: 5Gi
gitea:
  admin:
    username: lab
    email: lab@localtest.me          # password injected by 02-bootstrap.sh
  config:
    database: { DB_TYPE: sqlite3 }
    session: { PROVIDER: memory }
    cache: { ADAPTER: memory }
    queue: { TYPE: level }
    server:
      ROOT_URL: https://gitea.localtest.me/
```

### ArgoCD values

Alongside the app-of-apps health check, this adds a health check for the `Keycloak` CR. Without it, ArgoCD would mark the Keycloak app Healthy before Keycloak is ready, and the config job in the next sync wave would race it. `oidc.config` stays commented until Step 7.

```yaml
# file: bootstrap/argocd-values.yaml
global:
  domain: argocd.localtest.me
configs:
  params:
    server.insecure: true            # TLS terminates at Envoy
    # Diff server-side: Gateway API objects and CRDs get API-server defaults that a client-side diff
    # reports as permanent drift (OutOfSync after every successful sync).
    controller.diff.server.side: "true"
  cm:
    url: https://argocd.localtest.me
    admin.enabled: true              # set false after use case 1 proves SSO
    # Lets sync waves wait for child Applications to be Healthy
    # Contour static provisioning (gatewayRef) never writes GatewayClass status, so "Unknown / Waiting for
    # controller" is normal and would leave the contour app Progressing forever. Only Accepted=False is unhealthy.
    resource.customizations.health.gateway.networking.k8s.io_GatewayClass: |
      hs = { status = "Healthy", message = "GatewayClass present" }
      if obj.status ~= nil and obj.status.conditions ~= nil then
        for _, c in ipairs(obj.status.conditions) do
          if c.type == "Accepted" and c.status == "False" then
            hs.status = "Degraded"
            hs.message = c.message
          end
        end
      end
      return hs
    resource.customizations.health.argoproj.io_Application: |
      hs = { status = "Progressing", message = "" }
      if obj.status ~= nil and obj.status.health ~= nil then
        hs.status = obj.status.health.status
        if obj.status.health.message ~= nil then hs.message = obj.status.health.message end
      end
      -- Hold the next wave until the child's sync (including PostSync hooks such as the realm import) finishes.
      if obj.status ~= nil and obj.status.operationState ~= nil and obj.status.operationState.phase == "Running" then
        hs.status = "Progressing"
        hs.message = "sync operation running"
      end
      return hs
    # ArgoCD has no built-in health check for the Keycloak CR; without this it reports Healthy immediately
    resource.customizations.health.k8s.keycloak.org_Keycloak: |
      hs = { status = "Progressing", message = "Waiting for Keycloak" }
      if obj.status ~= nil and obj.status.conditions ~= nil then
        for _, c in ipairs(obj.status.conditions) do
          if c.type == "Ready" and c.status == "True" then hs.status = "Healthy"; hs.message = "Ready" end
          if c.type == "HasErrors" and c.status == "True" then hs.status = "Degraded"; hs.message = c.message end
        end
      end
      return hs
    # Step 7: uncomment once the platform realm exists, and paste ~/.kc-lab-ca/ca.crt into rootCA
    # oidc.config: |
    #   name: Keycloak
    #   issuer: https://keycloak.localtest.me/realms/platform
    #   clientID: argocd
    #   clientSecret: $argocd-oidc-keycloak:clientSecret
    #   requestedScopes: [openid, profile, email, groups]
    #   rootCA: |
    #     -----BEGIN CERTIFICATE-----
    #     ...
    #     -----END CERTIFICATE-----
  rbac:
    policy.default: role:readonly
    scopes: "[groups]"
    policy.csv: |
      p, role:developer, applications, get,  */*, allow
      p, role:developer, applications, sync, */*, allow
      p, role:developer, logs,         get,  */*, allow
      g, ArgoCD Admins, role:admin
      g, Developers,    role:developer
```

### Root app-of-apps values

The root Application is a separate Helm release (`argocd-apps` chart) installed after ArgoCD. Putting it in the ArgoCD chart's `extraObjects` fails on a fresh cluster: Helm validates the `Application` kind before the chart has installed the CRD.

```yaml
# file: bootstrap/root-app-values.yaml
# Values for the argocd-apps chart: creates the root app-of-apps after ArgoCD (and its CRDs) exist.
# Installed once by 02-bootstrap.sh as a separate Helm release ("root-app").
applications:
  root:
    namespace: argocd
    project: default
    source:
      repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      path: root
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      automated: { prune: true, selfHeal: true }
```

### Bootstrap script

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/02-bootstrap.sh
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
```

### Self-management Applications

```yaml
# file: root/00-sealed-secrets.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: default
  source:
    repoURL: https://bitnami.github.io/sealed-secrets
    chart: sealed-secrets
    targetRevision: 2.20.0             # verified 10 Oct 2026
    helm:
      releaseName: sealed-secrets
      valuesObject:
        fullnameOverride: sealed-secrets-controller
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

```yaml
# file: root/10-argocd.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
spec:
  project: default
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 9.7.1
      helm:
        releaseName: argocd
        valueFiles:
          - $values/bootstrap/argocd-values.yaml
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      ref: values
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      path: components/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: false, selfHeal: true }   # never let ArgoCD prune itself
    syncOptions: [ServerSideApply=true]
```

### Generate and seal every secret

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/03-secrets.sh
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
```

It writes eight files:

| File | Contents |
| --- | --- |
| `components/platform-config/lab-root-ca.sealed.yaml` | Lab CA for cert-manager |
| `components/keycloak/keycloak-bootstrap-admin.sealed.yaml` | Keycloak bootstrap admin |
| `components/keycloak-config/keycloak-config-env.sealed.yaml` | Client secrets + demo password for realm substitution |
| `components/argocd/argocd-oidc-keycloak.sealed.yaml` | ArgoCD client secret |
| `components/monitoring/extras/grafana-oidc.sealed.yaml` | Grafana client secret |
| `components/monitoring/extras/grafana-admin.sealed.yaml` | Grafana local admin (fixed, so ArgoCD doesn't see drift) |
| `components/monitoring/extras/oauth2-proxy.sealed.yaml` | oauth2-proxy client + cookie secrets |
| `components/demo-app/demo-app.sealed.yaml` | demo-web client secret, session key, demo-api introspection secret |

It also writes `lab-ca.crt`, the public CA cert, for Grafana, oauth2-proxy and the demo app. The Keycloak database password is not on this list: CloudNativePG generates it in-cluster (Step 5).

The script finishes by committing the sealed files and pushing them to Gitea through a temporary port-forward. `gitea.localtest.me` can't be used yet, because its certificate depends on the CA secret being pushed. Re-running it reseals the same values from `secrets.env`.

## Step 4: Platform layer

### Run order

1. `02-bootstrap.sh` seeds Gitea with the whole repo, and the root app starts syncing in wave order. Apps that need sealed secrets wait (Degraded) until step 2.
2. `03-secrets.sh` seals every secret and pushes the files, and the waiting apps recover on their own.
3. `06-post-bootstrap.sh` waits for each wave, switches git to `https://gitea.localtest.me`, and turns on ArgoCD SSO once the realm exists (Step 7).

Waves and what holds each one:

| Wave | Apps | Gate before the next wave |
| --- | --- | --- |
| -10 / -9 | sealed-secrets, cert-manager | Controllers ready |
| -8 | contour, coredns-config | Contour and Envoy ready; GatewayClass health check passes |
| -7 | platform-config | CA unsealed, wildcard cert issued, Gateway (defined here) programmed |
| -6 / -5 | cnpg, keycloak-operator, argocd | Operators running; ArgoCD adopts itself |
| 0 | keycloak | Postgres up, Keycloak CR Ready |
| 1 | keycloak-config | Realm Job (PostSync hook) finished |
| 5 | monitoring, oidc-rbac | Prometheus and Grafana ready |
| 6 | oauth2-proxy | OIDC discovery against the realm succeeds; Prometheus route (defined here) resolves |
| 7 | demo-app | Image loaded by `05-build-demo-app.sh` |

### Root Applications

```yaml
# file: root/01-cert-manager.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-9" }
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.21.2           # verified 10 Oct 2026
    helm:
      valuesObject:
        crds: { enabled: true }
  destination: { server: https://kubernetes.default.svc, namespace: cert-manager }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

```yaml
# file: root/02-contour.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: contour
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-8" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/contour
  destination: { server: https://kubernetes.default.svc, namespace: projectcontour }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

```yaml
# file: root/03-coredns.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coredns-config
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-8" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/coredns
  destination: { server: https://kubernetes.default.svc, namespace: kube-system }
  syncPolicy:
    automated: { prune: false, selfHeal: true }   # never prune the cluster Corefile
    syncOptions: [ServerSideApply=true]
```

```yaml
# file: root/04-platform-config.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-config
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-7" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/platform-config
  destination: { server: https://kubernetes.default.svc }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

### Contour with a pinned Envoy IP

```yaml
# file: components/contour/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  # Pin to the Contour release you run; check that the render still names the Gateway "contour".
  - https://raw.githubusercontent.com/projectcontour/contour/release-1.33/examples/render/contour-gateway.yaml
patches:
  - target: { kind: Service, name: envoy, namespace: projectcontour }
    patch: |
      apiVersion: v1
      kind: Service
      metadata: { name: envoy, namespace: projectcontour }
      spec:
        type: ClusterIP
        clusterIP: 10.96.0.250        # immutable: set on first sync only
        externalTrafficPolicy: null
  - target: { kind: DaemonSet, name: envoy, namespace: projectcontour }
    patch: |
      apiVersion: apps/v1
      kind: DaemonSet
      metadata: { name: envoy, namespace: projectcontour }
      spec:
        template:
          spec:
            nodeSelector: { ingress-ready: "true" }
            containers:
              - name: envoy
                ports:
                  - { containerPort: 8080, hostPort: 80 }
                  - { containerPort: 8443, hostPort: 443 }
  # The Gateway lives in platform-config (wave -7) beside the wildcard certificate its HTTPS listener needs.
  # Kept here, it could never go Healthy before that certificate existed, deadlocking the sync waves.
  - target: { group: gateway.networking.k8s.io, kind: Gateway, name: contour }
    patch: |
      $patch: delete
      apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      metadata: { name: contour, namespace: projectcontour }
```

### CoreDNS hosts block

```yaml
# file: components/coredns/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        hosts {
           10.96.0.250 keycloak.localtest.me argocd.localtest.me grafana.localtest.me prometheus.localtest.me gitea.localtest.me demo.localtest.me api.localtest.me
           fallthrough
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

```yaml
# file: components/coredns/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [configmap.yaml]
```

### CA issuer, wildcard cert, shared routes

```yaml
# file: components/platform-config/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - lab-root-ca.sealed.yaml           # written by 03-secrets.sh
  - cluster-issuer.yaml
  - wildcard-cert.yaml
  - gateway.yaml
  - http-redirect.yaml
  - gitea-route.yaml
```

```yaml
# file: components/platform-config/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-ca
spec:
  ca:
    secretName: lab-root-ca           # in the cert-manager namespace
```

```yaml
# file: components/platform-config/wildcard-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-localtest-me
  namespace: projectcontour
spec:
  secretName: wildcard-localtest-me
  issuerRef: { kind: ClusterIssuer, name: lab-ca }
  dnsNames: ["*.localtest.me"]
  duration: 2160h
  renewBefore: 360h
```

```yaml
# file: components/platform-config/gateway.yaml
# The single Gateway for the lab. Contour's static config (from the contour render) binds to projectcontour/contour,
# and the GatewayClass "example" comes from that render. Lives here, not in components/contour, because the HTTPS
# listener needs wildcard-localtest-me, which cert-manager issues in this same app.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: contour
  namespace: projectcontour
spec:
  gatewayClassName: example
  listeners:
    - name: http
      protocol: HTTP
      port: 80                        # Contour maps 80/443 to Envoy 8080/8443
      allowedRoutes: { namespaces: { from: All } }
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.localtest.me"
      tls:
        mode: Terminate
        certificateRefs: [{ name: wildcard-localtest-me }]
      allowedRoutes: { namespaces: { from: All } }
```

```yaml
# file: components/platform-config/http-redirect.yaml
# Redirects every plain-HTTP request to HTTPS. No hostnames filter: on Contour a "*.localtest.me" filter
# against the hostname-less http listener was rejected (NoMatchingListenerHostname), leaving the route unaccepted.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
  namespace: projectcontour
spec:
  parentRefs: [{ name: contour, sectionName: http }]
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect: { scheme: https, statusCode: 301 }
```

```yaml
# file: components/platform-config/gitea-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gitea
  namespace: gitea
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [gitea.localtest.me]
  rules:
    - backendRefs: [{ name: gitea-http, port: 3000 }]
```

### ArgoCD route

```yaml
# file: components/argocd/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - httproute.yaml
  - argocd-oidc-keycloak.sealed.yaml   # written by 03-secrets.sh
```

```yaml
# file: components/argocd/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [argocd.localtest.me]
  rules:
    - backendRefs: [{ name: argocd-server, port: 80 }]
```

### Check the layer

```bash
curl -sI https://argocd.localtest.me | head -1                     # HTTP/2 200, no TLS error
kubectl run dnscheck --rm -it --restart=Never --image=busybox:1.36 -- nslookup keycloak.localtest.me
                                                                     # Address: 10.96.0.250
```

## Step 5: CloudNativePG, Keycloak Operator and Keycloak

Keycloak deploys in three layers:

1. The CloudNativePG operator (wave -6).
2. The Keycloak Operator with its CRDs (wave -6). From 26.7 that includes `KeycloakOIDCClient` and `KeycloakSAMLClient`; the operator exits at startup if those CRDs are missing.
3. A `keycloak` app (wave 0) holding the database `Cluster`, the `Keycloak` CR, its route and the bootstrap admin secret.

The Operator does not manage the database, so CloudNativePG provides it [R3].

### Root Applications

```yaml
# file: root/05-cnpg.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-6" }
spec:
  project: default
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    chart: cloudnative-pg
    targetRevision: 0.29.1             # verified 10 Oct 2026
  destination: { server: https://kubernetes.default.svc, namespace: cnpg-system }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

```yaml
# file: root/06-keycloak-operator.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak-operator
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-6" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/keycloak-operator
  destination: { server: https://kubernetes.default.svc, namespace: keycloak }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, CreateNamespace=true]
```

```yaml
# file: root/20-keycloak.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "0" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/keycloak
  destination: { server: https://kubernetes.default.svc, namespace: keycloak }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]
```

### Operator manifests

```yaml
# file: components/keycloak-operator/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: keycloak
resources:
  - namespace.yaml
  # Upstream Operator manifests, pinned to the Keycloak release. Bump all together.
  # 26.7 added KeycloakOIDCClient / KeycloakSAMLClient: the operator exits at startup if their CRDs are missing.
  - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
  - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
  - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloakoidcclients.k8s.keycloak.org-v1.yml
  - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloaksamlclients.k8s.keycloak.org-v1.yml
  - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/kubernetes.yml
```

```yaml
# file: components/keycloak-operator/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
```

### Database, Keycloak CR and route

```yaml
# file: components/keycloak/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: keycloak
resources:
  - keycloak-bootstrap-admin.sealed.yaml   # written by 03-secrets.sh
  - postgres-cluster.yaml
  - keycloak.yaml
  - httproute.yaml
```

```yaml
# file: components/keycloak/postgres-cluster.yaml
# CloudNativePG creates Service keycloak-db-rw and Secret keycloak-db-app (keys: username, password, …).
# Lab: one instance. PRODUCTION: instances: 3, backups to object storage, PodMonitor enabled.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
spec:
  instances: 1
  storage:
    size: 2Gi
  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
```

```yaml
# file: components/keycloak/keycloak.yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
spec:
  instances: 1                         # PRODUCTION: 2+ (embedded Infinispan clusters the pods)
  db:
    vendor: postgres
    host: keycloak-db-rw
    database: keycloak
    usernameSecret: { name: keycloak-db-app, key: username }
    passwordSecret: { name: keycloak-db-app, key: password }
  bootstrapAdmin:
    user:
      secret: keycloak-bootstrap-admin # keys: username, password. Temporary admin; replace with a realm admin later
  hostname:
    hostname: https://keycloak.localtest.me   # fixes the issuer for every caller, internal or external
  proxy:
    headers: xforwarded                # Envoy/Contour sends X-Forwarded-*
  http:
    httpEnabled: true                  # TLS terminates at Envoy
  ingress:
    enabled: false                     # HTTPRoute instead
  additionalOptions:
    - name: metrics-enabled
      value: "true"
  resources:
    requests: { cpu: 250m, memory: 1Gi }
    limits: { memory: 2Gi }
```

```yaml
# file: components/keycloak/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [keycloak.localtest.me]
  rules:
    - backendRefs: [{ name: keycloak-service, port: 8080 }]
```

Key choices in the CR:

- **`hostname.hostname`** is the full public URL, so the issuer is fixed for every caller.
- **`proxy.headers: xforwarded`** trusts Envoy's forwarded headers.
- **`httpEnabled`** is set because TLS terminates at Envoy.
- **The database secret** is the one CloudNativePG generates (`keycloak-db-app`).
- **Health** is served on the management port 9000 by default.

### Verify

```bash
argocd app wait keycloak --health --timeout 900
kubectl get keycloaks.k8s.keycloak.org,clusters.postgresql.cnpg.io --all-namespaces
curl -s https://keycloak.localtest.me/realms/master/.well-known/openid-configuration | jq -r .issuer
                                                                     # https://keycloak.localtest.me/realms/master
```

Log in at `https://keycloak.localtest.me/admin` as `admin` with `KEYCLOAK_ADMIN_PASSWORD` from `~/.kc-lab-ca/secrets.env`. Keycloak shows a banner saying this is a temporary admin; that is expected for the bootstrap account.

## Step 6: Realm as code with keycloak-config-cli

The whole `platform` realm lives in one YAML file:
- groups
- the `groups` client scope
- four clients
- three demo users
- a custom MFA flow

keycloak-config-cli applies it through the admin API, and secrets come in through `$(env:VAR)` substitution. The CLI runs as an ArgoCD PostSync hook, so every commit that changes the realm file re-runs it.

### Why not `KeycloakRealmImport`?

The Operator's `KeycloakRealmImport` CR is the official route. In my understanding it only creates a realm that does not exist yet and does not update an existing one; check this against the current Operator guide before relying on it. That makes it a bootstrap tool, not a reconcile loop. keycloak-config-cli is the community tool usually used to fill that gap. It is maintained by adorsys rather than the Keycloak project [R4].

### Application

```yaml
# file: root/21-keycloak-config.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak-config
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "1" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/keycloak-config
  destination: { server: https://kubernetes.default.svc, namespace: keycloak }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

```yaml
# file: components/keycloak-config/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: keycloak
resources:
  - keycloak-config-env.sealed.yaml    # written by 03-secrets.sh
  - config-job.yaml
configMapGenerator:
  - name: keycloak-realms
    files:
      - realms/platform.yaml
# The hash suffix is kept on purpose: a realm change produces a new ConfigMap name, ArgoCD sees a diff,
# auto-syncs the app, and the PostSync hook (config-job.yaml) re-runs against the new realm file.
```

```yaml
# file: components/keycloak-config/config-job.yaml
# keycloak-config-cli applies realms/*.yaml through the Keycloak admin API on every ArgoCD sync of this app.
# It only reconciles when this app syncs; UI drift persists until the next commit (see use case 7).
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-config-cli
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      securityContext: { seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: config-cli
          image: quay.io/adorsys/keycloak-config-cli:latest   # ran as v6.5.1 against Keycloak 26.7.0 on 10 Oct 2026; "6.5.1" is NOT a registry tag. To pin, use the digest: docker pull …:latest && docker inspect --format "{{index .RepoDigests 0}}"
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
          env:
            # Public URL so admin-API tokens carry the same issuer Keycloak advertises
            - { name: KEYCLOAK_URL, value: "https://keycloak.localtest.me" }
            - { name: KEYCLOAK_SSLVERIFY, value: "false" }     # lab: in-cluster hop to Envoy with the lab CA; mount a truststore in production
            - { name: KEYCLOAK_AVAILABILITYCHECK_ENABLED, value: "true" }
            - { name: KEYCLOAK_AVAILABILITYCHECK_TIMEOUT, value: "180s" }
            - { name: IMPORT_FILES_LOCATIONS, value: "/config/*" }
            - { name: IMPORT_VARSUBSTITUTION_ENABLED, value: "true" }
            - name: KEYCLOAK_USER
              valueFrom: { secretKeyRef: { name: keycloak-bootstrap-admin, key: username } }
            - name: KEYCLOAK_PASSWORD
              valueFrom: { secretKeyRef: { name: keycloak-bootstrap-admin, key: password } }
          envFrom:
            - secretRef: { name: keycloak-config-env }
          volumeMounts:
            - { name: realms, mountPath: /config, readOnly: true }
      volumes:
        - name: realms
          configMap: { name: keycloak-realms }
```

### The realm

```yaml
# file: components/keycloak-config/realms/platform.yaml
# Applied by keycloak-config-cli. Values written as env placeholders come from the keycloak-config-env Secret.
realm: platform
enabled: true
displayName: Platform Lab
sslRequired: external
bruteForceProtected: true
accessTokenLifespan: 300               # 5 min: what use case 6 measures
ssoSessionIdleTimeout: 1800
browserFlow: browser                   # use case 5: change to browser-mfa

roles:
  client:
    demo-api:                          # client roles the demo API checks
      - { name: reader, description: "Read endpoints of the demo API" }
      - { name: admin, description: "Admin endpoints of the demo API" }

groups:
  - name: Platform Engineers
    clientRoles: { demo-api: [reader, admin] }
  - name: ArgoCD Admins
  - name: Grafana Admins
  - name: Grafana Editors
  - name: Developers
    clientRoles: { demo-api: [reader] }   # use case 10: add admin here
  - name: Auditors                     # no demo-api roles: carol gets 403 from the API

clientScopes:
  - name: groups
    protocol: openid-connect
    attributes:
      include.in.token.scope: "true"
      display.on.consent.screen: "false"
    protocolMappers:
      - name: groups
        protocol: openid-connect
        protocolMapper: oidc-group-membership-mapper
        config:
          claim.name: groups
          full.path: "false"           # "Platform Engineers", not "/Platform Engineers"
          id.token.claim: "true"
          access.token.claim: "true"
          userinfo.token.claim: "true"
          introspection.token.claim: "true"

authenticationFlows:
  # Use case 5: password + mandatory OTP. Users without OTP are sent to enrolment.
  - alias: browser-mfa
    description: Browser login with mandatory OTP
    providerId: basic-flow
    topLevel: true
    builtIn: false
    authenticationExecutions:
      - { authenticator: auth-cookie, requirement: ALTERNATIVE, priority: 10, authenticatorFlow: false, userSetupAllowed: false }
      - { flowAlias: browser-mfa-forms, requirement: ALTERNATIVE, priority: 20, authenticatorFlow: true, userSetupAllowed: false }
  - alias: browser-mfa-forms
    description: Username, password, OTP
    providerId: basic-flow
    topLevel: false
    builtIn: false
    authenticationExecutions:
      - { authenticator: auth-username-password-form, requirement: REQUIRED, priority: 10, authenticatorFlow: false, userSetupAllowed: false }
      - { authenticator: auth-otp-form, requirement: REQUIRED, priority: 20, authenticatorFlow: false, userSetupAllowed: false }

clients:
  - clientId: argocd
    name: ArgoCD
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:ARGOCD_CLIENT_SECRET)
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    redirectUris:
      - https://argocd.localtest.me/auth/callback
      - http://localhost:8085/auth/callback       # argocd login --sso
    webOrigins: ["+"]
    attributes:
      post.logout.redirect.uris: https://argocd.localtest.me/*
    defaultClientScopes: [web-origins, acr, basic, profile, roles, email, groups]

  - clientId: grafana
    name: Grafana
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:GRAFANA_CLIENT_SECRET)
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    redirectUris: [https://grafana.localtest.me/login/generic_oauth]
    webOrigins: ["+"]
    attributes:
      pkce.code.challenge.method: S256
      post.logout.redirect.uris: https://grafana.localtest.me/login
    defaultClientScopes: [web-origins, acr, basic, profile, roles, email, groups]

  - clientId: kubernetes
    name: Kubernetes API
    enabled: true
    publicClient: true                 # kubelogin cannot keep a secret
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    redirectUris: [http://localhost:8000, http://localhost:18000]
    attributes:
      pkce.code.challenge.method: S256
      access.token.lifespan: "300"
    defaultClientScopes: [web-origins, acr, basic, profile, roles, email, groups]

  - clientId: oauth2-proxy
    name: Prometheus (via oauth2-proxy)
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:OAUTH2_PROXY_CLIENT_SECRET)
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    redirectUris: [https://prometheus.localtest.me/oauth2/callback]
    attributes:
      pkce.code.challenge.method: S256
    protocolMappers:
      - name: aud-oauth2-proxy         # oauth2-proxy validates aud on the access token
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: oauth2-proxy
          id.token.claim: "false"
          access.token.claim: "true"
    defaultClientScopes: [web-origins, acr, basic, profile, roles, email, groups]

  # ---- Demo application (Step 8) ----
  - clientId: demo-web
    name: Demo web app
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:DEMO_WEB_CLIENT_SECRET)
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    redirectUris: [https://demo.localtest.me/callback]
    webOrigins: ["+"]
    attributes:
      pkce.code.challenge.method: S256
      post.logout.redirect.uris: https://demo.localtest.me/*
    protocolMappers:
      - name: aud-demo-api             # access tokens issued to demo-web are valid for demo-api
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: demo-api
          id.token.claim: "false"
          access.token.claim: "true"
    defaultClientScopes: [web-origins, acr, basic, profile, roles, email, groups]

  - clientId: demo-api                 # resource server: owns the client roles, uses its secret only for introspection
    name: Demo API
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:DEMO_API_CLIENT_SECRET)
    standardFlowEnabled: false
    directAccessGrantsEnabled: false
    serviceAccountsEnabled: false
    defaultClientScopes: [basic]

  - clientId: demo-cli                 # machine-to-machine client (client credentials)
    name: Demo CLI / batch job
    enabled: true
    publicClient: false
    clientAuthenticatorType: client-secret
    secret: $(env:DEMO_CLI_CLIENT_SECRET)
    standardFlowEnabled: false
    directAccessGrantsEnabled: false
    serviceAccountsEnabled: true
    protocolMappers:
      - name: aud-demo-api
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: demo-api
          id.token.claim: "false"
          access.token.claim: "true"
    defaultClientScopes: [basic, roles]

users:
  - username: service-account-demo-cli # the service account Keycloak creates for demo-cli
    enabled: true
    serviceAccountClientId: demo-cli
    clientRoles: { demo-api: [reader] }
  - username: alice
    enabled: true
    email: alice@localtest.me
    emailVerified: true
    firstName: Alice
    lastName: Admin
    credentials: [{ type: password, value: $(env:DEMO_USER_PASSWORD), temporary: false }]
    groups: ["/Platform Engineers", "/ArgoCD Admins", "/Grafana Admins"]
  - username: bob
    enabled: true                      # use case 6 (GitOps path): set to false
    email: bob@localtest.me
    emailVerified: true
    firstName: Bob
    lastName: Developer
    credentials: [{ type: password, value: $(env:DEMO_USER_PASSWORD), temporary: false }]
    groups: ["/Developers", "/Grafana Editors"]
  - username: carol
    enabled: true
    email: carol@localtest.me
    emailVerified: true
    firstName: Carol
    lastName: Auditor
    credentials: [{ type: password, value: $(env:DEMO_USER_PASSWORD), temporary: false }]
    groups: ["/Auditors"]
```

| User | Groups | ArgoCD | Grafana | kubectl | Prometheus |
| --- | --- | --- | --- | --- | --- |
| alice | Platform Engineers, ArgoCD Admins, Grafana Admins | admin | Admin | cluster-admin | allowed |
| bob | Developers, Grafana Editors | get + sync | Editor | edit in `demo` | denied |
| carol | Auditors | read-only | Viewer | view | denied |

Demo-app roles (client roles on `demo-api`, granted through groups): alice `reader` + `admin`, bob `reader`, carol none. The `demo-cli` service account has `reader`.

### Verify

```bash
kubectl logs job/keycloak-config-cli | tail -5   # with your context namespace set to keycloak; look for "keycloak-config-cli ran in"
curl -s https://keycloak.localtest.me/realms/platform/.well-known/openid-configuration | jq -r .issuer
                                                                        # https://keycloak.localtest.me/realms/platform
```

## Step 7: Wire the clients

### Post-bootstrap automation

`06-post-bootstrap.sh` does this step for you. It waits for each wave, sets up the HTTPS git remote with the lab CA and a keychain credential, waits until the `platform` realm answers, writes `oidc.config` into the ArgoCD values with the CA indented, and commits and pushes it. It finishes by waiting for the remaining apps.

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/06-post-bootstrap.sh
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
```

### ArgoCD

This is the block the script writes into `bootstrap/argocd-values.yaml`. The RBAC block is already live.

```yaml
# file: bootstrap/argocd-values.yaml  (configs.cm, written by 06-post-bootstrap.sh)
    oidc.config: |
      name: Keycloak
      issuer: https://keycloak.localtest.me/realms/platform
      clientID: argocd
      clientSecret: $argocd-oidc-keycloak:clientSecret
      requestedScopes: [openid, profile, email, groups]
      rootCA: |
        -----BEGIN CERTIFICATE-----
        ...contents of ~/.kc-lab-ca/ca.crt...
        -----END CERTIFICATE-----
```

### kube-prometheus-stack with Grafana OIDC

```yaml
# file: root/30-monitoring.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "5" }
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 92.3.0             # verified 10 Oct 2026
      helm:
        releaseName: kube-prometheus-stack   # Prometheus Service name used by the proxy blueprint
        valueFiles: [$values/components/monitoring/values.yaml]
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      ref: values
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      path: components/monitoring/extras
  destination: { server: https://kubernetes.default.svc, namespace: monitoring }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

```yaml
# file: components/monitoring/values.yaml
grafana:
  # The chart would generate a random admin password on every render (its Secret lookup does not run under
  # ArgoCD), leaving the Secret and Deployment permanently OutOfSync. Use a fixed one from a SealedSecret.
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  grafana.ini:
    server:
      root_url: https://grafana.localtest.me
    auth:
      signout_redirect_url: https://keycloak.localtest.me/realms/platform/protocol/openid-connect/logout?client_id=grafana&post_logout_redirect_uri=https%3A%2F%2Fgrafana.localtest.me%2Flogin
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      client_id: grafana
      client_secret: $__file{/etc/secrets/grafana-oidc/client_secret}
      scopes: openid profile email groups
      auth_url: https://keycloak.localtest.me/realms/platform/protocol/openid-connect/auth
      token_url: https://keycloak.localtest.me/realms/platform/protocol/openid-connect/token
      api_url: https://keycloak.localtest.me/realms/platform/protocol/openid-connect/userinfo
      use_pkce: true
      tls_client_ca: /etc/ssl/lab/ca.crt
      login_attribute_path: preferred_username
      role_attribute_path: >-
        contains(groups, 'Grafana Admins') && 'Admin' ||
        contains(groups, 'Grafana Editors') && 'Editor' || 'Viewer'
  extraSecretMounts:
    - name: grafana-oidc
      secretName: grafana-oidc
      mountPath: /etc/secrets/grafana-oidc
      readOnly: true
  extraConfigmapMounts:
    - name: lab-ca
      configMap: lab-ca
      mountPath: /etc/ssl/lab
      readOnly: true

prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    retention: 2d

alertmanager:
  enabled: false                       # lab: not needed for the demos
```

```yaml
# file: components/monitoring/extras/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - grafana-oidc.sealed.yaml           # written by 03-secrets.sh
  - grafana-admin.sealed.yaml          # written by 03-secrets.sh
  - oauth2-proxy.sealed.yaml           # written by 03-secrets.sh
  - httproute.yaml
configMapGenerator:
  - name: lab-ca
    files: [ca.crt=lab-ca.crt]         # copied from ~/.kc-lab-ca/ca.crt by 03-secrets.sh
generatorOptions:
  disableNameSuffixHash: true
```

```yaml
# file: components/monitoring/extras/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [grafana.localtest.me]
  rules:
    - backendRefs: [{ name: kube-prometheus-stack-grafana, port: 80 }]
```

### oauth2-proxy in front of Prometheus

```yaml
# file: root/40-oauth2-proxy.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oauth2-proxy
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "6" }
spec:
  project: default
  sources:
    - repoURL: https://oauth2-proxy.github.io/manifests
      chart: oauth2-proxy
      targetRevision: 10.7.1             # verified 10 Oct 2026
      helm:
        releaseName: oauth2-proxy
        valueFiles: [$values/components/monitoring/oauth2-proxy-values.yaml]
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      ref: values
    - repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
      targetRevision: main
      path: components/oauth2-proxy        # HTTPRoute for prometheus.localtest.me
  destination: { server: https://kubernetes.default.svc, namespace: monitoring }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

```yaml
# file: components/monitoring/oauth2-proxy-values.yaml
# oauth2-proxy in front of Prometheus. Keycloak has no built-in authenticating proxy, so this replaces the
# embedded outpost used in the authentik lab.
config:
  existingSecret: oauth2-proxy         # keys: client-id, client-secret, cookie-secret
  configFile: |-
    provider              = "keycloak-oidc"
    oidc_issuer_url       = "https://keycloak.localtest.me/realms/platform"
    redirect_url          = "https://prometheus.localtest.me/oauth2/callback"
    upstreams             = [ "http://kube-prometheus-stack-prometheus.monitoring.svc:9090" ]
    email_domains         = [ "*" ]
    allowed_groups        = [ "Platform Engineers" ]   # use case 4 step 4 adds "Developers"
    provider_ca_files     = [ "/etc/ssl/lab/ca.crt" ]
    code_challenge_method = "S256"
    cookie_secure         = true
    reverse_proxy         = true
    skip_provider_button  = true
extraVolumes:
  - name: lab-ca
    configMap: { name: lab-ca }
extraVolumeMounts:
  - { name: lab-ca, mountPath: /etc/ssl/lab, readOnly: true }
```

```yaml
# file: components/oauth2-proxy/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring
resources:
  - httproute.yaml
```

```yaml
# file: components/oauth2-proxy/httproute.yaml
# Use case 4: the only route to Prometheus goes through oauth2-proxy. Lives in the oauth2-proxy app (wave 6),
# beside the Service it targets; in monitoring (wave 5) it was Degraded until wave 6 ran, deadlocking the waves.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: prometheus-via-oauth2-proxy
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [prometheus.localtest.me]
  rules:
    - backendRefs: [{ name: oauth2-proxy, port: 80 }]
```

### Kubernetes RBAC for OIDC groups

```yaml
# file: root/50-oidc-rbac.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: oidc-rbac
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "5" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/oidc-rbac
  destination: { server: https://kubernetes.default.svc }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

```yaml
# file: components/oidc-rbac/bindings.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-platform-engineers-cluster-admin
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - { apiGroup: rbac.authorization.k8s.io, kind: Group, name: "oidc:Platform Engineers" }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-auditors-view
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view }
subjects:
  - { apiGroup: rbac.authorization.k8s.io, kind: Group, name: "oidc:Auditors" }
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: oidc-developers-edit
  namespace: demo
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: edit }
subjects:
  - { apiGroup: rbac.authorization.k8s.io, kind: Group, name: "oidc:Developers" }
```

```yaml
# file: components/oidc-rbac/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [bindings.yaml]
```

### kubeconfig users for the personas

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/04-kubeconfig-users.sh
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
```

### Smoke test

```bash
argocd app list -o name | xargs -n1 argocd app wait --health --timeout 300 >/dev/null && echo all-healthy
kubectl get --raw /.well-known/openid-configuration >/dev/null && echo apiserver-ok
curl -sI https://prometheus.localtest.me | grep -i '^location'      # redirect to Keycloak
```

## Step 8: Demo application

The demo app is two small Python services built from one image:

- **demo-web** is a server-side web app that logs users in with Keycloak (authorization code + PKCE, confidential client `demo-web`). It decodes and displays the ID, access and refresh tokens, enforces one page by group membership, calls the API with the user's access token, refreshes tokens, and does RP-initiated logout.
- **demo-api** is a resource server. It validates access tokens offline against Keycloak's JWKS: signature, `iss`, `aud=demo-api` and `exp`. It authorises on the client roles in `resource_access["demo-api"].roles`. With `INTROSPECT=true` it also asks Keycloak whether each token is still active.

```mermaid
sequenceDiagram
  participant B as Browser
  participant W as demo-web
  participant K as Keycloak (platform realm)
  participant A as demo-api
  B->>W: GET /login
  W-->>B: 302 to /realms/platform/protocol/openid-connect/auth (code_challenge)
  B->>K: login (password, OTP if browser-mfa)
  K-->>B: 302 /callback?code=…
  B->>W: /callback
  W->>K: POST /token (code + verifier + client secret)
  K-->>W: id_token, access_token (aud: demo-api), refresh_token
  B->>W: GET /call/user
  W->>A: GET /api/user, Authorization: Bearer access_token
  A->>K: GET /certs (cached JWKS)
  opt INTROSPECT=true
    A->>K: POST /token/introspect (demo-api credentials)
  end
  A-->>W: 200 or 403 (role check)
```

### Realm additions

These are already in `components/keycloak-config/realms/platform.yaml` (Step 6). The relevant parts:

| Object | Purpose |
| --- | --- |
| Client roles `demo-api: reader, admin` | What the API authorises on |
| Group → client role mappings | Platform Engineers: reader + admin; Developers: reader; Auditors: none |
| Client `demo-web` | Confidential, PKCE S256, redirect `https://demo.localtest.me/callback`; audience mapper adds `demo-api` to access tokens |
| Client `demo-api` | No login flows; owns the client roles; its secret is used only for introspection |
| Client `demo-cli` + service account | Client credentials; audience `demo-api`; service account holds `reader` |

### Source code

```txt
# file: apps/demo-app/requirements.txt
flask==3.1.*
authlib==1.6.*
requests==2.32.*
pyjwt[crypto]==2.10.*
gunicorn==23.*
werkzeug==3.1.*
```

```dockerfile
# file: apps/demo-app/Dockerfile
# One image, two entrypoints: web.py (OIDC client) and api.py (resource server).
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN useradd --uid 10001 --create-home app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
USER 10001
EXPOSE 8080
# Single worker + threads: the web app keeps tokens in process memory (see web.py)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "web:app"]
```

```python
# file: apps/demo-app/web.py
"""demo-web: a server-side web app that logs users in with Keycloak (authorization code + PKCE).

Shows: login, decoded ID/access tokens, group-based page authorisation, calling an API with the
access token, refresh, and RP-initiated logout. Tokens are kept server-side in memory, keyed by a
random session id in the cookie, so they never reach the browser. Single replica only.
"""
import base64
import json
import os
import secrets
import time

import requests
from authlib.integrations.flask_client import OAuth
from flask import Flask, abort, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

ISSUER = os.environ["OIDC_ISSUER"]                  # https://keycloak.localtest.me/realms/platform
PUBLIC_URL = os.environ["PUBLIC_URL"].rstrip("/")   # https://demo.localtest.me
API_URL = os.environ["API_URL"].rstrip("/")         # http://demo-api:8080
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "Platform Engineers")
# requests (and therefore Authlib) honours REQUESTS_CA_BUNDLE for the lab CA

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)   # Envoy terminates TLS
app.secret_key = os.environ["SESSION_SECRET"]
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

oauth = OAuth(app)
oauth.register(
    "keycloak",
    client_id=CLIENT_ID,
    client_secret=CLIENT_SECRET,
    server_metadata_url=f"{ISSUER}/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile email groups", "code_challenge_method": "S256"},
)

TOKENS: dict[str, dict] = {}   # session id -> token response


def log(event: str, **fields):
    print(json.dumps({"ts": int(time.time()), "app": "demo-web", "event": event, **fields}), flush=True)


def decode(jwt_str: str | None) -> dict:
    """Display-only decode of a JWT payload. The API does the real signature validation."""
    if not jwt_str:
        return {}
    payload = jwt_str.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def current_tokens() -> dict | None:
    sid = session.get("sid")
    return TOKENS.get(sid) if sid else None


def refresh(tokens: dict) -> dict:
    meta = oauth.keycloak.load_server_metadata()
    r = requests.post(meta["token_endpoint"], data={
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
    }, timeout=10)
    if r.status_code != 200:
        log("refresh_failed", status=r.status_code, body=r.text[:200])
        TOKENS.pop(session.get("sid"), None)
        session.clear()
        abort(401, "Refresh token rejected by Keycloak (session ended, user disabled, or expired). Log in again.")
    new = r.json()
    new["expires_at"] = int(time.time()) + int(new.get("expires_in", 0))
    TOKENS[session["sid"]] = new
    log("refreshed", user=decode(new.get("access_token")).get("preferred_username"))
    return new


def fresh_tokens() -> dict:
    tokens = current_tokens()
    if not tokens:
        abort(401, "Not logged in.")
    if tokens.get("expires_at", 0) - time.time() < 30:   # refresh 30 s before expiry
        tokens = refresh(tokens)
    return tokens


@app.get("/")
def index():
    tokens = current_tokens()
    user = decode(tokens.get("id_token")) if tokens else None
    return render_template("index.html", user=user)


@app.get("/login")
def login():
    return oauth.keycloak.authorize_redirect(f"{PUBLIC_URL}/callback")


@app.get("/callback")
def callback():
    token = oauth.keycloak.authorize_access_token()
    sid = secrets.token_urlsafe(24)
    token.setdefault("expires_at", int(time.time()) + int(token.get("expires_in", 0)))
    TOKENS[sid] = dict(token)
    session["sid"] = sid
    log("login", user=decode(token.get("id_token")).get("preferred_username"))
    return redirect(url_for("profile"))


@app.get("/profile")
def profile():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    now = int(time.time())
    return render_template(
        "profile.html",
        id_claims=decode(tokens.get("id_token")),
        access_claims=decode(tokens.get("access_token")),
        refresh_claims=decode(tokens.get("refresh_token")),
        now=now,
    )


@app.post("/refresh")
def refresh_now():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    refresh(tokens)
    return redirect(url_for("profile"))


@app.get("/admin")
def admin_page():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    claims = decode(tokens.get("id_token"))
    allowed = ADMIN_GROUP in claims.get("groups", [])
    log("admin_page", user=claims.get("preferred_username"), allowed=allowed)
    if not allowed:
        return render_template("result.html", title="Admin page", status=403,
                               body={"error": f"requires group '{ADMIN_GROUP}'", "your_groups": claims.get("groups", [])}), 403
    return render_template("result.html", title="Admin page", status=200,
                           body={"message": f"Welcome, member of {ADMIN_GROUP}", "groups": claims.get("groups", [])})


@app.get("/call/<endpoint>")
def call_api(endpoint: str):
    if endpoint not in {"public", "user", "admin"}:
        abort(404)
    headers = {}
    if endpoint != "public":
        headers["Authorization"] = f"Bearer {fresh_tokens()['access_token']}"
    r = requests.get(f"{API_URL}/api/{endpoint}", headers=headers, timeout=10)
    try:
        body = r.json()
    except ValueError:
        body = {"raw": r.text[:500]}
    return render_template("result.html", title=f"GET /api/{endpoint}", status=r.status_code, body=body), 200


@app.get("/logout")
def logout():
    tokens = current_tokens()
    meta = oauth.keycloak.load_server_metadata()
    TOKENS.pop(session.get("sid"), None)
    session.clear()
    params = {"post_logout_redirect_uri": f"{PUBLIC_URL}/", "client_id": CLIENT_ID}
    if tokens and tokens.get("id_token"):
        params["id_token_hint"] = tokens["id_token"]
    query = "&".join(f"{k}={requests.utils.quote(v, safe='')}" for k, v in params.items())
    return redirect(f"{meta['end_session_endpoint']}?{query}")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.errorhandler(401)
def unauthorized(e):
    return render_template("result.html", title="Unauthorized", status=401, body={"error": e.description}), 401
```

```python
# file: apps/demo-app/api.py
"""demo-api: a resource server that validates Keycloak access tokens.

- Offline validation: signature (JWKS), issuer, audience "demo-api", expiry.
- Authorisation: client roles in resource_access["demo-api"].roles ("reader", "admin").
- INTROSPECT=true additionally asks Keycloak whether the token is still active (immediate revocation).
"""
import json
import os
import threading
import time

import jwt
import requests
from flask import Flask, jsonify, request

ISSUER = os.environ["OIDC_ISSUER"]
AUDIENCE = os.environ.get("AUDIENCE", "demo-api")
CLIENT_ID = os.environ.get("CLIENT_ID", "demo-api")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
INTROSPECT = os.environ.get("INTROSPECT", "false").lower() == "true"
JWKS_URL = f"{ISSUER}/protocol/openid-connect/certs"
INTROSPECT_URL = f"{ISSUER}/protocol/openid-connect/token/introspect"

app = Flask(__name__)
_jwks: dict = {"keys": None, "fetched": 0.0}
_lock = threading.Lock()


def log(event: str, **fields):
    print(json.dumps({"ts": int(time.time()), "app": "demo-api", "event": event, **fields}), flush=True)


def signing_key(kid: str):
    """Cached JWKS; refetch on unknown kid (key rotation) or after 10 minutes."""
    with _lock:
        stale = time.time() - _jwks["fetched"] > 600
        keys = _jwks["keys"]
        if keys is None or stale or kid not in {k.key_id for k in keys.keys}:
            keys = jwt.PyJWKSet.from_dict(requests.get(JWKS_URL, timeout=10).json())
            _jwks.update(keys=keys, fetched=time.time())
            log("jwks_refreshed", kids=[k.key_id for k in keys.keys])
        for k in keys.keys:
            if k.key_id == kid:
                return k.key
    raise jwt.InvalidTokenError(f"unknown kid {kid}")


def deny(status: int, reason: str, **extra):
    log("deny", status=status, reason=reason, **extra)
    return jsonify({"error": reason, **extra}), status


def authorize(required_role: str):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None, deny(401, "missing bearer token")
    token = auth[7:]
    try:
        kid = jwt.get_unverified_header(token).get("kid", "")
        claims = jwt.decode(token, signing_key(kid), algorithms=["RS256", "ES256", "PS256"],
                            audience=AUDIENCE, issuer=ISSUER, leeway=10)
    except jwt.ExpiredSignatureError:
        return None, deny(401, "token expired")
    except jwt.InvalidTokenError as e:
        return None, deny(401, f"invalid token: {e}")

    if INTROSPECT:
        r = requests.post(INTROSPECT_URL, data={"token": token}, auth=(CLIENT_ID, CLIENT_SECRET), timeout=10)
        if r.status_code != 200 or not r.json().get("active"):
            return None, deny(401, "token not active (introspection)", user=claims.get("preferred_username"))

    roles = claims.get("resource_access", {}).get(AUDIENCE, {}).get("roles", [])
    who = claims.get("preferred_username") or claims.get("client_id") or claims.get("sub")
    if required_role not in roles:
        return None, deny(403, f"requires role '{required_role}'", user=who, roles=roles)
    log("allow", user=who, role=required_role, introspect=INTROSPECT)
    return {"user": who, "roles": roles, "exp_in_seconds": claims["exp"] - int(time.time()),
            "validation": "jwks+introspection" if INTROSPECT else "jwks only"}, None


@app.get("/api/public")
def public():
    return jsonify({"message": "public endpoint, no token required"})


@app.get("/api/user")
def user():
    result, err = authorize("reader")
    return err or jsonify({"message": "reader access granted", **result})


@app.get("/api/admin")
def admin():
    result, err = authorize("admin")
    return err or jsonify({"message": "admin access granted", **result})


@app.get("/healthz")
def healthz():
    return {"status": "ok", "introspect": INTROSPECT}
```

```html
<!-- file: apps/demo-app/templates/base.html -->
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Keycloak demo app</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { max-width: 920px; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
    nav a { margin-right: 1rem; }
    pre { background: rgba(127,127,127,.12); padding: 1rem; overflow-x: auto; border-radius: 8px; }
    table { border-collapse: collapse; width: 100%; } td, th { border-bottom: 1px solid rgba(127,127,127,.3); padding: .3rem .5rem; text-align: left; }
    .ok { color: #2e7d32; } .err { color: #c62828; }
    button { padding: .4rem .8rem; }
  </style>
</head>
<body>
  <nav>
    <a href="/">Home</a><a href="/profile">Tokens</a><a href="/admin">Admin page</a>
    <a href="/call/public">API public</a><a href="/call/user">API user</a><a href="/call/admin">API admin</a>
    <a href="/logout">Log out</a>
  </nav>
  <hr>
  {% block content %}{% endblock %}
</body>
</html>
```

```html
<!-- file: apps/demo-app/templates/index.html -->
{% extends "base.html" %}
{% block content %}
<h1>Keycloak demo app</h1>
{% if user %}
  <p>Signed in as <strong>{{ user.preferred_username }}</strong> ({{ user.email }}).</p>
  <p>Groups: {{ user.groups | join(", ") if user.groups else "none" }}</p>
{% else %}
  <p>You are not signed in.</p>
  <p><a href="/login"><button>Log in with Keycloak</button></a></p>
{% endif %}
{% endblock %}
```

```html
<!-- file: apps/demo-app/templates/profile.html -->
{% extends "base.html" %}
{% block content %}
<h1>Your tokens</h1>
<table>
  <tr><th>Token</th><th>Expires in</th><th>Audience</th></tr>
  <tr><td>ID token</td><td>{{ id_claims.exp - now }} s</td><td>{{ id_claims.aud }}</td></tr>
  <tr><td>Access token</td><td>{{ access_claims.exp - now }} s</td><td>{{ access_claims.aud }}</td></tr>
  <tr><td>Refresh token</td><td>{{ (refresh_claims.exp - now) if refresh_claims.exp else "n/a" }} s</td><td>{{ refresh_claims.typ }}</td></tr>
</table>
<form method="post" action="/refresh"><p><button>Refresh tokens now</button></p></form>
<h2>Roles for demo-api (access token)</h2>
<pre>{{ access_claims.get("resource_access", {}).get("demo-api", {}).get("roles", []) | tojson }}</pre>
<h2>ID token claims</h2>
<pre>{{ id_claims | tojson(indent=2) }}</pre>
<h2>Access token claims</h2>
<pre>{{ access_claims | tojson(indent=2) }}</pre>
{% endblock %}
```

```html
<!-- file: apps/demo-app/templates/result.html -->
{% extends "base.html" %}
{% block content %}
<h1>{{ title }}</h1>
<p class="{{ 'ok' if status < 400 else 'err' }}">HTTP {{ status }}</p>
<pre>{{ body | tojson(indent=2) }}</pre>
{% endblock %}
```

```text
# file: apps/demo-app/.dockerignore
__pycache__
*.pyc
```

Design notes:

- **Tokens stay server-side.** demo-web keeps them in process memory, keyed by a random session id in a signed cookie. Browser cookies stay small and tokens never reach JavaScript. The trade-off is a single replica with `Recreate` strategy; a restart logs everyone out. A production app would use Redis or a database for sessions.
- **Token decoding.** demo-web decodes tokens only for display. Trust decisions belong to demo-api, which verifies signatures.
- **Audience.** demo-api rejects any token whose `aud` lacks `demo-api`, so ArgoCD's or Grafana's tokens cannot be replayed against it.
- **Lab CA.** Both services trust the lab CA through `REQUESTS_CA_BUNDLE`, and the JWKS is fetched with `requests` so the same setting applies.

### Build and load the image

kind on Docker Desktop can use locally built images without a registry. `kind load` copies the image into the node's containerd, and the Deployments use `imagePullPolicy: IfNotPresent`. The quick start runs this script straight after `01-cluster.sh`, so the image is already on the node when wave 7 arrives. Run later, it restarts the Deployments for you.

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/05-build-demo-app.sh
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
```

To ship a code change, run `05-build-demo-app.sh 0.1.1`, change `demo-app:0.1.0` to `0.1.1` in both Deployments, commit and push. ArgoCD rolls the pods.

### Kubernetes manifests

```yaml
# file: root/45-demo-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "7" }
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/lab/keycloak-gitops.git
    targetRevision: main
    path: components/demo-app
  destination: { server: https://kubernetes.default.svc, namespace: demo-app }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

```yaml
# file: components/demo-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-app
resources:
  - demo-app.sealed.yaml               # written by 03-secrets.sh
  - demo-api.yaml
  - demo-web.yaml
  - httproutes.yaml
configMapGenerator:
  - name: lab-ca
    files: [ca.crt=lab-ca.crt]         # copied from ~/.kc-lab-ca/ca.crt by 03-secrets.sh
generatorOptions:
  disableNameSuffixHash: true
```

```yaml
# file: components/demo-app/demo-api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
  labels: { app: demo-api }
spec:
  replicas: 1
  selector: { matchLabels: { app: demo-api } }
  template:
    metadata:
      labels: { app: demo-api }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 10001, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: api
          image: demo-app:0.1.0          # loaded by 05-build-demo-app.sh
          imagePullPolicy: IfNotPresent
          command: [gunicorn, --bind, "0.0.0.0:8080", --workers, "2", "api:app"]
          ports: [{ name: http, containerPort: 8080 }]
          env:
            - { name: OIDC_ISSUER, value: "https://keycloak.localtest.me/realms/platform" }
            - { name: AUDIENCE, value: "demo-api" }
            - { name: CLIENT_ID, value: "demo-api" }
            - { name: INTROSPECT, value: "false" }        # use case 12: set "true" and commit
            - { name: REQUESTS_CA_BUNDLE, value: "/etc/ssl/lab/ca.crt" }
            - name: CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: demo-app, key: api-client-secret } }
          readinessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 10 }
          resources:
            requests: { cpu: 20m, memory: 64Mi }
            limits: { memory: 256Mi }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          volumeMounts:
            - { name: lab-ca, mountPath: /etc/ssl/lab, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: lab-ca
          configMap: { name: lab-ca }
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: demo-api
spec:
  selector: { app: demo-api }
  ports: [{ name: http, port: 8080, targetPort: http }]
```

```yaml
# file: components/demo-app/demo-web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-web
  labels: { app: demo-web }
spec:
  replicas: 1                          # tokens are held in process memory; do not scale
  strategy: { type: Recreate }
  selector: { matchLabels: { app: demo-web } }
  template:
    metadata:
      labels: { app: demo-web }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 10001, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: web
          image: demo-app:0.1.0          # loaded by 05-build-demo-app.sh
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 8080 }]
          env:
            - { name: OIDC_ISSUER, value: "https://keycloak.localtest.me/realms/platform" }
            - { name: PUBLIC_URL, value: "https://demo.localtest.me" }
            - { name: API_URL, value: "http://demo-api:8080" }
            - { name: CLIENT_ID, value: "demo-web" }
            - { name: ADMIN_GROUP, value: "Platform Engineers" }
            - { name: REQUESTS_CA_BUNDLE, value: "/etc/ssl/lab/ca.crt" }
            - name: CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: demo-app, key: web-client-secret } }
            - name: SESSION_SECRET
              valueFrom: { secretKeyRef: { name: demo-app, key: session-secret } }
          readinessProbe: { httpGet: { path: /healthz, port: http }, periodSeconds: 10 }
          resources:
            requests: { cpu: 20m, memory: 96Mi }
            limits: { memory: 256Mi }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          volumeMounts:
            - { name: lab-ca, mountPath: /etc/ssl/lab, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: lab-ca
          configMap: { name: lab-ca }
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: demo-web
spec:
  selector: { app: demo-web }
  ports: [{ name: http, port: 8080, targetPort: http }]
```

```yaml
# file: components/demo-app/httproutes.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-web
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [demo.localtest.me]
  rules:
    - backendRefs: [{ name: demo-web, port: 8080 }]
---
# Exposed so you can call the API with curl from the Mac (use cases 9, 11, 12)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-api
spec:
  parentRefs: [{ name: contour, namespace: projectcontour, sectionName: https }]
  hostnames: [api.localtest.me]
  rules:
    - backendRefs: [{ name: demo-api, port: 8080 }]
```

Both Deployments run non-root, with a read-only root filesystem, all capabilities dropped and the RuntimeDefault seccomp profile. They pass the restricted Pod Security Standard.

### Helper scripts and jq filters

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/demo-cli-call.sh
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
```

```jq
# file: jq/token-claims.jq
# Decodes the access token from a Keycloak token-endpoint response (e.g. client credentials).
def b64url: gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d;
.access_token
| split(".")[1] | b64url | fromjson
| { iss, aud, azp, sub, preferred_username,
    demo_api_roles: (.resource_access["demo-api"].roles // []),
    expires: (.exp | todate) }
```

### Verify

```bash
argocd app wait demo-app --health --timeout 300
curl -s --cacert ~/.kc-lab-ca/ca.crt https://api.localtest.me/api/public          # {"message":"public endpoint, no token required"}
curl -s --cacert ~/.kc-lab-ca/ca.crt -o /dev/null -w '%{http_code}\n' https://api.localtest.me/api/user   # 401
open https://demo.localtest.me
```

If `demo-app` shows `ErrImageNeverPull` or `ImagePullBackOff`, the image is not in the node yet. Run `05-build-demo-app.sh`, then delete the pod or let ArgoCD retry.

## Demo use cases

Use one private browser window per persona. Demo passwords are `DEMO_USER_PASSWORD` in `~/.kc-lab-ca/secrets.env`.

### Use case 1: ArgoCD SSO with group RBAC

1. `https://argocd.localtest.me` → **Log in via Keycloak** as `alice`: full admin.
2. As `bob`: **Sync** works; **Delete** returns `permission denied`.
3. As `carol`: read-only; Sync is denied.
4. Check from the CLI:

```bash
# The CLI's gRPC-web calls 404 through Contour in this lab (the browser UI is fine), so log in over a port-forward
kubectl config set-context --current --namespace=argocd
kubectl port-forward svc/argocd-server 8080:80 >/dev/null & PF=$!; sleep 3
argocd login localhost:8080 --plaintext --sso                         # browser opens; callback on localhost:8085
argocd account get-user-info                          # Groups: [Platform Engineers ArgoCD Admins Grafana Admins]
argocd account can-i sync applications '*/*'
argocd account can-i delete applications '*/*'
kill $PF
```

5. Set `admin.enabled: false` in `bootstrap/argocd-values.yaml`, commit, and confirm the local login form is gone.

### Use case 2: Grafana role mapping and logout

1. Sign in with **Sign in with Keycloak**. alice lands as Admin, bob as Editor, carol as Viewer.
2. Promote carol in Git: add `"/Grafana Editors"` to her `groups` in `realms/platform.yaml`, commit, and wait for the hook Job to finish. When she logs in again she is an Editor.
3. As carol, **Sign out**. Grafana calls Keycloak's end-session endpoint, which ends the Keycloak SSO session. ArgoCD in the same window keeps its own session until its token expires.

### Use case 3: kubectl through Keycloak

```bash
kubectl --context oidc-alice@keycloak-lab auth whoami
# Username: oidc:alice   Groups: [oidc:Platform Engineers oidc:ArgoCD Admins oidc:Grafana Admins system:authenticated]
kubectl --context oidc-alice@keycloak-lab auth can-i '*' '*' --all-namespaces       # yes
kubectl --context oidc-bob@keycloak-lab auth can-i create deployments              # yes (demo)
kubectl --context oidc-bob@keycloak-lab auth can-i get pods --all-namespaces       # no
kubectl --context oidc-carol@keycloak-lab auth can-i get pods --all-namespaces     # yes
kubectl --context oidc-carol@keycloak-lab auth can-i get secrets --all-namespaces  # no
```

Show the claims the API server receives:

```bash
kubectl oidc-login get-token \
  --oidc-issuer-url=https://keycloak.localtest.me/realms/platform --oidc-client-id=kubernetes \
  --oidc-extra-scope=profile --oidc-extra-scope=email \
  --certificate-authority=$HOME/.kc-lab-ca/ca.crt \
  --token-cache-dir=$HOME/.kube/cache/oidc-login/keycloak-lab/alice \
  | jq -f jq/jwt-claims.jq
```

```jq
# file: jq/jwt-claims.jq
# Decodes the ID token from a kubelogin ExecCredential and prints the claims the API server maps.
def b64url: gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d;
.status.token
| split(".")[1] | b64url | fromjson
| { iss, aud, preferred_username, groups,
    issued: (.iat | todate), expires: (.exp | todate) }
```

### Use case 4: Protect Prometheus with oauth2-proxy

1. Run `curl -sI https://prometheus.localtest.me | grep -i '^location'`. It returns a redirect to Keycloak: there is no unauthenticated path.
2. As `alice`, Prometheus loads after login.
3. As `bob` or `carol`, oauth2-proxy returns **403 Forbidden** after a successful Keycloak login. Authentication succeeded and the group check failed.
4. Grant Developers access through Git. In `components/monitoring/oauth2-proxy-values.yaml`, set `allowed_groups = [ "Platform Engineers", "Developers" ]` and commit. oauth2-proxy rolls, then bob gets in and carol is still denied.

**Point out:** authorisation lives in the proxy's config, not in Keycloak. In the authentik lab it is a policy binding on the IdP application. Keycloak can also enforce it at login with a client policy or a conditional authenticator, but that is extra flow configuration.

### Use case 5: Turn on MFA with a commit

1. Enrol the Keycloak `admin` user in OTP first. The master realm is unaffected anyway, since only `platform` changes.
2. Switch the realm's browser flow:

```bash
yq -i '.browserFlow = "browser-mfa"' components/keycloak-config/realms/platform.yaml
git commit -am "keycloak: require OTP for the platform realm" && git push lab main
argocd app wait keycloak-config --health
```

3. Sign in to Grafana as `carol`. After the password, Keycloak forces OTP setup with a QR code, and later logins ask for the code.
4. Audit trail: `git log -p -- components/keycloak-config/realms/platform.yaml`. In Keycloak, the realm's admin events show the change if you enable them under **Realm settings → Events → Admin events**.
5. Revert: `git revert HEAD && git push lab main`.

**Point out:** the switch is one line, but only because the realm file already defines the custom flow. Built-in flows can't be edited in place declaratively.

### Use case 6: Leaver and time to lockout

Prepare: bob is signed in to ArgoCD, Grafana and Prometheus (after UC4's grant), and holds a kubectl token. Note its `expires` value with `jq -f jq/jwt-claims.jq`.

1. Disable bob. The fastest path is the admin console: **Users → bob → Enabled: off**, then the **Sessions** tab → **Sign out**. The GitOps path is to set `enabled: false` for bob in the realm file and commit.
2. Probe every minute:

```bash
while true; do date +%T; kubectl --context oidc-bob@keycloak-lab auth whoami 2>&1 | head -1; sleep 60; done
bootstrap/scripts/kc-sessions.sh bob                # live Keycloak sessions for bob
```

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/kc-sessions.sh
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
```

```jq
# file: jq/kc-sessions.jq
# One line per Keycloak user session: start, last access, IP, clients using it.
.[]
| "\(.start/1000 | todate)\tlast=\(.lastAccess/1000 | todate)\t\(.ipAddress)\tclients=\(.clients | [.[]] | join(","))"
```

| Surface | What holds bob's access | Expected cutoff | Lever |
| --- | --- | --- | --- |
| New login anywhere | Keycloak SSO session | Immediate (account disabled) | — |
| kubectl | Cached ID token, then refresh | ID token expiry (≤ 5 min); refresh then fails | `access.token.lifespan` on the `kubernetes` client |
| Prometheus | oauth2-proxy cookie session | Cookie lifetime, unless the refresh is checked | `cookie_refresh` / `cookie_expire` in oauth2-proxy |
| Grafana | Grafana session + OAuth token | Next OAuth token refresh | Shorter token lifetime; Grafana session settings |
| ArgoCD | ArgoCD session | Session token expiry; measure on your version | Shorter lifetime; back-channel logout where the RP supports it |

Re-enable bob from the UI or set `enabled: true`. With the GitOps path, the next config-cli run flips him back anyway (see UC7).

### Use case 7: Config drift (Keycloak-specific)

1. In the admin console, change the `grafana` client's redirect URI to something wrong and save. Grafana login now fails.
2. Wait 10 minutes. Nothing heals it, because keycloak-config-cli only runs when ArgoCD syncs `keycloak-config`, and ArgoCD sees no Git diff.
3. Fix it with **Sync** on the `keycloak-config` app (with **Replace** or **Force** to re-run the hook), or with any commit to the realm file. config-cli restores the declared value.

**Point out:** this is the main operational difference from the authentik lab. Authentik's worker re-applies blueprints on file change and periodically. Here, closing the drift window needs a scheduled re-run, such as a CronJob running the same container, or an ArgoCD sync window with periodic hard refresh.

### Use case 8: Demo app — login and token anatomy

1. Open `https://demo.localtest.me` in a private window → **Log in with Keycloak** → `alice`.
2. **Tokens** page:
   - The **ID token** has `aud: demo-web`. It is for the app and states who logged in.
   - The **access token** has `aud` including `demo-api`, from the audience mapper. It is for the API and states what the bearer may do.
   - The **refresh token** has `typ: Refresh` and a longer lifetime, bound to the SSO session.
   - `groups` appears in both tokens, from the `groups` client scope. `resource_access.demo-api.roles` is in the access token only.
3. Click **Refresh tokens now** and watch the access token's expiry reset to about 300 s while the session continues.
4. **Admin page**: alice passes the group check that demo-web makes against the ID token's `groups`.
5. **Log out**: demo-web clears its session and redirects to Keycloak's end-session endpoint with `id_token_hint`. Keycloak ends the SSO session and sends you back to the app. Opening `https://grafana.localtest.me` in the same window now requires a fresh login.

**Point out:** the browser never sees a token. Group checks in the web app and role checks in the API are deliberately different mechanisms.

### Use case 9: Demo app — API authorisation with client roles

Run the three API links as each user, one private window per persona:

| User | `/call/public` | `/call/user` (needs `reader`) | `/call/admin` (needs `admin`) | Admin page (group) |
| --- | --- | --- | --- | --- |
| alice | 200 | 200 | 200 | 200 |
| bob | 200 | 200 | 403 `requires role 'admin'` | 403 |
| carol | 200 | 403 `requires role 'reader'` | 403 | 403 |

Watch the API's decisions live. Set your context namespace to `demo-app`, then:

```bash
kubectl logs deploy/demo-api -f | jq -c 'select(.event=="allow" or .event=="deny")'
```

**Point out:** the API trusts nothing but the signed token. Roles come from Keycloak group membership, managed in Git.

### Use case 10: Demo app — role change by commit

1. As bob, `/call/admin` returns 403.
2. Give Developers the admin role in Git:

```bash
yq -i '(.groups[] | select(.name == "Developers") | .clientRoles."demo-api") = ["reader", "admin"]' \
  components/keycloak-config/realms/platform.yaml
git commit -am "demo-api: developers get admin" && git push lab main
argocd app wait keycloak-config --health
```

3. As bob, `/call/admin` still returns 403, because his access token is a snapshot of his roles at issue time.
4. Click **Refresh tokens now** on the Tokens page, then `/call/admin` returns 200. The new roles also appear without a click once the access token reaches its 5-minute expiry and demo-web refreshes automatically.
5. Revert with `git revert HEAD && git push lab main`.

**Point out:** token lifetime is the latency of every authorisation change, whether it grants or revokes access.

### Use case 11: Machine-to-machine (client credentials)

```bash
bootstrap/scripts/demo-cli-call.sh user     # token: azp demo-cli, preferred_username service-account-demo-cli, roles [reader] → HTTP 200
bootstrap/scripts/demo-cli-call.sh admin    # HTTP 403 requires role 'admin'
```

**Point out:** no user, no browser, no refresh token. The service account's roles live in the same realm file and the API code path is identical. Rotating the secret means changing `secrets.env`, re-running `03-secrets.sh`, and committing.

### Use case 12: Revocation — offline JWT validation vs introspection

1. As bob, call `/call/user` (200), and note the access token's remaining lifetime on the Tokens page.
2. Disable bob in the admin console: **Users → bob → Enabled: off**.
3. Immediately call `https://demo.localtest.me/call/user` again as bob. It still returns 200, because demo-api validates the JWT offline and the token has not expired. demo-web only notices once it tries to refresh, which then fails with 401.
4. Switch the API to introspection by setting `INTROSPECT` to `"true"` in `components/demo-app/demo-api.yaml`:

```bash
yq -i '(select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "INTROSPECT") | .value) = "true"' \
  components/demo-app/demo-api.yaml
git commit -am "demo-api: introspect tokens" && git push lab main
argocd app wait demo-app --health
```

5. Re-enable bob, log in again to get a fresh token, and call `/call/user` (200). Disable bob again; the next `/call/user` returns 401 `token not active (introspection)` at once.
6. Revert the flag afterwards.

**Point out:** introspection buys immediate revocation at the cost of one Keycloak round-trip per API call. Short access-token lifetimes are the usual compromise.

## Operating notes

**ArgoCD CLI.** `argocd login argocd.localtest.me --grpc-web` returns `404` on `/session.SessionService/Create` through Contour in this lab, although the browser UI works. Log in over a port-forward instead (UC1 shows it). If the port-forward resets with `connection reset by peer`, just retry it; this happens intermittently on Docker Desktop. A `token signature is invalid` error means the CLI is holding a session from before ArgoCD restarted. Log in again, or remove the old context with `argocd context --delete <name>`.

**Terminating a stuck sync without the CLI.** If an app keeps running an old operation after you push a fix (its hook keeps failing against the old revision), terminate it with kubectl. This is exactly what `argocd app terminate-op` does:

```bash
kubectl config set-context --current --namespace=argocd
kubectl patch application <app> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
kubectl annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
```

Auto-sync then picks up the latest commit.

**Re-running the realm Job.** Hook Jobs aren't part of ArgoCD's diff. A commit that only changes `config-job.yaml` (its image, for example) leaves `keycloak-config` Synced, and the PostSync hook never runs. Changes to `realms/platform.yaml` do trigger it, because they create a new ConfigMap name. To force a run, start a sync by hand (the kubectl equivalent of `argocd app sync`):

```bash
kubectl patch application keycloak-config --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'
```

**Diagnosing any app.** Three jq filters cover almost everything:

```bash
kubectl get applications -o json | jq -r -f jq/apps-status.jq | column -t                       # all apps by wave
kubectl get application <app> -o json | jq -f jq/app-conditions.jq                             # why it's Unknown/Degraded
kubectl get application <app> -o json | jq -r -f jq/app-resources.jq | column -t -s $'\t'      # which resources aren't Synced/Healthy
```

```jq
# file: jq/app-conditions.jq
# Why an Application is Unknown/Degraded: conditions plus the last operation message.
{ app: .metadata.name,
  repo: (.spec.source.repoURL // .spec.sources[0].repoURL),
  path: (.spec.source.path // "-"),
  conditions: [(.status.conditions // [])[] | {type, message}],
  operation: (.status.operationState.message // "-") }
```

```jq
# file: jq/app-resources.jq
# Resources in an Application that are not Synced/Healthy, with ArgoCD's health message.
.status.resources[]
| select(.status != "Synced" or ((.health.status // "Healthy") != "Healthy"))
| [.kind, (.namespace // "-"), .name, .status, (.health.status // "-"), (.health.message // "")]
| @tsv
```

**Switching between this lab and the authentik lab.** Both bind host ports 80/443 and use the same `*.localtest.me` names. Tear one down before building the other. Re-run `06-post-bootstrap.sh` after switching, because it replaces the keychain credential for `gitea.localtest.me`.

**zsh.** Run `setopt interactive_comments` once (or add it to `~/.zshrc`) so pasted commands with trailing `# comments` work.

## Troubleshooting

| Symptom | Likely cause | Check / fix |
| --- | --- | --- |
| `kind create cluster` fails on 80/443 | Another lab or process holds the ports | `lsof -nP -iTCP:443 -sTCP:LISTEN` |
| `keycloak` app stuck Progressing | Keycloak CR not Ready: DB not up, or admin secret missing | `kubectl describe keycloak keycloak` in the keycloak context; check `keycloak-db` Cluster status |
| Keycloak pod CrashLoop on DB auth | CR points at the wrong CNPG secret keys | Secret `keycloak-db-app` must exist with `username`/`password` |
| Redirect loop or `http://` links in Keycloak UI | Forwarded headers not honoured | `proxy.headers: xforwarded` in the CR; Envoy route is HTTPS listener |
| Config Job fails `Connection refused` / timeout | Keycloak not ready, or CoreDNS hosts block missing | Job retries 3×; `kubectl run dnscheck` from Step 4 |
| Config Job fails on a realm field | config-cli version doesn't match Keycloak 26.7 | Pin a config-cli tag built for your Keycloak version |
| Config Job doesn't re-run after a commit | No diff seen (ConfigMap hash unchanged) | Confirm the file actually changed; sync `keycloak-config` manually |
| ArgoCD user is read-only | `groups` claim missing | Client must include the `groups` default scope; `argocd account get-user-info` |
| Groups appear as `/Platform Engineers` | `full.path` is true on the mapper | Realm file sets `full.path: "false"` |
| kubectl: `unknown command "oidc-login" for "kubectl"` | kubelogin plugin not installed | `brew install int128/kubelogin/kubelogin`, or `kubectl krew install oidc-login` if Azure kubelogin is installed |
| kubectl `Unauthorized` (API server log: `invalid bearer token`) | API server can't resolve or reach the issuer, or `aud` ≠ `kubernetes` | Check its view: `docker exec keycloak-lab-control-plane sh -c 'cat /proc/$(pgrep -f ^kube-apiserver)/root/etc/hosts'` must list `keycloak.localtest.me`. Live fix: append `10.96.0.250 keycloak.localtest.me` to that file. Permanent: the `hostAliases` patch in `01-cluster.sh`. Then `jq -f jq/jwt-claims.jq` on the token |
| oauth2-proxy 500 at callback | CA not trusted or wrong issuer | `provider_ca_files` mount present; issuer has no trailing slash |
| oauth2-proxy 403 for alice | Group name mismatch | `allowed_groups` must match the claim exactly, incl. spaces |
| Grafana login loop | Token endpoint TLS/DNS from pod | `/etc/ssl/lab/ca.crt` present in Grafana pod; DNS check |
| demo-app pods `ErrImageNeverPull` / `ImagePullBackOff` | Image not loaded into kind | `05-build-demo-app.sh <tag>`; tag in Deployments must match |
| demo-web `invalid_redirect_uri` | Callback URL mismatch | Realm `demo-web.redirectUris` must be exactly `https://demo.localtest.me/callback` |
| demo-web callback error `mismatching_state` | Session cookie lost (http vs https, or pod restarted mid-login) | Use https URL; ProxyFix needs Envoy's `X-Forwarded-Proto` |
| demo-api 401 `invalid token: Invalid audience` | Token lacks `aud: demo-api` | Audience mapper on `demo-web` / `demo-cli` in the realm file |
| demo-api 403 for alice | Roles missing from `resource_access` | Group → client role mapping in realm file; refresh tokens after a change |
| demo-cli 401 at token endpoint | Service account or secret not applied | config-cli Job logs; `serviceAccountsEnabled: true` on `demo-cli` |
| `02-bootstrap.sh`: `Git repo root is …, not …` | Scripts run from a copy nested inside another git repo, or `git init` run in a parent folder | Remove that `.git` (only if it exists just for this lab), then `git init -b main` in `keycloak-gitops/` |
| `root` app `ComparisonError: app path does not exist` | Same as above, if the guard was bypassed | `git ls-tree --name-only HEAD` from the repo root must list `root` |
| An app stays OutOfSync after a fix is pushed | Its previous sync operation is still running | Terminate it (Operating notes) |
| Keycloak Operator CrashLoop `… Not Found` for a `k8s.keycloak.org` kind | Operator version needs a CRD the kustomization doesn't install | Add the matching CRD file from `keycloak-k8s-resources/<version>/kubernetes/` |
| Realm Job `Cannot resolve variable 'env:…'` | Realm file mentions a `$(env:NAME)` that isn't in `keycloak-config-env` (comments count) | Add the key to `03-secrets.sh`, or reword the comment |
| `git push lab` `Unauthorized` | Wrong credential in the keychain for `gitea.localtest.me` | Re-run `06-post-bootstrap.sh`, or the `credential-osxkeychain erase` / `credential approve` pair in it |

## Teardown and rebuild

### Teardown

`99-teardown.sh` has two levels:

| Command | Removes | Keeps |
| --- | --- | --- |
| `./bootstrap/scripts/99-teardown.sh` | kind cluster and its kube context; kubectl persona contexts and kubelogin caches; argocd CLI contexts; `bootstrap/.rendered`; the `lab` git remote and its CA setting | Lab CA and its keychain trust, `~/.kc-lab-ca/secrets.env`, Gitea password, sealed files in the repo, demo-app image |
| `./bootstrap/scripts/99-teardown.sh --purge` | Everything above, plus the keychain trust and `~/.kc-lab-ca` (CA, `secrets.env`, Gitea password), the `gitea.localtest.me` keychain credential, all `*.sealed.yaml` and `lab-ca.crt` copies in the repo, and `demo-app` images | The repo and your git history |

```bash
#!/usr/bin/env zsh
# file: bootstrap/scripts/99-teardown.sh
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
```

Without `--purge`, a rebuild reuses the same CA and secret values. The sealed files are still regenerated by `03-secrets.sh`, because a new cluster has a new Sealed Secrets key and the old ciphertext can't be decrypted. With `--purge`, the next build starts with a new CA and new passwords.

Neither level touches Docker Desktop itself, the `kindest/node` image, Homebrew tools, or `~/.zshrc`. To reclaim the node image too: `docker image rm kindest/node:v1.34.0`.

### Full rebuild from scratch

```bash
cd ~/labs/keycloak-gitops-lab
./bootstrap/scripts/99-teardown.sh --purge

cd ~/labs && rm -rf keycloak-gitops-lab               # discard the old working copy (it holds lab-only commits)
git clone https://github.com/simonjday/keycloak-gitops-lab.git
cd keycloak-gitops-lab
./bootstrap/scripts/00-lab-ca.sh
./bootstrap/scripts/01-cluster.sh
./bootstrap/scripts/05-build-demo-app.sh
./bootstrap/scripts/02-bootstrap.sh
./bootstrap/scripts/03-secrets.sh
./bootstrap/scripts/06-post-bootstrap.sh
./bootstrap/scripts/04-kubeconfig-users.sh
```

### Faster rebuild keeping secrets

Use this to reset the cluster while keeping the same CA and passwords:

```bash
./bootstrap/scripts/99-teardown.sh
./bootstrap/scripts/01-cluster.sh
./bootstrap/scripts/05-build-demo-app.sh
./bootstrap/scripts/02-bootstrap.sh
./bootstrap/scripts/03-secrets.sh
./bootstrap/scripts/06-post-bootstrap.sh
./bootstrap/scripts/04-kubeconfig-users.sh
```

### Verify a rebuild

```bash
kubectl config set-context --current --namespace=argocd
kubectl get applications -o json | jq -r -f jq/apps-status.jq | column -t      # every app Synced / Healthy
curl -s https://keycloak.localtest.me/realms/platform/.well-known/openid-configuration | jq -r .issuer
curl -s https://api.localtest.me/api/public | jq -r .message
kubectl --context oidc-alice@keycloak-lab auth whoami
```

## Production gaps

| Lab choice | Production concern | Replace with |
| --- | --- | --- |
| 1 Keycloak instance, 1 CNPG instance | No HA | 2+ Keycloak instances (embedded Infinispan), 3-instance CNPG with backups. Multi-site: Keycloak's multi-cluster v2 is preview in 26.7 [R1] |
| Bootstrap admin from a Secret | Temporary admin account | Create a permanent admin in `master`, then delete the bootstrap user |
| `KEYCLOAK_SSLVERIFY=false` for config-cli | Admin API call not TLS-verified | Mount a truststore with the issuing CA |
| Versions pinned by hand | Upgrades are manual and untested | Bump through Renovate PRs or Kargo stages, with this lab as the test environment |
| config-cli runs only on sync | Drift window (UC7) | Scheduled reconcile, or restrict admin-console write access |
| Demo passwords in the realm file | Credentials in config | Federate users from LDAP/AD or an upstream IdP; no `credentials` in Git |
| demo-web stores tokens in memory, single replica | Lost on restart; cannot scale | External session store (Redis/DB) and multiple replicas |
| demo-app image loaded with `kind load` | No registry, no signing | Push to a registry, sign with Cosign, verify with your Kyverno `verifyImages` policies |
| Self-signed lab CA, `/etc/hosts`, CoreDNS hosts | Hand-maintained trust and DNS | Corporate PKI, real DNS |
| Upstream Keycloak | No vendor support | Red Hat build of Keycloak on OpenShift via its Operator [R2][R3] |

## References

Accessed 3 Oct 2026.

| ID | Source | Supports |
| --- | --- | --- |
| R1 | [Keycloak 26.7.0 release announcement](https://www.keycloak.org/2026/07/keycloak-2670-released) | Version/date; multi-cluster v2 preview; Operator kustomize install; MCP guide; SCIM preview |
| R2 | [Red Hat build of Keycloak supported configurations](https://access.redhat.com/articles/7057191) | RHBK 26.6.x support on OpenShift/RHEL |
| R3 | [RHBK 26.0 Operator Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.0/html-single/operator_guide) | Operator deploys Keycloak via CR; database must be provisioned separately |
| R4 | [keycloak-config-cli on Docker Hub](https://hub.docker.com/r/adorsys/keycloak-config-cli) | Image tags (`latest`, `latest-x.y.z`), variable substitution, adorsys maintainer |

**Verified by a clean end-to-end build on 10 Oct 2026** (Docker Desktop, kind v1.34.0, M3): the build went from `99-teardown.sh --purge` to all 15 apps Synced/Healthy with no manual steps, and all twelve demo use cases ran, including kubectl OIDC login against the API server. Everything in the Components table was part of that build.

**Not verified against primary docs in this pass:**
- keycloak-config-cli handling of `serviceAccountClientId` users and group `clientRoles`.
- `KeycloakRealmImport` create-only behaviour.
- keycloak-config-cli field names for `authenticationFlows` against 26.7.
- oauth2-proxy chart value names.
- CloudNativePG generated-secret key names.

Each of these surfaces quickly on the first sync; the troubleshooting table covers the symptoms.
