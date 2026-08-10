#!/usr/bin/env bash
# iSCSI node-record preflight: detect open-iscsi persisted node records that the
# OTHER side of a Talos version boundary cannot parse, BEFORE you change version.
#
# WHY THIS CLASS OF BUG EXISTS. Talos ships open-iscsi via an extension image.
# Different open-iscsi releases have, in practice, renamed persisted node-record
# parameters (e.g. a `*_reopen_log_freq` field renamed between point releases).
# Neither side parses the other's parameter name, and `iscsiadm -m node` parses
# the WHOLE node database in one pass -- so ONE incompatible record can break
# attachment for EVERY Longhorn (or other iSCSI-backed) volume on that node.
# `/var/lib/iscsi` is host state: it survives the Talos upgrade AND a rollback,
# so rolling back does not undo it.
#
# The extension's own version number is not a reliable signal for this: it is
# possible for the extension version string to stay the same across a schematic
# bump while the embedded open-iscsi payload changes underneath it. Do not trust
# `talosctl get extensions` to tell you which side of the boundary a node is on
# -- verify against the actual open-iscsi release notes / changelog for your
# schematic instead.
#
# This is per-node persistent state, not a release-wide regression: a canary
# node upgrading cleanly proves nothing about the others, because each node
# carries its own copy of /var/lib/iscsi.
#
# THE GATE IS BROAD ON PURPOSE. It blocks when ANY node record or ANY active
# iSCSI session exists across a version boundary you've configured below --
# it does not grep for one specific parameter name. Two reasons:
#
#   1. The next boundary will rename something else. A parameter-specific check
#      silently passes the day a *different* field gets renamed.
#   2. Persisted records and live sessions are the hazard regardless of their
#      contents. An upgrade, reboot, or rollback while they exist is the
#      dangerous case.
#
# The clean path is to drain the node's storage workloads, then VERIFY that
# both the node-record database and active sessions are empty -- do not assume
# workload eviction guarantees deletion of every historical node record; that
# is what this script checks for. Manual quarantine (moving records aside) is
# the FALLBACK for a node that will not detach cleanly or crashed mid-drain,
# not the normal procedure.
#
# CONFIGURE talos_to_iscsi() BELOW before relying on this. It ships with no
# known mappings on purpose -- an unconfigured boundary must fail closed, never
# silently pass. See the comment above that function for how to determine your
# own mapping.
#
# READ-ONLY. Reports; never edits. Exit 0 clean, 1 findings, 2 undetermined.

set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
NODES_DIR=/var/lib/iscsi/nodes

# EDIT THESE for your own open-iscsi persisted-record incompatibility. These
# defaults are a common real-world example (a `conn_reopen_log_freq` /
# `sess_reopen_log_freq` rename) -- confirm against your own schematic's
# open-iscsi changelog before trusting them; do not assume your extension image
# hit the exact same rename on the exact same Talos versions.
OLD_PARAM="${ISCSI_OLD_PARAM:-node.session.conn_reopen_log_freq}"
NEW_PARAM="${ISCSI_NEW_PARAM:-node.session.sess_reopen_log_freq}"

# TARGET-AWARE, not "is the database self-consistent". The old open-iscsi
# release parses its own records perfectly well, so a generic `iscsiadm -m
# node` check on the running node passes right up until the moment you
# upgrade. The only question that matters is: can the open-iscsi version you
# are moving TO read what is on disk right now?
TARGET_TALOS="${TARGET_TALOS:-$(grep -oP '^\s*TALOS_VERSION:\s*\K\S+' \
  "${REPO}/clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml" 2>/dev/null)}"

# Map a Talos version to the open-iscsi release your schematic ships for it.
# UNCONFIGURED VERSIONS MUST RETURN "unknown" -- never guess. Work out your own
# mapping by pulling the node-record format (see below) on a couple of known
# Talos versions and diffing which parameter name each one writes, or by
# reading your extension image's open-iscsi changelog directly. Fill in real
# entries once you know your own boundaries; the placeholders below are only
# illustrative and will both resolve to "unknown" as shipped.
talos_to_iscsi() {
  case "$1" in
    # v1.13.[0-7]) echo 2.1.11 ;;
    # v1.13.8)     echo 2.1.12 ;;
    *)             echo unknown ;;
  esac
}

TARGET_ISCSI=$(talos_to_iscsi "$TARGET_TALOS")
case "$TARGET_ISCSI" in
  2.1.12) INCOMPATIBLE="$OLD_PARAM" ;;   # moving to 2.1.12: 2.1.11 records break it
  2.1.11) INCOMPATIBLE="$NEW_PARAM" ;;   # moving to 2.1.11: 2.1.12 records break it
  *)
    printf '  [ ????? ] unknown open-iscsi compatibility boundary for target %s\n' "${TARGET_TALOS:-<unset>}" >&2
    printf '            Refusing to guess. Configure talos_to_iscsi() before upgrading.\n' >&2
    echo; echo "VERDICT: UNDETERMINED (unknown target -- talos_to_iscsi() not configured for your cluster)"; exit 2 ;;
esac

findings=0; undet=0
bad()  { printf '  [ BLOCK ] %s\n' "$*"; findings=$((findings+1)); }
okay() { printf '  [ ok    ] %s\n' "$*"; }
huh()  { printf '  [ ????? ] %s\n' "$*"; undet=$((undet+1)); }

echo "=== iSCSI node-record preflight $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
printf '    target: Talos %s  ->  open-iscsi %s   (incompatible parameter: %s)\n\n' \
       "$TARGET_TALOS" "$TARGET_ISCSI" "$INCOMPATIBLE"

if ! command -v talosctl >/dev/null 2>&1; then
  huh "talosctl not on PATH"; echo; echo "VERDICT: UNDETERMINED"; exit 2
fi

# Absolute path: `direnv exec .` is cwd-relative and silently targets whatever
# ~/.kube/config points at if an earlier command changed directory. Read
# osImage pipe-delimited, NOT whitespace-split -- osImage looks like
# "Talos (v1.13.7)" and a naive whitespace read() truncates it to "Talos",
# which would make the version match never fire.
mapfile -t NODES < <(direnv exec "$REPO" kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}|{.status.addresses[?(@.type=="InternalIP")].address}|{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null)

if [[ ${#NODES[@]} -eq 0 ]]; then
  huh "could not list nodes -- indeterminate, NOT passing"; echo; echo "VERDICT: UNDETERMINED"; exit 2
fi

for entry in "${NODES[@]}"; do
  [[ -z "${entry// /}" ]] && continue
  IFS='|' read -r name ip os <<<"$entry"
  printf '%s (%s, %s)\n' "$name" "$ip" "${os:-?}"

  # A node already running the target crosses no boundary, so its records and
  # sessions are irrelevant -- they were written by the version it is on.
  # Without this the gate blocks on already-migrated nodes and can never
  # clear, which makes it noise rather than a gate.
  if [[ -n "$TARGET_TALOS" && "$os" == *"$TARGET_TALOS"* ]]; then
    okay "already on ${TARGET_TALOS} -- no version change, iSCSI state not a factor"
    echo; continue
  fi

  # Only storage nodes have a node database worth checking; a missing
  # directory on a control plane is expected, not a finding.
  if ! listing=$(direnv exec "$REPO" talosctl -n "$ip" ls -r "$NODES_DIR" 2>/dev/null); then
    ns=$(direnv exec "$REPO" talosctl -n "$ip" ls /sys/class/iscsi_session 2>/dev/null \
         | awk 'NR>1 && $NF!="." {n++} END {print n+0}')
    if (( ${ns:-0} > 0 )); then
      bad "no ${NODES_DIR}, but ${ns} active iSCSI session(s) -- drain before changing version"
    else
      okay "no ${NODES_DIR} and no sessions (not a storage node, or already drained)"
    fi
    echo; continue
  fi

  files=$(printf '%s\n' "$listing" | awk '{print $NF}' | grep -F 'default' || true)
  if [[ -z "${files// /}" ]]; then
    ns=$(direnv exec "$REPO" talosctl -n "$ip" ls /sys/class/iscsi_session 2>/dev/null \
         | awk 'NR>1 && $NF!="." {n++} END {print n+0}')
    if (( ${ns:-0} > 0 )); then
      bad "no records, but ${ns} active iSCSI session(s) -- drain before changing version"
    else
      okay "no node records and no active sessions -- safe to change version"
    fi
    echo; continue
  fi

  n_old=0; n_new=0; n_unread=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    path="$f"; [[ "$path" != /* ]] && path="${NODES_DIR}/${f}"
    if ! body=$(direnv exec "$REPO" talosctl -n "$ip" read "$path" 2>/dev/null); then
      n_unread=$((n_unread+1)); continue
    fi
    grep -qF "$OLD_PARAM" <<<"$body" && n_old=$((n_old+1))
    grep -qF "$NEW_PARAM" <<<"$body" && n_new=$((n_new+1))
  done <<<"$files"

  printf '           records: old-format=%d  new-format=%d  unreadable=%d\n' \
         "$n_old" "$n_new" "$n_unread"
  (( n_unread > 0 )) && huh "${n_unread} record(s) unreadable -- cannot classify"

  # Active sessions matter as much as persisted records: an upgrade or reboot
  # while sessions are live is the dangerous case, whatever the record
  # contents.
  n_sess=$(direnv exec "$REPO" talosctl -n "$ip" ls /sys/class/iscsi_session 2>/dev/null \
           | awk 'NR>1 && $NF!="." {n++} END {print n+0}')
  printf '           sessions: %s\n' "${n_sess:-?}"

  n_rec=$(( n_old + n_new ))
  if (( n_rec > 0 || ${n_sess:-0} > 0 )); then
    bad "${n_rec} record(s), ${n_sess:-?} session(s) present -- must be empty before a version change"
    if (( n_old > 0 && n_new > 0 )); then
      printf '           MIXED formats: the database already fails to parse under EITHER version.\n'
    elif [[ "$INCOMPATIBLE" == "$OLD_PARAM" ]] && (( n_old > 0 )); then
      printf '           %d of these are unreadable by the target open-iscsi %s.\n' "$n_old" "$TARGET_ISCSI"
    elif [[ "$INCOMPATIBLE" == "$NEW_PARAM" ]] && (( n_new > 0 )); then
      printf '           %d of these are unreadable by the target open-iscsi %s.\n' "$n_new" "$TARGET_ISCSI"
    fi
    printf '           PREFERRED FIX: cordon and cleanly DRAIN the node, then verify\n'
    printf '           both the node-record database and active sessions are empty.\n'
    printf '           Quarantining records by hand is the fallback when verification\n'
    printf '           fails or a node will not detach cleanly.\n'
  else
    okay "no node records and no active sessions -- safe to change version"
  fi
  echo
done

echo "-----------------------------------------------------------"
if (( findings > 0 )); then
  echo "VERDICT: BLOCKED -- ${findings} node(s) hold iSCSI state across a version change."
  echo "         This is per-node persistent state in /var/lib/iscsi. It survives"
  echo "         both upgrade and rollback, and a canary node does not protect the"
  echo "         others: every node carries its own records."
  exit 1
fi
(( undet > 0 )) && { echo "VERDICT: UNDETERMINED -- ${undet} check(s) inconclusive. Not a pass."; exit 2; }
echo "VERDICT: OK -- no incompatible iSCSI node records found."
exit 0
