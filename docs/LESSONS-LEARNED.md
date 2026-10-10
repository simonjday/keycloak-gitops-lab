# Lessons learned

Every failure hit while turning this lab from "works on my cluster" into "builds from a clean clone with no manual steps". Each was fixed in the repo, and the build that followed went from `--purge` to all apps Healthy with nothing done by hand.

## Sync ordering: health that depends on a later wave

The app-of-apps waits for each wave to be Healthy before starting the next. Three times, a resource's health depended on something created in a *later* wave, and the build deadlocked.

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Build stalls at wave -8; Gateway `InvalidCertificateRef: Secret not found` | The Gateway (in `contour`, wave -8) referenced the wildcard certificate created in `platform-config` (wave -7) | Gateway moved into `platform-config`, beside the certificate |
| `monitoring` Degraded; HTTPRoute `service "monitoring/oauth2-proxy" not found` | The Prometheus route (wave 5) targeted a Service created by `oauth2-proxy` (wave 6) | Route moved into the `oauth2-proxy` app |
| oauth2-proxy CrashLoop: `Realm does not exist` | Later waves started while the realm import (a PostSync hook) was still running | App-of-apps health treats a child with a running sync operation as Progressing |

**Lesson:** keep a resource in the same Application, or a later wave, than everything its health depends on. This only shows up on a clean build; an incremental fix on a live cluster hides it.

## Silent misconfiguration

| Symptom | Root cause | Fix |
| --- | --- | --- |
| kubectl OIDC `Unauthorized`; API server logs `invalid bearer token` | kind generates `kubeadm.k8s.io/v1beta3`; patches written for `v1beta4` were silently ignored, so the API server never got `--authentication-config` | Patches in `v1beta3` form; `01-cluster.sh` verifies the flag |
| Same symptom once the flag was present | The API server (host network) uses a kubelet snapshot of the node's `/etc/hosts` taken at pod creation; an entry added later never reaches it | `hostAliases` on the API server via a kubeadm patch; verified by `01-cluster.sh` |
| Realm Job: `Cannot resolve variable 'env:VAR'` | keycloak-config-cli substitutes `$(env:…)` across the whole file, comments included | Comment reworded |

**Lesson:** make bootstrap scripts assert the outcome (the flag is present, the entry resolves), not just run the step.

## ArgoCD diff and health semantics

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Gateway, HTTPRoutes and CRDs permanently OutOfSync | Client-side diff against API-server-defaulted fields | `controller.diff.server.side: "true"` |
| `contour` stuck Progressing | Contour static mode never writes GatewayClass status | Custom health check: only `Accepted=False` is unhealthy |
| `monitoring` permanently OutOfSync, Grafana keeps rolling | The chart generates a random admin password each render (its `lookup` doesn't run under ArgoCD) | Fixed admin password from a SealedSecret |
| A commit changing only the realm Job didn't re-run it | Hook Jobs aren't part of the diff, so there's no OutOfSync and no auto-sync | Realm changes create a new ConfigMap name; manual sync documented for Job-only changes |
| Keycloak app Healthy before Keycloak was ready | No built-in health check for the Keycloak CR | Custom health check on the `Ready` condition |

## Upstream changes

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Sealed Secrets chart `index.yaml 404` | Project moved from `bitnami-labs` to the `bitnami` GitHub org | `https://bitnami.github.io/sealed-secrets` |
| Keycloak Operator CrashLoop: `keycloaksamlclients … Not Found` | 26.7 also watches new OIDC/SAML client CRDs | Both CRDs added to the operator kustomization |
| Realm Job `ImagePullBackOff` on `keycloak-config-cli:6.5.1` | The app reports v6.5.1, but that isn't a registry tag | `:latest`; pin by digest if needed |

**Lesson:** pin versions only after you've seen them pull and run; an "obviously right" tag can be wrong.

## Bootstrap and local tooling

| Symptom | Root cause | Fix |
| --- | --- | --- |
| ArgoCD install: `no matches for kind "Application"` | Root app in the chart's `extraObjects` was validated before the chart's CRDs existed | Separate `argocd-apps` release for the root app |
| `root: app path does not exist` | `git init` ran in a parent folder, so `root/` was really `keycloak-gitops/root/` (and `git ls-tree` from a subfolder hides it) | Bootstrap refuses unless the repo root is the working directory |
| `git push` rejected after re-initialising | New local history against an old Gitea seed | Bootstrap seed push uses `--force` |
| `git push lab` `Unauthorized` | macOS keychain held another lab's credential for the same hostname | `06-post-bootstrap.sh` replaces it |
| `unknown command "oidc-login"` / Homebrew refuses kubelogin | Microsoft's Azure `kubelogin` shares the formula and binary name | Install the OIDC plugin via krew |
| `zsh: no matches found` on pasted commands | zsh treats `# comments` as arguments by default | `setopt interactive_comments` |

## Still open

- **ArgoCD CLI through Contour:** `argocd login argocd.localtest.me --grpc-web` returns `404` on `/session.SessionService/Create`, although the browser UI works. The workaround is to log in over a port-forward. The root cause is unconfirmed; the suspect is Contour's gRPC-web handling in front of ArgoCD's single HTTP/1.1 port.
