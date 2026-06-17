#!/usr/bin/env bash
# ===========================================================================
# 03-analyze.sh — STAGE 3: 분석 (ANALYZE / EVIDENCE COLLECTION)
#
# Collects an immutable evidence bundle for a pod into a timestamped directory
# under ./incident-evidence/. Read-only with respect to cluster state.
#
# Collected:
#   - kubectl describe pod + owning workload
#   - current + previous container logs (all containers)
#   - namespace events (sorted, recent)
#   - NetworkPolicies in the namespace + which select this pod
#   - Falco events mentioning the pod / its node
#   - Prometheus error-rate & latency snapshot (instant + short range)
#   - pod spec, image digests, resource usage (if metrics-server present)
#
# Usage:
#   ./03-analyze.sh <namespace> <pod> [timestamp]
#
#   timestamp   Optional evidence-dir suffix. Default: UTC `date -u`
#               formatted as YYYYmmddTHHMMSSZ.
#
# Output: ./incident-evidence/<ts>__<ns>__<pod>/   (+ INDEX.md, MANIFEST.txt)
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help|"") usage 0;; esac

NS="$1"; POD="${2:-}"
[ -n "$POD" ] || { err "missing <pod>"; usage 1; }
TS="${3:-$(date -u +%Y%m%dT%H%M%SZ)}"

require_cmd kubectl jq
require_kubectl_ctx

kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 || warn "pod ${NS}/${POD} not currently present (will still collect events/netpol/metrics)."

EVID="${IR_EVIDENCE_DIR}/${TS}__${NS}__${POD}"
mkdir -p "$EVID"
section "STAGE 3 — ANALYZE  (ns=${NS} pod=${POD})  evidence=${EVID}"

# Helper: run a command, tee output into the evidence dir, never abort the run.
collect() {
  local outfile="$1"; shift
  info "collecting -> ${outfile}"
  { echo "### $* "; echo "### at $(_ts)"; echo; "$@"; } > "${EVID}/${outfile}" 2>&1 || warn "  (command returned non-zero; partial output saved)"
}

# ---------------------------------------------------------------------------
# 3a. Describe + spec
# ---------------------------------------------------------------------------
collect "describe-pod.txt"   kubectl -n "$NS" describe pod "$POD"
collect "pod.yaml"           kubectl -n "$NS" get pod "$POD" -o yaml

# Owning workload
OWNER_KIND="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
OWNER_NAME="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
WL_KIND=""; WL_NAME=""
if [ "$OWNER_KIND" = "ReplicaSet" ]; then
  WL_KIND="$(kubectl -n "$NS" get rs "$OWNER_NAME" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
  WL_NAME="$(kubectl -n "$NS" get rs "$OWNER_NAME" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
else
  WL_KIND="$OWNER_KIND"; WL_NAME="$OWNER_NAME"
fi
if [ -n "$WL_KIND" ] && [ -n "$WL_NAME" ]; then
  collect "describe-workload.txt" kubectl -n "$NS" describe "$WL_KIND" "$WL_NAME"
fi
echo "owning_workload=${WL_KIND}/${WL_NAME}" > "${EVID}/context.env"
NODE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
echo "node=${NODE}" >> "${EVID}/context.env"

# ---------------------------------------------------------------------------
# 3b. Logs — current + previous, all containers
# ---------------------------------------------------------------------------
CONTAINERS="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -z "$CONTAINERS" ]; then CONTAINERS="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || true)"; fi
for c in $CONTAINERS; do
  collect "logs-${c}-current.log"  kubectl -n "$NS" logs "$POD" -c "$c" --tail=2000 --timestamps
  collect "logs-${c}-previous.log" kubectl -n "$NS" logs "$POD" -c "$c" --previous --tail=2000 --timestamps
done

# ---------------------------------------------------------------------------
# 3c. Events
# ---------------------------------------------------------------------------
collect "events-namespace.txt" kubectl -n "$NS" get events --sort-by=.lastTimestamp
{ echo "### field-scoped events for pod ${POD}"; kubectl -n "$NS" get events --field-selector "involvedObject.name=${POD}" --sort-by=.lastTimestamp 2>&1; } > "${EVID}/events-pod.txt" || true

# ---------------------------------------------------------------------------
# 3d. NetworkPolicies (all in ns + which ones select this pod)
# ---------------------------------------------------------------------------
collect "networkpolicies.yaml" kubectl -n "$NS" get networkpolicy -o yaml
{
  echo "### NetworkPolicies whose podSelector matches pod ${POD}'s labels"
  echo "### at $(_ts)"; echo
  POD_LABELS="$(kubectl -n "$NS" get pod "$POD" -o json 2>/dev/null | jq -c '.metadata.labels // {}')"
  echo "pod labels: ${POD_LABELS}"
  echo
  kubectl -n "$NS" get networkpolicy -o json 2>/dev/null | jq -r --argjson pl "${POD_LABELS:-{}}" '
    .items[]
    | . as $np
    | ($np.spec.podSelector.matchLabels // {}) as $sel
    | select(($sel | length) == 0 or (($sel | to_entries) | all(.value == $pl[.key])))
    | "  MATCH: \($np.metadata.name)  policyTypes=\($np.spec.policyTypes // [])"
  ' 2>/dev/null || echo "  (jq match step skipped)"
} > "${EVID}/networkpolicies-matching.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 3e. Falco events for this pod / node
# ---------------------------------------------------------------------------
{
  echo "### Falco events mentioning pod=${POD} or node=${NODE}"
  echo "### at $(_ts)"; echo
  FALCO_PODS="$(kubectl -n "$FALCO_NAMESPACE" get pods -l app.kubernetes.io/name=falco -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  [ -z "$FALCO_PODS" ] && FALCO_PODS="$(kubectl -n "$FALCO_NAMESPACE" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i falco | grep -vi sidekick | tr '\n' ' ' || true)"
  for fp in $FALCO_PODS; do
    echo "--- falco pod: $fp ---"
    kubectl -n "$FALCO_NAMESPACE" logs "$fp" --tail=5000 2>/dev/null | grep -E "${POD}|${NODE:-__none__}" || echo "  (no matching lines)"
  done
} > "${EVID}/falco-events.txt" 2>&1 || true
info "collecting -> falco-events.txt"

# ---------------------------------------------------------------------------
# 3f. Prometheus error-rate & latency snapshot
# ---------------------------------------------------------------------------
{
  echo "### Prometheus snapshot for ns=${NS} pod=${POD}"
  echo "### at $(_ts)"; echo
  declare -a QUERIES=(
    "5xx rate (5m):::sum by (pod)(rate(http_requests_total{namespace=\"${NS}\",pod=\"${POD}\",code=~\"5..\"}[5m]))"
    "request rate (5m):::sum by (pod)(rate(http_requests_total{namespace=\"${NS}\",pod=\"${POD}\"}[5m]))"
    "p95 latency (5m):::histogram_quantile(0.95, sum by (le)(rate(http_request_duration_seconds_bucket{namespace=\"${NS}\",pod=\"${POD}\"}[5m])))"
    "container restarts:::sum by (pod)(kube_pod_container_status_restarts_total{namespace=\"${NS}\",pod=\"${POD}\"})"
    "memory working set:::sum by (pod)(container_memory_working_set_bytes{namespace=\"${NS}\",pod=\"${POD}\"})"
    "cpu usage (5m):::sum by (pod)(rate(container_cpu_usage_seconds_total{namespace=\"${NS}\",pod=\"${POD}\"}[5m]))"
  )
  for entry in "${QUERIES[@]}"; do
    label="${entry%%:::*}"; q="${entry##*:::}"
    echo "## ${label}"
    echo "   query: ${q}"
    if r="$(prom_query "$q" 2>/dev/null)" && echo "$r" | jq -e '.status=="success"' >/dev/null 2>&1; then
      echo "$r" | jq -r '.data.result[]? | "   => \(.metric|tostring) = \(.value[1])"' || echo "   (no samples)"
      echo "$r" | jq -e '.data.result|length>0' >/dev/null 2>&1 || echo "   (no samples)"
    else
      echo "   (query failed / Prometheus unreachable)"
    fi
    echo
  done
} > "${EVID}/prometheus-snapshot.txt" 2>&1 || true
info "collecting -> prometheus-snapshot.txt"

# ---------------------------------------------------------------------------
# 3g. Resource usage (best effort)
# ---------------------------------------------------------------------------
collect "top-pod.txt" kubectl -n "$NS" top pod "$POD" --containers

# ---------------------------------------------------------------------------
# 3h. Index + manifest
# ---------------------------------------------------------------------------
( cd "$EVID" && ls -la > MANIFEST.txt )
cat > "${EVID}/INDEX.md" <<EOF
# Incident evidence bundle

- **namespace:** ${NS}
- **pod:** ${POD}
- **owning workload:** ${WL_KIND}/${WL_NAME}
- **node:** ${NODE}
- **collected at (UTC):** $(_ts)
- **collected by:** $(whoami 2>/dev/null || echo unknown)

## Contents
| File | What |
|------|------|
| describe-pod.txt | \`kubectl describe pod\` |
| describe-workload.txt | \`kubectl describe ${WL_KIND}\` |
| pod.yaml | full pod spec/status |
| logs-*-current.log | current container logs (timestamped) |
| logs-*-previous.log | previous container logs (crash forensics) |
| events-namespace.txt | namespace events, time-sorted |
| events-pod.txt | events for this pod only |
| networkpolicies.yaml | all NetworkPolicies in ns |
| networkpolicies-matching.txt | which policies select this pod |
| falco-events.txt | Falco runtime-security hits for pod/node |
| prometheus-snapshot.txt | error-rate / latency / resource snapshot |
| top-pod.txt | live CPU/mem (metrics-server) |
EOF

section "ANALYZE complete"
echo "Evidence bundle: ${EVID}"
echo "Index:           ${EVID}/INDEX.md"
echo
echo "NEXT STEPS:"
echo "  - Recover when root cause understood: ./04-recover.sh ${NS} ${WL_NAME:-<workload>} --yes"
echo "  - Postmortem:                         ./05-retro.sh --evidence ${EVID}"
