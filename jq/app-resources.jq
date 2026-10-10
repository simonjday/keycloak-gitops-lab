# Resources in an Application that are not Synced/Healthy, with ArgoCD's health message.
.status.resources[]
| select(.status != "Synced" or ((.health.status // "Healthy") != "Healthy"))
| [.kind, (.namespace // "-"), .name, .status, (.health.status // "-"), (.health.message // "")]
| @tsv
