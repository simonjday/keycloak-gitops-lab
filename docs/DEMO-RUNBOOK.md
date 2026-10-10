# Demo runbook

A one-page script for presenting the lab. Full detail for every step is in [GUIDE.md](GUIDE.md#demo-use-cases).

## Before the audience arrives

```bash
setopt interactive_comments
kubectl config set-context --current --namespace=argocd
kubectl get applications -o json | jq -r -f jq/apps-status.jq | column -t   # all Synced / Healthy
grep -E 'DEMO_USER_PASSWORD|KEYCLOAK_ADMIN_PASSWORD' ~/.kc-lab-ca/secrets.env
```

- Open three private browser windows, one each for alice, bob and carol. Close and reopen a window before switching users.
- Pre-warm kubectl tokens:

  ```bash
  for u in alice bob carol; do kubectl --context oidc-$u@keycloak-lab auth whoami; done
  ```

| User | Persona | Groups |
| --- | --- | --- |
| alice | Platform admin | Platform Engineers, ArgoCD Admins, Grafana Admins |
| bob | Developer | Developers, Grafana Editors |
| carol | Auditor | Auditors |

## Suggested order (about 45 minutes)

Run the read-only scenarios first, then the commit-driven ones, then the leaver scenario last, because it locks bob out.

| Time | # | Scenario | Do | Expect |
| --- | --- | --- | --- | --- |
| 0:00 | 1 | ArgoCD SSO + RBAC | `https://argocd.localtest.me` → Log in via Keycloak as each user | alice admin; bob can sync, not delete; carol read-only |
| 0:05 | 2 | Grafana roles | `https://grafana.localtest.me` as each user | Admin / Editor / Viewer |
| 0:08 | 3 | kubectl OIDC | `kubectl --context oidc-carol@keycloak-lab auth can-i get secrets --all-namespaces` | `no`: view excludes Secrets |
| 0:12 | 4 | Protect a no-auth UI | `https://prometheus.localtest.me` as alice, then bob | alice in; bob 403 after a successful login |
| 0:15 | 8 | Token anatomy | `https://demo.localtest.me` → Tokens | ID token `aud: demo-web`; access token `aud` includes `demo-api` |
| 0:20 | 9 | API roles | API user / API admin links as each user | alice 200/200; bob 200/403; carol 403/403 |
| 0:25 | 11 | Machine-to-machine | `./bootstrap/scripts/demo-cli-call.sh user` then `admin` | 200 then 403 |
| 0:28 | 10 | Role change by commit | Give Developers `admin` in the realm file, push; bob refreshes tokens | 403 until refresh, then 200 |
| 0:33 | 5 | MFA by commit | `yq -i '.browserFlow = "browser-mfa"' …/platform.yaml`, push | carol forced into OTP enrolment |
| 0:37 | 7 | Config drift | Break the grafana client in the admin UI; it stays broken; re-sync | Drift persists until the next sync |
| 0:40 | 12 | Revocation | Disable bob; API keeps accepting; flip `INTROSPECT=true`; repeat | Offline 200 → introspection 401 |
| 0:43 | 6 | Leaver | Disable bob; probe each app | Lockout latency per app |

Revert each commit-driven change (`git revert HEAD && git push lab main`) before starting the next one.

## If something misbehaves mid-demo

| Symptom | Quick fix |
| --- | --- |
| A realm change didn't apply | `kubectl patch application keycloak-config --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main","prune":true}}}'` |
| App stuck on an old sync after a push | `kubectl patch application <app> --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'` |
| Wrong user appears logged in | Close every private window; Keycloak's SSO cookie is per browser session |
| kubectl asks to log in again | Expected after 5 minutes: that's the short token lifetime from scenario 6 |
