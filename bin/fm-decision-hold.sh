#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh attest <origin-id> <decision-key> \
#     --decision-file <path> --note <one-line> [--routed-to <task-id>...]
#   fm-decision-hold.sh amend <origin-id> <decision-key> \
#     --decision-file <path> --note <one-line> [--routed-to <task-id>...]
#   fm-decision-hold.sh supersede <origin-id> <decision-key> \
#     --duplicate-of <hold-id> --note <one-line>
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# An explicit `--none` durably records the reviewed legacy unkeyed ("default")
# status event. A later default event is a new decision and remains uncovered.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
#
# `attest`, `amend`, and `supersede` are explicit operator-invoked repair paths for
# a hold `resolve` can no longer reach, never a silent bypass: each still requires
# a real decision file (or an authoritative peer hold) and a one-line `--note`
# recording what evidence justifies the repair, and each writes a body marker
# distinguishable from an ordinary `resolve`.
# `attest` durably records a decision for a hold already closed outside this
# script (state done, kind captain) that has never carried a resolution record; an
# exact retry of an attested identity succeeds, while changed evidence is refused.
# `amend` (re)writes the resolution record for a hold already closed outside this
# script, whether the record is absent (an external body update wiped it) or
# present but wrong (the captain corrected an earlier ruling); it always requires
# `--note` and always overwrites.
# `supersede` retires a duplicate hold that investigates the same question as an
# already durable (actively held or resolved) authoritative hold, following any
# superseded links and refusing cycles so the gate cannot accept fabricated
# mutual attestations.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

status_default_decision_fingerprint() {  # <status-file>
  local status_file=$1 line verb key line_no=0 current=''
  [ -f "$status_file" ] || { printf 'none'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    key=$(_fm_decision_key "$line") || continue
    [ "$key" = default ] || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked) current=$(sha256_text "$line_no:$line") ;;
      resolved|captain-held) current='' ;;
    esac
  done < "$status_file"
  printf '%s' "${current:-none}"
}

mark_none_attested() {  # <meta> <status-fingerprint>
  printf 'decision_none_status=%s\n' "$2" >> "$1"
}

none_attested() {  # <meta> <status-fingerprint>
  [ "$(meta_value "$1" decision_none_status)" = "$2" ]
}

# 0 if <key> needs no captain-held backlog entry: either it is in the reviewed
# <keys> list, or it is the legacy unkeyed "default" status decision and this
# exact status event was durably attested with --none. A --none pass records no
# hold for "default" (there is nothing to hold), so unlike every other key it can
# be satisfied only by its matching status-event fingerprint.
key_is_covered() {  # <keys> <key> <meta> <status-file>
  local keys=$1 key=$2 meta=$3 status_file=$4 current
  list_has_key "$keys" "$key" && return 0
  [ "$key" = default ] || return 1
  [ -f "$meta" ] || return 1
  current=$(status_default_decision_fingerprint "$status_file")
  none_attested "$meta" "$current"
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body routes
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*)
      case "$body" in
        *'\nDecision digest: '*'\nRouted identities: '*'\nCaptain decision:'*'\nRouted work:'*)
          routes=$(resolution_routed_csv "$body")
          [ -n "$routes" ] && return 0
          ;;
      esac
      ;;
  esac
  return 1
}

resolution_routed_csv() {  # <hold-body>
  local body=$1 fields
  case "$body" in
    *'\nRouted identities: '*)
      fields=${body#*'\nRouted identities: '}
      fields=${fields%%\\n*}
      fields=${fields%\"}
      printf '%s' "$fields"
      ;;
  esac
}

verify_resolution_note() {  # <hold-id> <hold-body> <label> <expected>
  local id=$1 body=$2 label=$3 expected=$4 fields recorded
  case "$body" in
    *"\\n$label: "*)
      fields=${body#*"\\n$label: "}
      recorded=${fields%%\\n*}
      recorded=${recorded%\"}
      [ "$recorded" = "$expected" ] \
        || fail "captain hold $id records a different $label"
      ;;
    *) fail "captain hold $id has no $label retry identity" ;;
  esac
}

hold_superseded_peer() {  # <hold-body>
  local body=$1 peer
  case "$body" in
    *"Superseded by fm-decision-hold."*"Duplicate of: "*)
      peer=${body#*"Duplicate of: "}
      peer=${peer%%\\n*}
      peer=${peer%\"}
      printf '%s' "$peer"
      ;;
  esac
}

verify_hold_durable_chain() {  # <hold-id> <seen-csv>
  local id=$1 seen=$2 show state held kind hold_kind body peer next_seen
  case ",$seen," in
    *",$id,"*) return 2 ;;
  esac
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    verify_hold_resolved "$id" && return 0
    case "$body" in
      *"Superseded by fm-decision-hold."*"Duplicate of: "*)
        peer=$(hold_superseded_peer "$body")
        validate_slug duplicate-of "$peer" >/dev/null 2>&1 || return 1
        next_seen=$seen
        [ -n "$next_seen" ] && next_seen="$next_seen,"
        verify_hold_durable_chain "$peer" "${next_seen}${id}"
        return $?
        ;;
    esac
  fi
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 seen=${2:-} rc
  if verify_hold_durable_chain "$id" "$seen"; then
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    2) fail "captain decision $id has a supersede cycle" ;;
    *) fail "captain decision $id is neither actively held nor durably resolved" ;;
  esac
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_fields recorded_digest recorded_routes
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*'\nDecision digest: '*)
      resolution_fields=${hold_body#*'Decision digest: '}
      ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ -n "$recorded_routes" ] \
    || fail "captain hold $id has no routed identities"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

read_decision_file() {  # <path> -> decision text
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  printf '%s' "$decision"
}

route_evidence_file() {  # <hold-id>
  printf '%s/decision-hold-routes/%s.routes\n' "$DATA" "$1"
}

route_evidence_contains() {  # <hold-id> <task-id>
  local id=$1 dep=$2 routes path
  path=$(route_evidence_file "$id")
  [ -f "$path" ] || return 1
  routes=$(cat "$path") || return 1
  case ",$routes," in
    *",$dep,"*) return 0 ;;
    *) return 1 ;;
  esac
}

record_route_evidence() {  # <hold-id> <routed-csv>
  local id=$1 routes=$2 path existing
  path=$(route_evidence_file "$id")
  mkdir -p "${path%/*}" || fail "could not create route-evidence directory"
  if [ -f "$path" ]; then
    existing=$(cat "$path") || fail "could not read route evidence for $id"
    [ "$existing" = "$routes" ] || fail "hold $id records different routed evidence"
  else
    printf '%s\n' "$routes" > "$path" || fail "could not record route evidence for $id"
  fi
}

dependency_edge_present() {  # <deps> <hold-id>
  local deps=$1 id=$2
  deps=${deps#\"}
  deps=${deps%\"}
  case ",$deps," in
    *",blocked-by:$id,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Shared by attest and amend: a repair may only route a dependent when a
# pre-repair trace proves that this hold had been linked to it. The raw deps
# edge survives an external `tasks-axi done`; route evidence preserves links
# that resolve cleared after recording them.
route_dependents() {  # <hold-id> <hold-body> <routed-tasks> [reestablish]
  local id=$1 hold_body=$2 routed=$3 reestablish=${4:-0} dep show blocked deps state
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    deps=$(show_field "$show" deps | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        if [ "$reestablish" = 1 ]; then
          [ "$state" != "done" ] || fail "routed task $dep is already done"
          if dependency_edge_present "$deps" "$id"; then
            :
          elif route_evidence_contains "$id" "$dep"; then
            tasks_axi block "$dep" --by "$id" >/dev/null \
              || fail "could not re-establish the routed dependency to $dep"
          else
            fail "routed task $dep was not durably linked to $id before repair"
          fi
        else
          case "$hold_body" in
            *"- $dep"*) : ;;
            *) fail "routed task $dep is not durably blocked by $id" ;;
          esac
        fi
        ;;
    esac
  done
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    deps=$(show_field "$show" deps | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$deps," in
      *",blocked-by:$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
      *)
        case ",$blocked," in
          *",$id,"*)
            tasks_axi unblock "$dep" --by "$id" >/dev/null \
              || fail "could not route the recorded decision to $dep"
            ;;
        esac
        ;;
    esac
  done
}

parse_routed_args() {  # remaining CLI args already filtered to --routed-to values
  local raw=$1
  printf '%s\n' "$raw" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0 none_requested=0 none_fingerprint
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    none_requested=1
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  none_fingerprint=$(status_default_decision_fingerprint "$status_file")
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    key_is_covered "$keys" "$key" "$meta" "$status_file" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    [ "$none_requested" = 1 ] && mark_none_attested "$meta" "$none_fingerprint"
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open status_file
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  status_file="$STATE/$origin.status"
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    key_is_covered "$keys" "$key" "$meta" "$status_file" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    [ "$key" = default ] && ! list_has_key "$keys" "$key" && continue
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done
  record_route_evidence "$id" "$routed_csv"

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

# attest and amend repair a hold `resolve` can no longer reach: state done, kind
# captain, closed outside this script. Both require a real --decision-file and a
# one-line --note recording the evidence for the repair, and both write a body
# marker distinguishable from an ordinary resolve. An exact attest retry succeeds
# while changed evidence is refused; amend always overwrites.
command_attest() {
  local origin=${1:-} key=${2:-} decision_file='' note='' routed_raw='' id='' decision='' \
    decision_digest='' body='' routed='' routed_csv='' recorded_routed='' dep show state kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed_raw="${routed_raw}${routed_raw:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line note "$note"
  decision=$(read_decision_file "$decision_file")
  decision_digest=$(sha256_text "$decision")
  routed=$(parse_routed_args "$routed_raw")
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  hold_body=$(show_field "$show" body)
  [ "$state" = "done" ] || fail "captain hold $id is not closed; use resolve for an active decision"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  recorded_routed=$(resolution_routed_csv "$hold_body")
  [ -n "$routed" ] || routed=$(printf '%s\n' "$recorded_routed" | tr ',' ' ')
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold. (attested;"*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      verify_resolution_note "$id" "$hold_body" "Attestation note" "$note"
      printf 'attested: %s\n' "$id"
      return 0
      ;;
    *"Resolution recorded by fm-decision-hold."*)
      fail "captain hold $id already carries a resolution record; use amend to correct it" ;;
  esac
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  route_dependents "$id" "$hold_body" "$routed" 1
  record_route_evidence "$id" "$routed_csv"
  body=$(printf 'Resolution recorded by fm-decision-hold. (attested; hold closed outside fm-decision-hold prior to attest)\nDecision digest: %s\nRouted identities: %s\nAttestation note: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' \
    "$decision_digest" "$routed_csv" "$note" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the post-hoc attestation on $id"
  verify_hold_durable "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'attested: %s\n' "$id"
}

command_amend() {
  local origin=${1:-} key=${2:-} decision_file='' note='' routed_raw='' id='' decision='' \
    decision_digest='' body='' routed='' routed_csv='' recorded_routed='' dep show state kind hold_body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed_raw="${routed_raw}${routed_raw:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line note "$note"
  decision=$(read_decision_file "$decision_file")
  decision_digest=$(sha256_text "$decision")
  routed=$(parse_routed_args "$routed_raw")
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  hold_body=$(show_field "$show" body)
  [ "$state" = "done" ] || fail "captain hold $id is not closed; correct an active decision by re-running resolve"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  recorded_routed=$(resolution_routed_csv "$hold_body")
  [ -n "$routed" ] || routed=$(printf '%s\n' "$recorded_routed" | tr ',' ' ')
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  route_dependents "$id" "$hold_body" "$routed" 1
  record_route_evidence "$id" "$routed_csv"
  body=$(printf 'Resolution recorded by fm-decision-hold. (amended)\nDecision digest: %s\nRouted identities: %s\nAmendment note: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' \
    "$decision_digest" "$routed_csv" "$note" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the amended resolution on $id"
  verify_hold_durable "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'amended: %s\n' "$id"
}

# Retires a duplicate hold by pointing it at an already durable (actively held or
# resolved) authoritative hold, so two investigations surfacing the same question
# do not need two resolutions. Never closes a duplicate against a non-durable peer.
command_supersede() {
  local origin=${1:-} key=${2:-} dup_of='' note='' id='' auth_id='' body='' show state
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --duplicate-of) shift; dup_of=${1:-} ;;
      --note) shift; note=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_slug duplicate-of "$dup_of"
  validate_one_line note "$note"
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  auth_id=$dup_of
  [ "$auth_id" != "$id" ] || fail "captain hold $id cannot be a duplicate of itself"
  verify_hold_durable "$auth_id" "$id"
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  [ "$(show_field "$show" kind)" = captain ] || fail "backlog item $id is not kind captain"
  body=$(printf 'Superseded by fm-decision-hold.\nDuplicate of: %s\n\nNote:\n%s\n' "$auth_id" "$note")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the duplicate identity on $id"
  if [ "$state" != "done" ]; then
    tasks_axi "done" "$id" >/dev/null || fail "could not close superseded captain hold $id"
  fi
  verify_hold_durable "$id" || fail "captain hold $id did not retain its durable superseded record"
  printf 'superseded: %s -> %s\n' "$id" "$auth_id"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  attest) shift; command_attest "$@" ;;
  amend) shift; command_amend "$@" ;;
  supersede) shift; command_supersede "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
