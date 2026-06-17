#!/usr/bin/env bash
# ===========================================================================
# 04-recover.sh — STAGE 4: 복구 (RECOVER)
#
# Reverses the incident and restores service:
#   1. roll back the workload to the previous good revision
#      - Argo Rollout  -> `kubectl argo rollouts undo`
#      - Deployment/STS -> `kubectl rollout undo`
#   2. remove the quarantine NetworkPolicy + quarantine label applied by 02,
#   3. uncordon any node cordoned by 02,
#   4. scale back to the replica count recorded by 02 (if it scaled to 0),
#   5. wait for the workload to become Ready and verify.
#
# MUTATING. Requires --yes.
#
# Usage:
#   ./04-recover.sh <namespace> <workload> [options] --yes
#
#   <workload>  Bare name (auto-detects Rollout vs Deployment vs StatefulSet)
#               or kind/name to force it.
#
# Options:
#   --no-rollback     Skip the revision rollback (only de-quarantine + scale).
#   --to-revision N   Roll back to a specific revision number.
#   --timeout SECS    Readiness wait timeout (default 300).
#   --yes             REQUIRED.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help|"") usage 0;; esac

NS="$1"; WL_ARG="${2:-}"; shift 2 || true
[ -n "$WL_ARG" ] || { err "missing <workload>"; usage 1; }

NO_ROLLBACK=0; TO_REVISION=""; TIMEOUT=300; CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-rollback) NO_ROLLBACK=1 ;;
    --to-revision) TO_REVISION="${2:-}"; shift ;;
    --timeout)     TIMEOUT="${2:-300}"; shift ;;
    --yes)         CONFIRM="--yes" ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

require_cmd kubectl jq
require_kubectl_ctx
ensure_confirmed "$CONFIRM"

# --- Detect workload kind ---------------------------------------------------
if [[ "$WL_ARG" == */* ]]; then
  WL_KIND="${WL_ARG%%/*}"; WL_NAME="${WL_ARG#*/}"
  case "$WL_KIND" in deploy|deployment) WL_KIND="Deployment";; rollout) WL_KIND="Rollout";; statefulset|sts) WL_KIND="StatefulSet";; esac
else
  WL_NAME="$WL_ARG"
  if is_rollout "$NS" "$WL_NAME"; then
    WL_KIND="Rollout"
  elif kubectl -n "$NS" get deploy "$WL_NAME" >/dev/null 2>&1; then
    WL_KIND="Deployment"
  elif kubectl -n "$NS" get statefulset "$WL_NAME" >/dev/null 2>&1; then
    WL_KIND="StatefulSet"
  else
    die "workload '${WL_NAME}' not found as Rollout/Deployment/StatefulSet in ${NS}."
  fi
fi
WL_TAG="$(echo "$WL_NAME" | tr '/:' '__')"
BACKUP_DIR="${IR_STATE_DIR}/${NS}__${WL_TAG}"
section "STAGE 4 — RECOVER  (ns=${NS} ${WL_KIND}/${WL_NAME})  backup=${BACKUP_DIR}"

# Load isolation backup if present
PREV_REPLICAS=""; SCALED_ZERO="0"; CORDONED_NODE=""; NETPOL_NAME="quarantine-deny-${WL_TAG}"
if [ -f "${BACKUP_DIR}/isolation.env" ]; then
  info "loading isolation backup ${BACKUP_DIR}/isolation.env"
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "$k" in
      prev_replicas) PREV_REPLICAS="$v" ;;
      scaled_zero)   SCALED_ZERO="$v" ;;
      cordoned_node) CORDONED_NODE="$v" ;;
      netpol_name)   NETPOL_NAME="$v" ;;
    esac
  done < "${BACKUP_DIR}/isolation.env"
else
  warn "no isolation backup found; proceeding with defaults (netpol=${NETPOL_NAME}). De-quarantine still attempted."
fi

# ---------------------------------------------------------------------------
# 4a. Roll back to previous good revision
# ---------------------------------------------------------------------------
if [ "$NO_ROLLBACK" -eq 0 ]; then
  section "4a. Rolling back ${WL_KIND}/${WL_NAME}"
  if [ "$WL_KIND" = "Rollout" ]; then
    require_cmd kubectl-argo-rollouts || true
    if kubectl argo rollouts version >/dev/null 2>&1; then
      if [ -n "$TO_REVISION" ]; then
        kubectl argo rollouts undo "$WL_NAME" -n "$NS" --to-revision="$TO_REVISION"
      else
        kubectl argo rollouts undo "$WL_NAME" -n "$NS"
      fi
    else
      warn "kubectl-argo-rollouts plugin unavailable; falling back to abort+retry via kubectl patch."
      kubectl argo rollouts undo "$WL_NAME" -n "$NS" 2>/dev/null \
        || die "cannot roll back Rollout without the argo-rollouts plugin."
    fi
  else
    if [ -n "$TO_REVISION" ]; then
      kubectl -n "$NS" rollout undo "$WL_KIND" "$WL_NAME" --to-revision="$TO_REVISION"
    else
      kubectl -n "$NS" rollout undo "$WL_KIND" "$WL_NAME"
    fi
  fi
  info "rollback issued."
else
  warn "skipping rollback (--no-rollback)."
fi

# ---------------------------------------------------------------------------
# 4b. Remove quarantine NetworkPolicy
# ---------------------------------------------------------------------------
section "4b. Removing quarantine NetworkPolicy ${NETPOL_NAME}"
if kubectl -n "$NS" get networkpolicy "$NETPOL_NAME" >/dev/null 2>&1; then
  kubectl -n "$NS" delete networkpolicy "$NETPOL_NAME"
  info "deleted NetworkPolicy ${NETPOL_NAME}."
else
  info "NetworkPolicy ${NETPOL_NAME} not present (already removed)."
fi

# ---------------------------------------------------------------------------
# 4c. Remove quarantine label from pods + template
# ---------------------------------------------------------------------------
section "4c. Removing quarantine label ${QUARANTINE_LABEL_KEY}"
kubectl -n "$NS" label pods -l "${QUARANTINE_LABEL_KEY}=${QUARANTINE_LABEL_VAL}" "${QUARANTINE_LABEL_KEY}-" 2>/dev/null \
  && info "removed quarantine label from matching pods." \
  || info "no pods carried the quarantine label."

# ---------------------------------------------------------------------------
# 4d. Scale back up
# ---------------------------------------------------------------------------
if [ "$SCALED_ZERO" = "1" ]; then
  TARGET_REPLICAS="${PREV_REPLICAS:-1}"
  [ -n "$TARGET_REPLICAS" ] && [ "$TARGET_REPLICAS" != "0" ] || TARGET_REPLICAS=1
  section "4d. Scaling ${WL_KIND}/${WL_NAME} back to ${TARGET_REPLICAS}"
  if [ "$WL_KIND" = "Rollout" ]; then
    kubectl -n "$NS" patch rollout "$WL_NAME" --type=merge -p "{\"spec\":{\"replicas\":${TARGET_REPLICAS}}}"
  else
    kubectl -n "$NS" scale "$WL_KIND" "$WL_NAME" --replicas="$TARGET_REPLICAS"
  fi
else
  info "workload was not scaled to zero by isolate; leaving replica count unchanged."
fi

# ---------------------------------------------------------------------------
# 4e. Uncordon node
# ---------------------------------------------------------------------------
if [ -n "$CORDONED_NODE" ]; then
  section "4e. Uncordoning node ${CORDONED_NODE}"
  kubectl uncordon "$CORDONED_NODE" && info "uncordoned ${CORDONED_NODE}." || warn "failed to uncordon ${CORDONED_NODE}."
fi

# ---------------------------------------------------------------------------
# 4f. Wait for healthy / Ready and verify
# ---------------------------------------------------------------------------
section "4f. Waiting for ${WL_KIND}/${WL_NAME} to become Ready (timeout ${TIMEOUT}s)"
OK=0
if [ "$WL_KIND" = "Rollout" ]; then
  if kubectl argo rollouts status "$WL_NAME" -n "$NS" --timeout "${TIMEOUT}s" >/dev/null 2>&1; then OK=1; fi
  kubectl argo rollouts get rollout "$WL_NAME" -n "$NS" 2>/dev/null | head -30 || true
else
  if kubectl -n "$NS" rollout status "$WL_KIND/$WL_NAME" --timeout="${TIMEOUT}s"; then OK=1; fi
fi

section "Verification"
kubectl -n "$NS" get "$WL_KIND" "$WL_NAME" -o wide 2>/dev/null || true
# Pod readiness summary
DESIRED="$(kubectl -n "$NS" get "$WL_KIND" "$WL_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
READY="$(kubectl -n "$NS" get "$WL_KIND" "$WL_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
info "readyReplicas=${READY:-0} / desired=${DESIRED}"

if [ "$OK" -eq 1 ]; then
  section "RECOVER complete — workload reports Ready"
else
  warn "workload did NOT reach Ready within ${TIMEOUT}s. Investigate before declaring resolved."
fi
cat <<EOF
NEXT STEPS:
  - Confirm error-rate has normalised (re-run ./01-detect.sh ${NS}).
  - Write the postmortem: ./05-retro.sh --evidence ./incident-evidence/<bundle>
EOF
[ "$OK" -eq 1 ] || exit 2
