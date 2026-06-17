# shellcheck shell=bash
# ---------------------------------------------------------------------------
# lib-common.sh — shared helpers for the incident-response toolkit.
# Sourced (not executed) by 0[1-5]-*.sh. Do NOT add `set -euo pipefail` here;
# the calling script owns that. This file only defines functions/vars.
# ---------------------------------------------------------------------------

# --- Cluster-specific defaults (override via env) --------------------------
: "${APP_NAMESPACE:=ktcloud-market-msa}"
: "${PROM_SVC:=kps-prometheus.kube-prometheus-stack.svc:9090}"
: "${ALERTMANAGER_SVC:=kps-alertmanager.kube-prometheus-stack.svc:9093}"
: "${FALCO_NAMESPACE:=falco}"
: "${LOGGING_NAMESPACE:=logging}"
: "${ROLLOUTS_NAMESPACE:=argo-rollouts}"
# Workloads managed by Argo Rollouts (rollback = `kubectl argo rollouts undo`).
: "${ROLLOUT_WORKLOADS:=order-service}"
# Where 02-isolate stores backups so 04-recover can reverse them.
: "${IR_STATE_DIR:=./incident-state}"
: "${IR_EVIDENCE_DIR:=./incident-evidence}"
# Label key/value used to mark quarantined workloads.
: "${QUARANTINE_LABEL_KEY:=ktcloud.io/quarantine}"
: "${QUARANTINE_LABEL_VAL:=true}"

# --- Logging ---------------------------------------------------------------
_ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()   { echo "[$(_ts)] $*"; }
info()  { echo "[$(_ts)] INFO  $*"; }
warn()  { echo "[$(_ts)] WARN  $*" >&2; }
err()   { echo "[$(_ts)] ERROR $*" >&2; }
die()   { err "$*"; exit 1; }
section() { echo; echo "==================================================================="; echo ">>> $*"; echo "==================================================================="; }

# --- Preconditions ---------------------------------------------------------
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "required command not found on PATH: $c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "install the missing prerequisites and retry."
}

require_kubectl_ctx() {
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach the cluster (check the SSH tunnel / kubeconfig)."
}

# --- Prometheus / Alertmanager access --------------------------------------
# In-cluster ClusterIP services are not reachable from the operator laptop, so
# we proxy every HTTP call through `kubectl run` (curl in an ephemeral pod) or
# fall back to `kubectl exec` into the prometheus pod. PROM_QUERY_MODE lets the
# operator force a mode: "run" (default), or "local" if they already have a
# port-forward / direct route open.
: "${PROM_QUERY_MODE:=run}"
: "${CURL_IMAGE:=curlimages/curl:8.10.1}"

# http_get <url> -> stdout body, non-zero on transport failure
http_get() {
  local url="$1"
  case "$PROM_QUERY_MODE" in
    local)
      curl -sS --max-time 15 "$url"
      ;;
    run|*)
      # Ephemeral, auto-cleaned pod in the monitoring namespace.
      kubectl -n kube-prometheus-stack run "ir-curl-$$-$RANDOM" \
        --image="$CURL_IMAGE" --restart=Never --rm -i --quiet \
        --command -- curl -sS --max-time 15 "$url" 2>/dev/null
      ;;
  esac
}

alertmanager_get() { http_get "http://${ALERTMANAGER_SVC}$1"; }
prometheus_get()   { http_get "http://${PROM_SVC}$1"; }

# URL-encode a PromQL expression with jq (already a prerequisite).
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# prom_query <promql>  -> instant query, returns the parsed jq result table
prom_query() {
  local q enc
  q="$1"; enc="$(urlencode "$q")"
  prometheus_get "/api/v1/query?query=${enc}"
}

# --- Workload type detection ------------------------------------------------
# is_rollout <namespace> <name> -> 0 if an Argo Rollout object exists
is_rollout() {
  local ns="$1" name="$2"
  kubectl -n "$ns" get rollout "$name" >/dev/null 2>&1
}

# confirm guard: scripts that mutate require --yes (passed in as $1=flag)
ensure_confirmed() {
  local flag="${1:-}"
  if [ "$flag" != "--yes" ]; then
    die "refusing to mutate without confirmation. Re-run with --yes once you have reviewed the target."
  fi
}
