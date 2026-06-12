# ktcloud-k8s-argocd-manifest — repository layout

GitOps entry point for the KTCloud MSA platform. ArgoCD's `root-app`
(created by `msa-provisioning`'s `argocd` role) points at **`bootstrap/`**
and everything else fans out from there.

```
bootstrap/        ArgoCD entry point — applied by root-app (path: bootstrap)
  projects.yaml       Application → applies projects/ first (sync-wave -10)
  platform.yaml       ApplicationSet → one Application per platform/* addon
  applications.yaml   ApplicationSet → the KTCloudMarket application layer
projects/         ArgoCD AppProjects (RBAC / source & destination scoping)
  platform-project.yaml
  market-project.yaml
platform/         Cluster addons, operators, observability (was Addons/)
                  Folders are wave-numbered for readability; the actual
                  ordering is driven by argocd.argoproj.io/sync-wave
                  annotations in bootstrap/platform.yaml, not the prefix.
applications/     The KTCloudMarket workload layer (was Apps/KTCloudMarket/)
  appset.yaml         5 microservices (multi-source: chart repo + values repo)
  frontend.yaml       frontend Application
  charts/frontend/    in-repo Helm chart for the frontend
docs/             This document and any ADRs.
```

## Wave-number bands (`platform/`)

| Prefix | Concern                          | Examples |
|--------|----------------------------------|----------|
| 05     | Storage CSI                      | `05-aws-ebs-csi` |
| 10–13  | Service mesh + ingress           | `10-istio-base`, `11-istiod`, `13-traefik` |
| 20     | Cluster scaling                  | `20-cluster-autoscaler` |
| 30–31  | Observability (stores + config)  | `30-kube-prometheus-stack`, `30-elasticsearch`, `31-*` |
| 40     | Operators / controllers          | `40-external-secrets`, `40-kafka-operator`, `40-keda`, `40-gatekeeper`, `40-falco`, `40-chaos-mesh` |
| 50     | Operator-managed clusters        | `50-kafka-cluster` |
| 91     | Policies / jobs / experiments    | `91-gatekeeper-policies`, `91-es-lifecycle`, `91-chaos-experiments`, `91-perf-k6` |

## Cross-repo wiring

`applications/appset.yaml` uses ArgoCD multi-source to combine the two sibling
repos that remain independent (each has its own remote + CI):

- chart:  `github.com/ktcloud-msa/ktcloud-msa-chart` (ref `template`)
- values: `github.com/ktcloud-msa/ktcloud-msa-values` (`$values` ref)

Layout mirrors the reference repo
`KTCloud-CloudNative-Troica-Team/msa-argocd-manifest`.
