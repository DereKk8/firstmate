#!/usr/bin/env bash
# fm-migrate-endpoint-binding.sh - repairs task metadata records that predate
# the endpoint_task_id binding bin/fm-backend.sh's
# fm_backend_validate_task_endpoint now requires for herdr, zellij, orca, and
# cmux endpoints.
#
# A missing binding on those backends makes fm_backend_validate_task_endpoint
# refuse to act on the record at all, because an opaque runtime pane or
# terminal id carries no proof by itself that it still belongs to the
# recorded task. This migration supplies that proof from the LIVE endpoint
# before writing endpoint_task_id, never from the record being repaired, and
# refuses per task rather than guessing when no reliable live evidence
# exists. It never relaxes, bypasses, or works around that refusal.
#
# Proof sources, by backend:
#   herdr - `pane get` on the recorded pane. Its foreground_cwd (the live
#           foreground process's cwd, not the frozen creation-time cwd - see
#           bin/backends/herdr.sh's fm_backend_herdr_current_path) must equal
#           the task's recorded worktree= path exactly, and the pane's own
#           echoed workspace_id/tab_id must equal the recorded
#           herdr_workspace_id/herdr_tab_id. Passive: no text is sent to the
#           pane.
#   orca  - `orca worktree show` on the recorded orca_worktree_id. Its
#           returned worktree path must equal the task's recorded worktree=
#           path exactly. Structural (Orca's own worktree record), not a
#           process-cwd probe.
#   zellij, cmux - REFUSED unconditionally. Neither CLI exposes a live
#           per-pane cwd passively: their list-panes cwd field is frozen at
#           tab-creation time, which is the shared project checkout rather
#           than the isolated worktree the task later moves into, so it
#           cannot discriminate one sibling task's pane from another's even
#           when it happens to be readable (see fm_backend_zellij_current_path
#           and fm_backend_cmux_current_path). The only live-cwd read either
#           adapter offers types a probe command into the pane, which this
#           migration will not do unattended against a possibly-busy worker.
#   tmux  - never touched; a tmux endpoint proves ownership by construction
#           (the window name itself) and never carries endpoint_task_id.
#
# Every record is repaired independently and atomically (write a sibling temp
# file, then rename over the original), so a run that repairs some tasks and
# refuses others leaves a consistent state, and a task that already carries
# its own exact endpoint_task_id is left untouched and reported unchanged on
# a second run.
#
# Usage: fm-migrate-endpoint-binding.sh [--apply]
#   (no flags) - report-only: prints what would be repaired and what would be
#                refused, writes nothing.
#   --apply    - write endpoint_task_id into every task whose ownership this
#                run can prove; still refuses and leaves untouched any task it
#                cannot prove.
# Exit status: 0 when every non-tmux, non-already-migrated record was
# repaired; 1 when at least one task was refused and needs manual attention.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  *) echo "error: invalid migration request" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "error: invalid migration request" >&2; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

REPAIRED=0
REFUSED=0
ALREADY=0
UNAFFECTED=0

# fm_migrate_endpoint_prove_herdr: prints nothing and returns 0 when the
# recorded herdr pane's live foreground_cwd, workspace_id, and tab_id all
# match <meta>'s recorded fields; otherwise prints one reason and returns 1.
fm_migrate_endpoint_prove_herdr() {  # <meta> <id>
  local meta=$1 id=$2 worktree session pane workspace tab info fields cwd got_ws got_tab
  worktree=$(fm_meta_get "$meta" worktree)
  session=$(fm_meta_get "$meta" herdr_session)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  if [ -z "$worktree" ] || [ -z "$session" ] || [ -z "$pane" ] || [ -z "$workspace" ] || [ -z "$tab" ]; then
    printf 'missing a required herdr field (worktree/herdr_session/herdr_pane_id/herdr_workspace_id/herdr_tab_id) to prove ownership from'
    return 1
  fi
  fm_backend_source herdr || { printf 'could not load the herdr adapter'; return 1; }
  fm_backend_herdr_tool_check >/dev/null 2>&1 || { printf 'the herdr CLI is not available to prove ownership'; return 1; }
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || {
    printf 'herdr pane %s did not resolve (dead, unreachable, or the session is not running)' "$pane"
    return 1
  }
  fields=$(printf '%s' "$info" | jq -r --arg p "$pane" '
    if (.result.pane.pane_id // "") == $p then
      [(.result.pane.foreground_cwd // "-"), (.result.pane.workspace_id // "-"), (.result.pane.tab_id // "-")] | @tsv
    else "" end' 2>/dev/null)
  if [ -z "$fields" ]; then
    printf 'herdr pane get for %s did not echo back the exact pane id (ambiguous or malformed response)' "$pane"
    return 1
  fi
  IFS=$'\t' read -r cwd got_ws got_tab <<<"$fields"
  [ "$cwd" = '-' ] && cwd=
  [ "$got_ws" = '-' ] && got_ws=
  [ "$got_tab" = '-' ] && got_tab=
  if [ "$cwd" != "$worktree" ]; then
    printf 'live herdr pane cwd (%s) does not match the recorded worktree (%s)' "${cwd:-<empty>}" "$worktree"
    return 1
  fi
  if [ "$got_ws" != "$workspace" ] || [ "$got_tab" != "$tab" ]; then
    printf 'live herdr pane workspace/tab (%s/%s) does not match recorded herdr_workspace_id/herdr_tab_id (%s/%s)' \
      "${got_ws:-<empty>}" "${got_tab:-<empty>}" "$workspace" "$tab"
    return 1
  fi
  return 0
}

# fm_migrate_endpoint_prove_orca: prints nothing and returns 0 when the
# recorded orca_worktree_id's live worktree path matches <meta>'s recorded
# worktree; otherwise prints one reason and returns 1.
fm_migrate_endpoint_prove_orca() {  # <meta> <id>
  local meta=$1 id=$2 worktree wt_id path
  worktree=$(fm_meta_get "$meta" worktree)
  wt_id=$(fm_meta_get "$meta" orca_worktree_id)
  if [ -z "$worktree" ] || [ -z "$wt_id" ]; then
    printf 'missing a required orca field (worktree/orca_worktree_id) to prove ownership from'
    return 1
  fi
  fm_backend_source orca || { printf 'could not load the orca adapter'; return 1; }
  fm_backend_orca_tool_check >/dev/null 2>&1 || { printf 'the orca CLI is not available to prove ownership'; return 1; }
  path=$(fm_backend_orca_worktree_path "$wt_id" 2>/dev/null) || {
    printf 'orca worktree %s did not resolve (removed, unreachable, or the id no longer exists)' "$wt_id"
    return 1
  }
  if [ "$path" != "$worktree" ]; then
    printf 'live orca worktree path (%s) does not match the recorded worktree (%s)' "$path" "$worktree"
    return 1
  fi
  return 0
}

# fm_migrate_endpoint_write: atomically append endpoint_task_id=<id> to
# <meta>, preserving every existing line and the file's own permission bits.
fm_migrate_endpoint_write() {  # <meta> <id>
  local meta=$1 id=$2 tmp="$1.migrate-tmp.$$"
  { cat "$meta" && printf 'endpoint_task_id=%s\n' "$id"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$meta" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$meta"
}

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSE  ${meta##*/}  meta path is missing, not a regular file, or a symlink" >&2
    REFUSED=$((REFUSED + 1))
    continue
  }
  id=${meta##*/}
  id=${id%.meta}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      echo "REFUSE  $id  task id derived from the meta filename is not a safe identifier" >&2
      REFUSED=$((REFUSED + 1))
      continue
      ;;
  esac

  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = tmux ]; then
    UNAFFECTED=$((UNAFFECTED + 1))
    continue
  fi

  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) : ;;
    1)
      binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || binding=
      if [ -n "$binding" ] && [ "$binding" = "$id" ]; then
        ALREADY=$((ALREADY + 1))
      else
        echo "REFUSE  $id  ($backend)  an existing endpoint_task_id is empty or names a different task; not a legacy-missing-binding case" >&2
        REFUSED=$((REFUSED + 1))
      fi
      continue
      ;;
    *)
      echo "REFUSE  $id  ($backend)  meta already carries more than one endpoint_task_id line" >&2
      REFUSED=$((REFUSED + 1))
      continue
      ;;
  esac

  reason=
  case "$backend" in
    herdr) reason=$(fm_migrate_endpoint_prove_herdr "$meta" "$id") && proven=1 || proven=0 ;;
    orca) reason=$(fm_migrate_endpoint_prove_orca "$meta" "$id") && proven=1 || proven=0 ;;
    zellij|cmux)
      proven=0
      reason="$backend exposes no passive, per-task-discriminating live evidence; requires manual verification"
      ;;
    *)
      proven=0
      reason="unrecognized backend '$backend'; not handled by this migration"
      ;;
  esac

  if [ "$proven" -eq 1 ]; then
    if [ "$APPLY" -eq 1 ]; then
      if fm_migrate_endpoint_write "$meta" "$id"; then
        echo "REPAIR  $id  ($backend)  live endpoint confirmed; endpoint_task_id written"
        REPAIRED=$((REPAIRED + 1))
      else
        echo "REFUSE  $id  ($backend)  ownership was proven but the meta file could not be written" >&2
        REFUSED=$((REFUSED + 1))
      fi
    else
      echo "REPAIR  $id  ($backend)  live endpoint confirmed; would write endpoint_task_id (dry run)"
      REPAIRED=$((REPAIRED + 1))
    fi
  else
    echo "REFUSE  $id  ($backend)  $reason" >&2
    REFUSED=$((REFUSED + 1))
  fi
done

if [ "$APPLY" -eq 1 ]; then
  echo "endpoint binding migration: $REPAIRED repaired, $REFUSED refused, $ALREADY already migrated, $UNAFFECTED unaffected (tmux)"
else
  echo "endpoint binding migration (dry run): $REPAIRED would be repaired, $REFUSED refused, $ALREADY already migrated, $UNAFFECTED unaffected (tmux)"
fi

[ "$REFUSED" -eq 0 ]
