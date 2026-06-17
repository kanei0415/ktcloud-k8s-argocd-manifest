#!/usr/bin/env bash
# ===========================================================================
# 02-isolate.sh — STAGE 2: 격리 (ISOLATE / QUARANTINE)
#
# Contains a suspected-compromised or misbehaving workload by:
#   1. recording the pre-change state (so 04-recover can reverse it),
#   2. labelling the workload pods with a quarantine label,
#   3. applying a default-deny NetworkPolicy scoped to that label,
#   4. (optionally) scaling the workload to 0 replicas, and/or cordoning a node.
#
# MUTATING. Requires --yes. Idempotent: re-running re-applies the same objects.
#
# Usage:
#   ./02-isolate.sh <namespace> <target> [options] --yes
#
#   <target>    deploy/NAME | deployment/NAME | rollout/NAME | pod/NAME
#               (pod targets are mapped back to their owning workload for
#                scale/label operations; the pod is always labelled directly).
#
# Options:
#   --scale-zero     Scale the workload down to 0 replicas (full stop).
#   --cordon-node    Cordon the node the (first) target pod runs on.
#   --no-netpol      Skip applying the default-deny NetworkPolicy.
#   --yes            REQUIRED. Confirms the mutation.
#
# Backups written to: $IR_STATE_DIR/<ns>__<workload>/
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help|"") usage 0;; esac

NS="$1"; TARGET="${2:-}"; shift 2 || true
[ -n "$TARGET" ] || { err "missing <target>"; usage 1; }

SCALE_ZERO=0; CORDON=0; NO_NETPOL=0; CONFIRM=""
for arg in "$@"; do
  case "$arg" in
    --scale-zero)  SCALE_ZERO=1 ;;
    --cordon-node) CORDON=1 ;;
    --no-netpol)   NO_NETPOL=1 ;;
    --yes)         CONFIRM="--yes" ;;
    *) die "unknown option: $arg" ;;
  esac
done

require_cmd kubectl jq
require_kubectl_ctx
ensure_confirmed "$CONFIRM"

# --- Resolve target into kind/name and a pod selector ----------------------
KIND="${TARGET%%/*}"; NAME="${TARGET#*/}"
[ "$KIND" != "$TARGET" ] || die "target must be in kind/name form, e.g. deploy/order-service"

WORKLOAD_KIND=""; WORKLOAD_NAME=""; POD_SELECTOR=""; SINGLE_POD=""
case "$KIND" in
  pod)
    SINGLE_POD="$NAME"
    kubectl -n "$NS" get pod "$NAME" >/dev/null 2>&1 || die "pod ${NS}/${NAME} not found."
    # Find owning workload via ownerReferences (ReplicaSet/Rollout/StatefulSet).
    OWNER_KIND="$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
    OWNER_NAME="$(kubectl -n "$NS" get pod "$NAME" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
    if [ "$OWNER_KIND" = "ReplicaSet" ]; then
      WORKLOAD_NAME="$(kubectl -n "$NS" get rs "$OWNER_NAME" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
      WORKLOAD_KIND="$(kubectl -n "$NS" get rs "$OWNER_NAME" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)"
    else
      WORKLOAD_KIND="$OWNER_KIND"; WORKLOAD_NAME="$OWNER_NAME"
    fi
    info "pod ${NAME} belongs to ${WORKLOAD_KIND:-?}/${WORKLOAD_NAME:-?}"
    ;;
  deploy|deployment)
    WORKLOAD_KIND="Deployment"; WORKLOAD_NAME="$NAME"
    POD_SELECTOR="$(kubectl -n "$NS" get deploy "$NAME" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)" \
      || die "deployment ${NS}/${NAME} not found."
    ;;
  rollout)
    WORKLOAD_KIND="Rollout"; WORKLOAD_NAME="$NAME"
    is_rollout "$NS" "$NAME" || die "rollout ${NS}/${NAME} not found."
    POD_SELECTOR="$(kubectl -n "$NS" get rollout "$NAME" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)"
    ;;
  *) die "unsupported kind '$KIND' (use pod/deploy/rollout)";;
esac

WL_TAG="$(echo "${WORKLOAD_NAME:-$NAME}" | tr '/:' '__')"
BACKUP_DIR="${IR_STATE_DIR}/${NS}__${WL_TAG}"
mkdir -p "$BACKUP_DIR"
section "STAGE 2 — ISOLATE  (ns=${NS} target=${TARGET})  backup=${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# 2a. Snapshot current state for the recover stage
# ---------------------------------------------------------------------------
{
  echo "namespace=${NS}"
  echo "target=${TARGET}"
  echo "workload_kind=${WORKLOAD_KIND}"
  echo "workload_name=${WORKLOAD_NAME}"
  echo "quarantine_label=${QUARANTINE_LABEL_KEY}=${QUARANTINE_LABEL_VAL}"
  echo "netpol_name=quarantine-deny-${WL_TAG}"
  echo "scaled_zero=${SCALE_ZERO}"
  echo "cordon=${CORDON}"
  echo "isolated_at=$(_ts)"
} > "${BACKUP_DIR}/isolation.env"

if [ -n "$WORKLOAD_NAME" ] && [ -n "$WORKLOAD_KIND" ]; then
  PREV_REPLICAS="$(kubectl -n "$NS" get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
  echo "prev_replicas=${PREV_REPLICAS}" >> "${BACKUP_DIR}/isolation.env"
  kubectl -n "$NS" get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -o yaml > "${BACKUP_DIR}/workload-before.yaml" 2>/dev/null || true
  info "recorded prev_replicas=${PREV_REPLICAS:-<unknown>} for ${WORKLOAD_KIND}/${WORKLOAD_NAME}"
fi

# ---------------------------------------------------------------------------
# 2b. Quarantine label (on pod and/or workload pod template)
# ---------------------------------------------------------------------------
section "2b. Applying quarantine label ${QUARANTINE_LABEL_KEY}=${QUARANTINE_LABEL_VAL}"
if [ -n "$SINGLE_POD" ]; then
  kubectl -n "$NS" label pod "$SINGLE_POD" "${QUARANTINE_LABEL_KEY}=${QUARANTINE_LABEL_VAL}" --overwrite
  info "labelled pod ${SINGLE_POD}"
fi
if [ -n "$WORKLOAD_NAME" ] && [ -n "$WORKLOAD_KIND" ]; then
  # Label all current pods of the workload (immediate effect, no restart).
  if [ -n "$POD_SELECTOR" ]; then
    SEL="$(echo "$POD_SELECTOR" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")' 2>/dev/null || true)"
    if [ -n "$SEL" ]; then
      kubectl -n "$NS" label pods -l "$SEL" "${QUARANTINE_LABEL_KEY}=${QUARANTINE_LABEL_VAL}" --overwrite || true
      info "labelled running pods matching: ${SEL}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2c. Default-deny NetworkPolicy scoped to the quarantine label
# ---------------------------------------------------------------------------
if [ "$NO_NETPOL" -eq 0 ]; then
  NETPOL_NAME="quarantine-deny-${WL_TAG}"
  section "2c. Applying default-deny NetworkPolicy: ${NETPOL_NAME}"
  cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NETPOL_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/managed-by: ktcloud-incident-response
    ktcloud.io/incident-stage: isolate
  annotations:
    ktcloud.io/quarantine-target: "${TARGET}"
    ktcloud.io/isolated-at: "$(_ts)"
spec:
  podSelector:
    matchLabels:
      ${QUARANTINE_LABEL_KEY}: "${QUARANTINE_LABEL_VAL}"
  policyTypes:
    - Ingress
    - Egress
  # No ingress/egress rules => deny all traffic to and from quarantined pods.
  ingress: []
  egress: []
YAML
  info "NetworkPolicy ${NETPOL_NAME} applied (deny-all ingress+egress)."
else
  warn "skipping NetworkPolicy (--no-netpol)."
fi

# ---------------------------------------------------------------------------
# 2d. Optional scale-to-zero
# ---------------------------------------------------------------------------
if [ "$SCALE_ZERO" -eq 1 ] && [ -n "$WORKLOAD_NAME" ]; then
  section "2d. Scaling ${WORKLOAD_KIND}/${WORKLOAD_NAME} to 0"
  if [ "$WORKLOAD_KIND" = "Rollout" ]; then
    kubectl -n "$NS" patch rollout "$WORKLOAD_NAME" --type=merge -p '{"spec":{"replicas":0}}'
  else
    kubectl -n "$NS" scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" --replicas=0
  fi
  info "scaled to 0 (previous replicas recorded in isolation.env)."
fi

# ---------------------------------------------------------------------------
# 2e. Optional node cordon
# ---------------------------------------------------------------------------
if [ "$CORDON" -eq 1 ]; then
  section "2e. Cordoning node"
  PODNAME="${SINGLE_POD:-}"
  if [ -z "$PODNAME" ] && [ -n "$POD_SELECTOR" ]; then
    SEL="$(echo "$POD_SELECTOR" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")' 2>/dev/null || true)"
    PODNAME="$(kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [ -n "$PODNAME" ]; then
    NODE="$(kubectl -n "$NS" get pod "$PODNAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    if [ -n "$NODE" ]; then
      echo "cordoned_node=${NODE}" >> "${BACKUP_DIR}/isolation.env"
      kubectl cordon "$NODE"
      info "cordoned node ${NODE} (recorded for uncordon during recover)."
    else
      warn "could not resolve node for pod ${PODNAME}."
    fi
  else
    warn "no pod resolved; skipping cordon."
  fi
fi

section "ISOLATE complete"
cat <<EOF
Isolation recorded at: ${BACKUP_DIR}/isolation.env
NEXT STEPS:
  - Collect evidence:  ./03-analyze.sh ${NS} <POD>
  - Notify #security-report and #incident (severity-dependent).
  - When safe, reverse with: ./04-recover.sh ${NS} ${WORKLOAD_NAME:-<workload>} --yes
EOF
