# ArgoCD Applications sorted by sync wave; a missing wave counts as 0 (ArgoCD's default).
.items
| map({ app: .metadata.name,
        wave: ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0") | tonumber),
        sync: (.status.sync.status // "-"),
        health: (.status.health.status // "-") })
| sort_by(.wave, .app)
| (["APP", "WAVE", "SYNC", "HEALTH"] | @tsv),
  (.[] | [.app, (.wave | tostring), .sync, .health] | @tsv)
