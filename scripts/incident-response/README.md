# Incident Response toolkit (`scripts/incident-response/`)

Five bash scripts that automate each stage of the KTCloud Incident Response
process. Each script maps to one stage of the runbook:

**탐지 (detect) → 격리 (isolate) → 분석 (analyze) → 복구 (recover) → 회고 (retrospective)**

The process/policy document lives at [`docs/INCIDENT-RESPONSE.md`](../../docs/INCIDENT-RESPONSE.md).
This README is the operational runbook for the scripts themselves.

---

## Stage → script → what it automates

| Stage | Korean | Script | Automates | Mutates? |
|-------|--------|--------|-----------|----------|
| 1. Detect | 탐지 | `01-detect.sh [ns]` | Pulls firing alerts from Alertmanager, lists CrashLoopBackOff/NotReady pods + NotReady nodes, scrapes recent Falco events, snapshots 5xx rate. Prints a triage summary. | No (read-only) |
| 2. Isolate | 격리 | `02-isolate.sh <ns> <kind/name> [--scale-zero] [--cordon-node] [--no-netpol] --yes` | Quarantines the workload: snapshots current state, applies a quarantine label + default-deny NetworkPolicy, optionally scales to 0 and/or cordons the node. Writes a backup under `./incident-state/` for stage 4. | **Yes** (needs `--yes`) |
| 3. Analyze | 분석 | `03-analyze.sh <ns> <pod> [timestamp]` | Collects an evidence bundle into `./incident-evidence/<ts>__<ns>__<pod>/`: describe, current+previous logs, events, NetworkPolicies (incl. which select the pod), Falco hits, Prometheus error-rate/latency/resource snapshot, `INDEX.md`. | No (read-only) |
| 4. Recover | 복구 | `04-recover.sh <ns> <workload> [--to-revision N] [--no-rollback] [--timeout S] --yes` | Auto-detects Rollout vs Deployment/StatefulSet and rolls back (`kubectl argo rollouts undo` vs `kubectl rollout undo`), removes the quarantine NetworkPolicy + label, uncordons the node, scales back to the recorded replica count, waits for Ready and verifies. | **Yes** (needs `--yes`) |
| 5. Retrospective | 회고 | `05-retro.sh [--evidence DIR] [--title T] [--severity SEVn] [--out F]` | Generates a blameless postmortem markdown under `./postmortems/`, pre-filled from the evidence bundle (timeline anchors, affected workload, Falco/Prometheus excerpts, MTTD/MTTR table). | Writes one `.md` |

---

## Prerequisites

- `kubectl` (v1.30 cluster) with a working context — these run from the
  operator host whose kubeconfig points at the master via the SSH tunnel/bastion.
- `jq` and `curl` on PATH.
- `kubectl-argo-rollouts` plugin (for recovering the `order-service` Rollout).
- Cluster facts (override via env if they differ):

  | Env var | Default |
  |---------|---------|
  | `APP_NAMESPACE` | `ktcloud-market-msa` |
  | `ALERTMANAGER_SVC` | `kps-alertmanager.kube-prometheus-stack.svc:9093` |
  | `PROM_SVC` | `kps-prometheus.kube-prometheus-stack.svc:9090` |
  | `FALCO_NAMESPACE` | `falco` |
  | `ROLLOUT_WORKLOADS` | `order-service` |
  | `IR_STATE_DIR` | `./incident-state` |
  | `IR_EVIDENCE_DIR` | `./incident-evidence` |
  | `PROM_QUERY_MODE` | `run` (ephemeral curl pod). Set `local` if you have a port-forward open. |

  > Prometheus/Alertmanager are ClusterIP services, not reachable from the
  > laptop. By default the scripts run an ephemeral `curlimages/curl` pod in the
  > `kube-prometheus-stack` namespace to query them (`PROM_QUERY_MODE=run`). If
  > you already `kubectl port-forward`, export `PROM_QUERY_MODE=local` and point
  > `ALERTMANAGER_SVC`/`PROM_SVC` at `localhost:<port>`.

All mutating scripts (`02`, `04`) refuse to run without `--yes`.

---

## Invocation order — example walkthrough

Scenario: Falco fires "Terminal Shell in Container" on an `order-service` pod
and the 5xx rate climbs. (`order-service` is an Argo Rollout.)

```bash
cd scripts/incident-response

# 1) DETECT — triage everything firing right now
./01-detect.sh ktcloud-market-msa
#   -> shows the Falco alert + the implicated pod, e.g. order-service-7d9c8-abcde

# 2) ISOLATE — quarantine the workload (deny-all netpol + label), keep it for forensics
./02-isolate.sh ktcloud-market-msa pod/order-service-7d9c8-abcde --cordon-node --yes
#   -> backup written to ./incident-state/ktcloud-market-msa__order-service/isolation.env
#   (use --scale-zero instead/also if you must fully stop the workload)

# 3) ANALYZE — snapshot all evidence to a timestamped dir
./03-analyze.sh ktcloud-market-msa order-service-7d9c8-abcde
#   -> ./incident-evidence/<UTC-ts>__ktcloud-market-msa__order-service-7d9c8-abcde/

# 4) RECOVER — roll back the Rollout, de-quarantine, scale back, wait Ready
./04-recover.sh ktcloud-market-msa order-service --yes
#   -> uses `kubectl argo rollouts undo` because it detects a Rollout

# 5) RETROSPECTIVE — draft the postmortem from the evidence
./05-retro.sh \
  --evidence ./incident-evidence/<UTC-ts>__ktcloud-market-msa__order-service-7d9c8-abcde \
  --title "order-service shell-injection + 5xx spike" \
  --severity SEV2
#   -> ./postmortems/<date>-order-service-...md
```

For a plain Deployment (e.g. `product-service`), step 4 auto-detects a
Deployment and uses `kubectl rollout undo` instead — same command form:

```bash
./04-recover.sh ktcloud-market-msa product-service --yes
```

### Notes
- `01` and `03` are safe to run anytime (read-only). Run `01` again after `04`
  to confirm the error-rate returned to baseline.
- `02` writes everything it changed to `./incident-state/<ns>__<workload>/` so
  `04` can reverse exactly those changes. Keep that directory until recovery is
  confirmed.
- Evidence (`./incident-evidence/`) and state (`./incident-state/`) should be
  treated as incident artifacts — archive them, don't commit live incident data.
- All scripts accept `-h` / `--help`.
