# Why an Application is Unknown/Degraded: conditions plus the last operation message.
{ app: .metadata.name,
  repo: (.spec.source.repoURL // .spec.sources[0].repoURL),
  path: (.spec.source.path // "-"),
  conditions: [(.status.conditions // [])[] | {type, message}],
  operation: (.status.operationState.message // "-") }
