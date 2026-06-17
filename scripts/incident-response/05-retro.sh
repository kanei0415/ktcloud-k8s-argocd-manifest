#!/usr/bin/env bash
# ===========================================================================
# 05-retro.sh — STAGE 5: 회고 (RETROSPECTIVE / POSTMORTEM)
#
# Generates a blameless-postmortem markdown from a template, pre-filling the
# parts we can derive automatically from an evidence bundle (timeline anchors,
# affected workload, detection/response timestamps, Falco/Prometheus excerpts)
# and leaving the human-judgement sections (root cause, 5-whys, action items)
# as prompts to complete.
#
# Read-only. Writes one markdown file.
#
# Usage:
#   ./05-retro.sh [options]
#
# Options:
#   --evidence DIR   Evidence bundle from 03-analyze (auto-fills context).
#   --title TEXT     Incident title.
#   --severity SEVn  SEV1 | SEV2 | SEV3 (default SEV2).
#   --out FILE       Output path. Default: ./postmortems/<date>-<slug>.md
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help) usage 0;; esac

EVIDENCE=""; TITLE=""; SEVERITY="SEV2"; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --evidence) EVIDENCE="${2:-}"; shift ;;
    --title)    TITLE="${2:-}"; shift ;;
    --severity) SEVERITY="${2:-SEV2}"; shift ;;
    --out)      OUT="${2:-}"; shift ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

require_cmd date

# --- Derive context from the evidence bundle (best effort) -----------------
NS="<namespace>"; POD="<pod>"; WORKLOAD="<workload>"; NODE="<node>"
COLLECTED_AT="<unknown>"; FALCO_EXCERPT="(no Falco excerpt available)"; PROM_EXCERPT="(no Prometheus excerpt available)"
if [ -n "$EVIDENCE" ] && [ -d "$EVIDENCE" ]; then
  info "reading evidence bundle: ${EVIDENCE}"
  base="$(basename "$EVIDENCE")"      # <ts>__<ns>__<pod>
  COLLECTED_AT="${base%%__*}"
  rest="${base#*__}"; NS="${rest%%__*}"; POD="${rest#*__}"
  if [ -f "${EVIDENCE}/context.env" ]; then
    while IFS='=' read -r k v; do
      case "$k" in owning_workload) WORKLOAD="$v";; node) NODE="$v";; esac
    done < "${EVIDENCE}/context.env"
  fi
  [ -f "${EVIDENCE}/falco-events.txt" ] && FALCO_EXCERPT="$(grep -Ev '^###|^$' "${EVIDENCE}/falco-events.txt" | head -12 || true)"
  [ -f "${EVIDENCE}/prometheus-snapshot.txt" ] && PROM_EXCERPT="$(grep -E '^##|=>' "${EVIDENCE}/prometheus-snapshot.txt" | head -24 || true)"
  [ -z "$FALCO_EXCERPT" ] && FALCO_EXCERPT="(no matching Falco lines in bundle)"
  [ -z "$PROM_EXCERPT" ]  && PROM_EXCERPT="(no Prometheus samples in bundle)"
else
  warn "no --evidence dir given (or not found); generating a blank template."
fi

[ -n "$TITLE" ] || TITLE="${POD} incident in ${NS}"
SLUG="$(echo "$TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-50)"
TODAY="$(date -u +%Y-%m-%d)"
if [ -z "$OUT" ]; then
  mkdir -p ./postmortems
  OUT="./postmortems/${TODAY}-${SLUG}.md"
fi

# --- Render -----------------------------------------------------------------
cat > "$OUT" <<EOF
# Postmortem — ${TITLE}

> Blameless postmortem. Focus on systems and process, not individuals.
> Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by 05-retro.sh
> Stage 5 (회고) of the KTCloud Incident Response process. See
> \`docs/INCIDENT-RESPONSE.md\`.

| Field | Value |
|-------|-------|
| Incident ID | INC-${TODAY//-/}-_____ |
| Severity | ${SEVERITY} |
| Status | DRAFT |
| Namespace | ${NS} |
| Affected workload | ${WORKLOAD} |
| Affected pod(s) | ${POD} |
| Node | ${NODE} |
| Evidence bundle | ${EVIDENCE:-N/A} |
| Authors | <you> |
| Reviewers | <SRE lead>, <service owner> |

---

## 1. Summary
_2–3 sentences: what broke, who was impacted, how long, current status._

## 2. Impact
- **Customer impact:** _e.g. checkout failures, elevated 5xx, latency._
- **Scope / blast radius:** _which services / % of traffic._
- **Duration:** _start → mitigated → resolved._
- **Data impact / security impact:** _any data exposure? (relevant if Falco-triggered)._

## 3. Timeline (UTC)
_Fill exact times. Anchors below are pre-populated from automation._

| Time (UTC) | Event | Source |
|------------|-------|--------|
| _T0_ | First bad signal (alert fired / Falco event) | Prometheus / Falco |
| _T_  | DETECTED — \`01-detect.sh\` triage run | Stage 1 |
| _T_  | ISOLATED — quarantine NetworkPolicy + label applied | Stage 2 (\`02-isolate.sh\`) |
| ${COLLECTED_AT} | EVIDENCE collected — \`03-analyze.sh\` | Stage 3 |
| _T_  | RECOVERED — rollback + de-quarantine, workload Ready | Stage 4 (\`04-recover.sh\`) |
| _T_  | RESOLVED — error-rate back to baseline | Verification |

## 4. Detection & response metrics
| Metric | Target | Actual |
|--------|--------|--------|
| MTTD (time to detect) | SEV1 ≤ 5m / SEV2 ≤ 15m | _____ |
| MTTA (time to acknowledge) | ≤ 10m | _____ |
| Time to isolate | — | _____ |
| MTTR (time to recover) | SEV1 ≤ 1h / SEV2 ≤ 4h | _____ |
| Detection source | — | _Prometheus alert / Falco / customer report_ |

## 5. Root cause
_What actually caused it. Distinguish trigger from underlying cause._

## 6. Five whys
1. **Why** did the incident happen? →
2. **Why?** →
3. **Why?** →
4. **Why?** →
5. **Why? (root)** →

## 7. What went well / what went poorly
- Went well: _detection automation, fast isolation, clean rollback…_
- Went poorly: _alert noise, missing dashboard, slow paging…_
- Where we got lucky: _…_

## 8. Action items
| # | Action | Type (prevent/detect/mitigate) | Owner | Due | Tracking |
|---|--------|-------------------------------|-------|-----|----------|
| 1 |        | prevent | | | |
| 2 |        | detect  | | | |
| 3 |        | mitigate| | | |

## 9. Evidence appendix

### Falco (runtime security) excerpt
\`\`\`
${FALCO_EXCERPT}
\`\`\`

### Prometheus snapshot excerpt
\`\`\`
${PROM_EXCERPT}
\`\`\`

### Full evidence bundle
${EVIDENCE:+See \`${EVIDENCE}/\` (describe, logs current+previous, events, NetworkPolicies, Falco, Prometheus).}
${EVIDENCE:-_No automated bundle attached; attach \`kubectl describe\`/logs manually._}
EOF

section "RETROSPECTIVE — postmortem draft written"
echo "Output: ${OUT}"
echo
echo "NEXT STEPS:"
echo "  - Fill sections 1–8 (root cause, 5-whys, action items)."
echo "  - Circulate in #incident; file action items as tracked issues."
