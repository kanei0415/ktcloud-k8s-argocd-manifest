#!/usr/bin/env bash
# ===========================================================================
# 01-detect.sh — STAGE 1: 탐지 (DETECT)
#
# Builds a triage summary from the three signal sources the cluster already
# runs: Prometheus Alertmanager (firing alerts), the Kubernetes API (unhealthy
# pods), and Falco (runtime-security events). Read-only — never mutates.
#
# Usage:
#   ./01-detect.sh [namespace]
#
#   namespace   Optional. App namespace to focus on. Default: $APP_NAMESPACE
#               (ktcloud-market-msa).
#
# Env overrides: ALERTMANAGER_SVC, PROM_QUERY_MODE, FALCO_NAMESPACE ...
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help) usage 0;; esac

NS="${1:-$APP_NAMESPACE}"

require_cmd kubectl jq
require_kubectl_ctx

section "STAGE 1 — DETECT  (namespace: ${NS})"

# ---------------------------------------------------------------------------
# 1a. Firing alerts from Alertmanager
# ---------------------------------------------------------------------------
section "1a. Alertmanager — active (firing) alerts"
if AM_JSON="$(alertmanager_get "/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null)" \
   && [ -n "$AM_JSON" ] && echo "$AM_JSON" | jq -e . >/dev/null 2>&1; then
  COUNT="$(echo "$AM_JSON" | jq 'length')"
  info "active alerts: ${COUNT}"
  echo "$AM_JSON" | jq -r '
    sort_by(.labels.severity)
    | .[]
    | "  [\(.labels.severity // "n/a" | ascii_upcase)] \(.labels.alertname // "?")"
      + " ns=\(.labels.namespace // "-")"
      + " pod=\(.labels.pod // "-")"
      + " since=\(.startsAt // "-")"
      + "\n        \(.annotations.summary // .annotations.description // "")"'
else
  warn "could not reach Alertmanager (${ALERTMANAGER_SVC}). Set PROM_QUERY_MODE=local if you have a port-forward, or check the tunnel."
fi

# ---------------------------------------------------------------------------
# 1b. Unhealthy pods (CrashLoopBackOff / not Ready / Pending / OOM)
# ---------------------------------------------------------------------------
section "1b. Kubernetes — unhealthy pods in ${NS}"
PODS_JSON="$(kubectl -n "$NS" get pods -o json 2>/dev/null || echo '{"items":[]}')"
UNHEALTHY="$(echo "$PODS_JSON" | jq -r '
  .items[]
  | . as $p
  | ($p.status.containerStatuses // []) as $cs
  | ($cs | map(select(.ready == false)) | length) as $notready
  | ($cs | map(.restartCount // 0) | add // 0) as $restarts
  | ($cs | map(.state.waiting.reason // empty) | join(",")) as $waiting
  | select(
      ($p.status.phase != "Running" and $p.status.phase != "Succeeded")
      or $notready > 0
      or ($waiting | test("CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError"))
    )
  | "  \($p.metadata.name)  phase=\($p.status.phase)  notReady=\($notready)  restarts=\($restarts)  waiting=[\($waiting)]"
')"
if [ -n "$UNHEALTHY" ]; then
  echo "$UNHEALTHY"
else
  info "no unhealthy pods detected in ${NS}."
fi

section "1b'. Nodes not Ready"
kubectl get nodes --no-headers 2>/dev/null \
  | awk '$2 !~ /^Ready/ {print "  " $1 "  status=" $2}' \
  | grep . || info "all nodes Ready."

# ---------------------------------------------------------------------------
# 1c. Recent Falco runtime-security events
# ---------------------------------------------------------------------------
section "1c. Falco — recent runtime-security events (last 200 log lines)"
FALCO_PODS="$(kubectl -n "$FALCO_NAMESPACE" get pods -l app.kubernetes.io/name=falco \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "$FALCO_PODS" ]; then
  # fall back to a looser selector
  FALCO_PODS="$(kubectl -n "$FALCO_NAMESPACE" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i falco | grep -vi sidekick | head -3 | tr '\n' ' ' || true)"
fi
if [ -n "$FALCO_PODS" ]; then
  for fp in $FALCO_PODS; do
    kubectl -n "$FALCO_NAMESPACE" logs "$fp" --tail=200 2>/dev/null \
      | grep -Ei '"priority"|Warning|Error|Critical|Notice' \
      | grep -Ei "$NS|Shell spawned|sensitive|outbound|mkdir|write below" \
      | tail -15 | sed 's/^/  /' || true
  done
  info "(showing Falco lines matching ns=${NS} or high-signal rule keywords; full stream in the falco pod logs)"
else
  warn "no Falco pods found in namespace '${FALCO_NAMESPACE}'."
fi

# ---------------------------------------------------------------------------
# 1d. Quick error-rate snapshot (best effort)
# ---------------------------------------------------------------------------
section "1d. Prometheus — 5xx error-rate snapshot (last 5m, by pod)"
PROMQL="sum by (namespace,pod) (rate(http_requests_total{namespace=\"${NS}\",code=~\"5..\"}[5m]))"
if Q_JSON="$(prom_query "$PROMQL" 2>/dev/null)" && echo "$Q_JSON" | jq -e '.status=="success"' >/dev/null 2>&1; then
  RESULTS="$(echo "$Q_JSON" | jq -r '.data.result[] | "  pod=\(.metric.pod // "-")  rate=\(.value[1])/s"')"
  [ -n "$RESULTS" ] && echo "$RESULTS" || info "no 5xx rate samples (metric http_requests_total may differ in this stack)."
else
  warn "Prometheus query failed/unavailable; skipping error-rate snapshot."
fi

section "DETECT complete"
cat <<EOF
NEXT STEPS:
  - If a workload is implicated, isolate it:   ./02-isolate.sh ${NS} <deploy/NAME or pod/NAME> --yes
  - Then collect evidence:                     ./03-analyze.sh ${NS} <POD>
EOF
