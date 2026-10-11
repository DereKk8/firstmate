#!/usr/bin/env bash
# Firstmate mechanics for the shared zero-trust review.
# The review rules stay in DereKk8/project-skills
# shared/zero-trust-review/SKILL.md at the pinned identity below.
# This script does not restate those rules. It staffs from the diff size,
# writes the shared brief, launches the blind reviewer in a directory that
# is not a repository, checks the report shape, and refuses a merge unless
# the review recorded for that pull request URL is a PASS of the live head.
#
# The blind launch requires bwrap. It mounts the operating-system runtime
# the command needs (/usr, and /nix/store only when the command itself is
# there), a private home, and temporary directories. It does not mount the
# host root. Optional --auth directories contribute only regular files
# named auth.json, .credentials.json, or gemini-credentials.json. Other
# files in those directories are not mounted. An auth path inside a git
# checkout, or whose path contains gh, git, glab, projects, or treehouse,
# is refused. Without bwrap the launch refuses and does not start the
# command. prepare and launch both refuse a staff label weaker than the
# diff requires.
#
# A missing review record for the pull request URL does not change merge.
# The record is keyed by that URL, so a review stored from another task
# is the one the merge sees. record-report refuses a report whose
# "Repo / PR" line is not that same URL. A record whose verdict is not
# PASS, or whose head is not the live head, is a refusal.
#
# Usage:
#   fm-zt-review.sh identity
#   fm-zt-review.sh identity --check
#   fm-zt-review.sh show-skill
#   fm-zt-review.sh staff <diff-file>
#   fm-zt-review.sh staff-check <diff-file> <one|two|sliced>
#   fm-zt-review.sh brief --run-id ID --repo REPO --pr URL --head SHA \
#       --base BRANCH --merge-base SHA --diff FILE --intent-file FILE \
#       --surface TEXT --evidence TEXT
#   fm-zt-review.sh prepare --staff one|two|sliced --out DIR [same brief flags]
#   fm-zt-review.sh assert <dir>
#   fm-zt-review.sh launch <dir> --staff one|two|sliced --diff FILE \
#       [--auth DIR]... -- <command> [args]
#   fm-zt-review.sh record-report <task-id> <report-file> <pr-url>
#   fm-zt-review.sh check-merge <task-id> <pr-url> <live-head>
#
# identity --check and show-skill read the pinned commit from
# FM_ZT_SKILL_REPO, or from $FM_HOME/projects/project-skills.
# FM_ZT_PIN_OVERRIDE=1 with FM_ZT_VERSION, FM_ZT_COMMIT, and FM_ZT_BLOB
# substitutes the pin. Leave those unset for a real review.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

pin_version() {
  if [ "${FM_ZT_PIN_OVERRIDE:-}" = 1 ]; then
    [ -n "${FM_ZT_VERSION:-}" ] || die "FM_ZT_PIN_OVERRIDE=1 requires FM_ZT_VERSION"
    printf '%s\n' "$FM_ZT_VERSION"
    return 0
  fi
  printf '%s\n' '2.1.0'
}

pin_commit() {
  if [ "${FM_ZT_PIN_OVERRIDE:-}" = 1 ]; then
    [ -n "${FM_ZT_COMMIT:-}" ] || die "FM_ZT_PIN_OVERRIDE=1 requires FM_ZT_COMMIT"
    printf '%s\n' "$FM_ZT_COMMIT"
    return 0
  fi
  printf '%s\n' 'b0eae5769571e8a809dd1d5e10b1d76ea6837e70'
}

pin_blob() {
  if [ "${FM_ZT_PIN_OVERRIDE:-}" = 1 ]; then
    [ -n "${FM_ZT_BLOB:-}" ] || die "FM_ZT_PIN_OVERRIDE=1 requires FM_ZT_BLOB"
    printf '%s\n' "$FM_ZT_BLOB"
    return 0
  fi
  printf '%s\n' 'f08cd046fe592828e7ddf72d148dad548429410c'
}

identity_line() {
  printf 'Identity: zero-trust-review %s %s %s\n' "$(pin_version)" "$(pin_commit)" "$(pin_blob)"
}

hex40() {
  case "${1:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0
      ;;
  esac
  return 1
}

skill_repo() {
  local candidate
  if [ -n "${FM_ZT_SKILL_REPO:-}" ]; then
    candidate=$FM_ZT_SKILL_REPO
  else
    candidate=$FM_HOME/projects/project-skills
  fi
  git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "shared skill repo is not available at $candidate"
  printf '%s\n' "$candidate"
}

skill_bytes() {
  local repo commit blob got version
  repo=$(skill_repo)
  commit=$(pin_commit)
  blob=$(pin_blob)
  hex40 "$commit" || die "pinned skill commit is not 40 hex characters"
  hex40 "$blob" || die "pinned skill blob is not 40 hex characters"
  got=$(git -C "$repo" rev-parse "${commit}:shared/zero-trust-review/SKILL.md" 2>/dev/null) \
    || die "pinned skill commit $commit has no shared/zero-trust-review/SKILL.md in $repo"
  [ "$got" = "$blob" ] || die "pinned skill blob drift: commit $commit has $got, pin is $blob"
  version=$(git -C "$repo" show "${commit}:shared/zero-trust-review/SKILL.md" \
    | awk 'BEGIN { found = 0 } /^Skill version: / { print substr($0, 16); found = 1; exit } END { if (!found) exit 1 }') \
    || die "pinned skill has no Skill version line"
  [ "$version" = "$(pin_version)" ] || die "pinned skill version is $version, pin is $(pin_version)"
  git -C "$repo" show "${commit}:shared/zero-trust-review/SKILL.md"
}

inside_worktree() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Prints size=<known|unknown> and changed_lines=<n or empty> on stdout.
measure_diff() {
  local file=$1 mode
  [ -f "$file" ] && [ ! -L "$file" ] || die "diff is not a regular file: $file"
  mode=$(awk '
    BEGIN { nonempty = 0; unified = 0; bad_numstat = 0; numstat = 0 }
    {
      if ($0 ~ /^diff --git / || $0 ~ /^@@/) unified = 1
      if (length($0) == 0) next
      nonempty = 1
      if ($0 ~ /^[0-9-]+\t[0-9-]+\t/) numstat++
      else bad_numstat = 1
    }
    END {
      if (unified) { print "unified"; exit }
      if (nonempty == 0) { print "empty"; exit }
      if (numstat > 0 && bad_numstat == 0) { print "numstat"; exit }
      print "unknown"
    }
  ' "$file")
  case "$mode" in
    empty)
      printf 'size=known\nchanged_lines=0\n'
      ;;
    unknown)
      printf 'size=unknown\nchanged_lines=\n'
      ;;
    unified)
      awk '
        BEGIN { add = 0; del = 0; unknown = 0; hunks = 0; headers = 0 }
        /^diff --git / { headers++; next }
        /^@@/ { hunks++; next }
        /^Binary files / || /^GIT binary patch/ { unknown = 1 }
        /^\+\+\+ (b\/|"b\/|\/dev\/null)/ { next }
        /^--- (a\/|"a\/|\/dev\/null)/ { next }
        /^\+/ { add++ }
        /^-/ { del++ }
        END {
          if (unknown || (headers > 0 && hunks == 0)) {
            print "size=unknown"
            print "changed_lines="
            exit
          }
          print "size=known"
          print "changed_lines=" (add + del)
        }
      ' "$file"
      ;;
    numstat)
      awk -F '\t' '
        BEGIN { total = 0; unknown = 0 }
        NF >= 2 {
          if ($1 == "-" || $2 == "-") unknown = 1
          else total += $1 + $2
        }
        END {
          if (unknown) { print "size=unknown"; print "changed_lines="; exit }
          print "size=known"
          print "changed_lines=" total
        }
      ' "$file"
      ;;
    *)
      die "could not measure diff $file"
      ;;
  esac
}

required_staffing() {
  local size=$1 lines=$2
  if [ "$size" != known ]; then
    printf '%s\n' sliced
    return 0
  fi
  if [ "$lines" -lt 100 ]; then
    printf '%s\n' one
  elif [ "$lines" -le 800 ]; then
    printf '%s\n' two
  else
    printf '%s\n' sliced
  fi
}

staff_rank() {
  case "$1" in
    one) printf '1\n' ;;
    two) printf '2\n' ;;
    sliced) printf '3\n' ;;
    *) return 1 ;;
  esac
}

print_staff() {
  local file=$1 size lines staffing measure
  measure=$(measure_diff "$file")
  size=${measure#size=}
  size=${size%%$'\n'*}
  lines=${measure#*$'\n'changed_lines=}
  staffing=$(required_staffing "$size" "${lines:-0}")
  printf 'changed_lines=%s\nsize=%s\nstaffing=%s\n' "$lines" "$size" "$staffing"
}

require_staffing() {
  local file=$1 requested=$2 measure lines size need need_rank got_rank
  staff_rank "$requested" >/dev/null || die "staffing must be one, two, or sliced"
  measure=$(print_staff "$file")
  lines=$(printf '%s\n' "$measure" | awk -F= '$1 == "changed_lines" { print $2 }')
  size=$(printf '%s\n' "$measure" | awk -F= '$1 == "size" { print $2 }')
  need=$(printf '%s\n' "$measure" | awk -F= '$1 == "staffing" { print $2 }')
  need_rank=$(staff_rank "$need")
  got_rank=$(staff_rank "$requested")
  if [ "$got_rank" -lt "$need_rank" ]; then
    if [ "$size" = known ]; then
      die "staffing $requested is below the diff rule ($lines changed lines require $need)"
    fi
    die "staffing $requested is below the diff rule (unknown size requires $need)"
  fi
}

# The closing marker has to start a line. Add a newline only when the
# copied file does not already end with one.
finish_marker_line() {
  local file=$1 byte
  [ -s "$file" ] || return 0
  # Command substitution would strip a trailing newline, so read the byte
  # through od. 10 is the newline byte.
  byte=$(tail -c 1 -- "$file" | od -An -tu1)
  byte=${byte//[[:space:]]/}
  if [ "$byte" != 10 ]; then
    printf '\n'
  fi
}

unique_marker() {
  local prefix=$1 file=$2 marker n=0
  while [ "$n" -lt 8 ]; do
    marker=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
    marker="${prefix}${marker}"
    if ! grep -qxF "$marker" "$file"; then
      printf '%s\n' "$marker"
      return 0
    fi
    n=$((n + 1))
  done
  return 1
}

require_text_arg() {
  local name=$1 value=$2
  [ -n "$value" ] || die "missing $name"
  case "$value" in
    *$'\n'*) die "$name contains a newline" ;;
  esac
}

write_brief() {
  local run_id=$1 repo=$2 pr=$3 head=$4 base=$5 merge_base=$6 diff_file=$7 intent_file=$8 surface=$9 evidence=${10} dest=${11}
  local measure size lines diff_mark intent_mark
  require_text_arg --run-id "$run_id"
  require_text_arg --repo "$repo"
  require_text_arg --pr "$pr"
  require_text_arg --base "$base"
  require_text_arg --surface "$surface"
  require_text_arg --evidence "$evidence"
  hex40 "$head" || die "--head is not 40 hex characters"
  hex40 "$merge_base" || die "--merge-base is not 40 hex characters"
  [ -f "$intent_file" ] && [ ! -L "$intent_file" ] || die "intent is not a regular file: $intent_file"
  measure=$(measure_diff "$diff_file")
  size=${measure#size=}
  size=${size%%$'\n'*}
  lines=${measure#*$'\n'changed_lines=}
  diff_mark=$(unique_marker 'FMZTDIFF' "$diff_file") || die "could not mark the diff"
  intent_mark=$(unique_marker 'FMZTINTENT' "$intent_file") || die "could not mark the intent"
  {
    printf 'Skill identity: %s\n' "$(identity_line)"
    printf 'Run id: %s\n' "$run_id"
    printf 'Repo / PR: %s %s\n' "$repo" "$pr"
    printf 'Pinned head SHA: %s\n' "$head"
    printf 'Base branch and merge base: %s %s\n' "$base" "$merge_base"
    if [ "$size" = known ]; then
      printf 'Diff: %s changed lines\n' "$lines"
    else
      printf 'Diff: unknown size\n'
    fi
    printf '%s\n' "$diff_mark"
    cat -- "$diff_file"
    finish_marker_line "$diff_file"
    printf '%s\n' "$diff_mark"
    printf 'Stated intent:\n'
    printf '%s\n' "$intent_mark"
    cat -- "$intent_file"
    finish_marker_line "$intent_file"
    printf '%s\n' "$intent_mark"
    printf 'Product surface to drive: %s\n' "$surface"
    printf 'Evidence location: %s\n' "$evidence"
  } >"$dest"
}

assert_blind() {
  local dir=$1 resolved names blob
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "blind directory is not a real directory: $dir"
  resolved=$(CDPATH='' cd -- "$dir" && pwd -P)
  if inside_worktree "$resolved"; then
    die "blind directory is inside a git checkout: $resolved"
  fi
  names=$(find "$resolved" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  [ "$names" = $'brief.md\nskill.md' ] || die "blind directory must contain only brief.md and skill.md"
  [ -f "$resolved/brief.md" ] && [ ! -L "$resolved/brief.md" ] || die "brief.md is not a regular file"
  [ -f "$resolved/skill.md" ] && [ ! -L "$resolved/skill.md" ] || die "skill.md is not a regular file"
  blob=$(git hash-object "$resolved/skill.md")
  [ "$blob" = "$(pin_blob)" ] || die "skill.md blob is $blob, pin is $(pin_blob)"
  grep -qxF "Skill identity: $(identity_line)" "$resolved/brief.md" \
    || die "brief is missing the pinned skill identity"
}

cleanup_prepare() {
  if [ -n "${PREPARE_DIR:-}" ]; then
    rm -rf -- "$PREPARE_DIR"
  fi
  if [ -n "${PREPARE_BYTES:-}" ]; then
    rm -f -- "$PREPARE_BYTES"
  fi
}

cleanup_brief() {
  if [ -n "${BRIEF_TMP:-}" ]; then
    rm -f -- "$BRIEF_TMP"
  fi
}

auth_ok() {
  local path=$1 resolved home rel
  [ -d "$path" ] && [ ! -L "$path" ] || die "auth path is not a real directory: $path"
  resolved=$(CDPATH='' cd -- "$path" && pwd -P)
  home=$(CDPATH='' cd -- "$HOME" && pwd -P)
  case "$resolved" in
    "$home"/*) ;;
    *) die "auth path must be inside HOME: $resolved" ;;
  esac
  rel=${resolved#"$home"/}
  case "$rel" in
    *gh*|*git*|*glab*|*projects*|*treehouse*)
      die "auth path is not a model-auth directory: $rel"
      ;;
  esac
  if inside_worktree "$resolved"; then
    die "auth path is inside a git checkout: $resolved"
  fi
  printf '%s\n' "$rel"
}

# Reviewer harness credential files named by the harness references:
# auth.json (codex, grok, muse, pi), .credentials.json (claude), and
# gemini-credentials.json (gemini). Session history and other files are
# not credential files.
credential_basename_ok() {
  case "$1" in
    auth.json|.credentials.json|gemini-credentials.json) return 0 ;;
    *) return 1 ;;
  esac
}

launch_blind() {
  local dir=$1
  shift
  local -a auth_rels=() auth_roots=() cred_srcs=() cred_dests=() bwrap_cmd=()
  local -A made_dirs=()
  local rel root staff='' diff='' file_rel base found dest parent
  local cmd_real os_path target i j
  local -a chain=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auth)
        [ "$#" -ge 2 ] || die "launch --auth needs a directory"
        rel=$(auth_ok "$2")
        root=$(CDPATH='' cd -- "$2" && pwd -P)
        auth_rels+=("$rel")
        auth_roots+=("$root")
        shift 2
        ;;
      --staff)
        [ "$#" -ge 2 ] || die "launch --staff needs one|two|sliced"
        [ -z "$staff" ] || die "launch --staff was given twice"
        staff=$2
        shift 2
        ;;
      --diff)
        [ "$#" -ge 2 ] || die "launch --diff needs a file"
        [ -z "$diff" ] || die "launch --diff was given twice"
        diff=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        die "launch expected --auth, --staff, --diff, or -- before the command"
        ;;
    esac
  done
  [ -n "$staff" ] || die "launch needs --staff one|two|sliced"
  [ -n "$diff" ] || die "launch needs --diff"
  [ "$#" -ge 1 ] || die "launch needs a command after --"
  require_staffing "$diff" "$staff"
  i=0
  while [ "$i" -lt "${#auth_roots[@]}" ]; do
    found=0
    while IFS= read -r file_rel; do
      [ -n "$file_rel" ] || continue
      base=${file_rel##*/}
      credential_basename_ok "$base" || continue
      [ -f "${auth_roots[$i]}/$file_rel" ] && [ ! -L "${auth_roots[$i]}/$file_rel" ] || continue
      cred_srcs+=("${auth_roots[$i]}/$file_rel")
      cred_dests+=("/tmp/zt-home/${auth_rels[$i]}/$file_rel")
      found=1
    done < <(find "${auth_roots[$i]}" -type f -printf '%P\n')
    [ "$found" -eq 1 ] || die "auth directory has no reviewer credential file: ${auth_roots[$i]}"
    i=$((i + 1))
  done
  assert_blind "$dir"
  command -v bwrap >/dev/null 2>&1 || die "bwrap is required to launch a blind reviewer, and it is not on PATH"
  local resolved
  resolved=$(CDPATH='' cd -- "$dir" && pwd -P)
  [ -d /usr ] && [ ! -L /usr ] || die "launch needs a real /usr directory for the reviewer runtime"
  cmd_real=$1
  if [ "${cmd_real#/}" = "$cmd_real" ]; then
    cmd_real=$(command -v -- "$1" 2>/dev/null || true)
    [ -n "$cmd_real" ] || die "launch command was not found: $1"
  fi
  cmd_real=$(readlink -f -- "$cmd_real")
  bwrap_cmd=(
    bwrap
    --ro-bind /usr /usr
  )
  for os_path in /bin /lib /lib64; do
    if [ -d "$os_path" ] && [ ! -L "$os_path" ]; then
      bwrap_cmd+=(--ro-bind "$os_path" "$os_path")
    elif [ -L "$os_path" ]; then
      target=$(readlink -- "$os_path")
      bwrap_cmd+=(--symlink "$target" "$os_path")
    fi
  done
  if [ -d /etc ] && [ ! -L /etc ]; then
    bwrap_cmd+=(--ro-bind /etc /etc)
  fi
  case "$cmd_real" in
    /nix/store/*)
      [ -d /nix/store ] && [ ! -L /nix/store ] || die "launch command is in /nix/store, and that directory is not real"
      bwrap_cmd+=(--ro-bind /nix/store /nix/store)
      bwrap_cmd+=(--setenv PATH "$(dirname -- "$cmd_real"):${PATH}")
      ;;
  esac
  bwrap_cmd+=(
    --dev /dev
    --proc /proc
    --tmpfs /home
    --tmpfs /tmp
    --tmpfs /var/tmp
    --dir /tmp/zt-home
    --bind "$resolved" /tmp/zt-work
    --chdir /tmp/zt-work
    --setenv HOME /tmp/zt-home
    --setenv GIT_DIR /fm-zt-no-repository
    --unsetenv GH_TOKEN
    --unsetenv GITHUB_TOKEN
    --unsetenv GH_ENTERPRISE_TOKEN
    --unsetenv GITLAB_TOKEN
    --unsetenv GL_TOKEN
  )
  made_dirs[/tmp/zt-home]=1
  i=0
  while [ "$i" -lt "${#cred_dests[@]}" ]; do
    dest=${cred_dests[$i]}
    chain=()
    parent=$(dirname -- "$dest")
    while [ "$parent" != /tmp/zt-home ] && [ "$parent" != / ]; do
      chain+=("$parent")
      parent=$(dirname -- "$parent")
    done
    j=${#chain[@]}
    while [ "$j" -gt 0 ]; do
      j=$((j - 1))
      if [ -z "${made_dirs[${chain[$j]}]+x}" ]; then
        bwrap_cmd+=(--dir "${chain[$j]}")
        made_dirs[${chain[$j]}]=1
      fi
    done
    bwrap_cmd+=(--ro-bind "${cred_srcs[$i]}" "$dest")
    i=$((i + 1))
  done
  bwrap_cmd+=("$@")
  "${bwrap_cmd[@]}"
}

parse_brief_opts() {
  RUN_ID='' REPO='' PR_URL='' HEAD_SHA='' BASE_BRANCH='' MERGE_BASE=''
  DIFF_FILE='' INTENT_FILE='' SURFACE='' EVIDENCE='' OUT_DIR='' STAFF=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id|--repo|--pr|--head|--base|--merge-base|--diff|--intent-file|--surface|--evidence|--out|--staff)
        [ "$#" -ge 2 ] || die "missing value for $1"
        case "$1" in
          --run-id) RUN_ID=$2 ;;
          --repo) REPO=$2 ;;
          --pr) PR_URL=$2 ;;
          --head) HEAD_SHA=$2 ;;
          --base) BASE_BRANCH=$2 ;;
          --merge-base) MERGE_BASE=$2 ;;
          --diff) DIFF_FILE=$2 ;;
          --intent-file) INTENT_FILE=$2 ;;
          --surface) SURFACE=$2 ;;
          --evidence) EVIDENCE=$2 ;;
          --out) OUT_DIR=$2 ;;
          --staff) STAFF=$2 ;;
        esac
        shift 2
        ;;
      *) die "unknown brief option $1" ;;
    esac
  done
}

report_ok() {
  local report=$1 identity head
  [ -f "$report" ] && [ ! -L "$report" ] || die "report is not a regular file: $report"
  identity=$(identity_line)
  head=$(awk -v identity="$identity" '
    NR == 1 { if ($0 != identity) { bad = "identity"; exit } next }
    $0 == "## Pinned head" { if (stage != 0) { bad = "order"; exit } stage = 1; next }
    stage == 1 && $0 ~ /^Final tested head: [0-9a-f]{40}$/ {
      if (tested != "") { bad = "order"; exit }
      tested = substr($0, 20)
      next
    }
    $0 == "## Setup" { if (stage != 1 || tested == "") { bad = "order"; exit } stage = 2; seen = 0; next }
    $0 == "## Blind-review suspicions" { if (stage != 2 || seen == 0) { bad = "order"; exit } stage = 3; seen = 0; next }
    $0 == "## Product-surface run" { if (stage != 3 || seen == 0) { bad = "order"; exit } stage = 4; seen = 0; next }
    $0 == "## Attack phase" { if (stage != 4 || seen == 0) { bad = "order"; exit } stage = 5; seen = 0; next }
    $0 == "## Findings" { if (stage != 5 || seen == 0) { bad = "order"; exit } stage = 6; seen = 0; next }
    $0 == "## Verdict" { if (stage != 6 || seen == 0) { bad = "order"; exit } stage = 7; seen = 0; next }
    $0 == "## Decisions for the engineering lead" { if (stage != 7 || seen != 1) { bad = "verdict"; exit } stage = 8; seen = 0; next }
    $0 == "## Evidence location" { if (stage != 8 || seen == 0) { bad = "order"; exit } stage = 9; seen = 0; next }
    $0 ~ /^Repo \/ PR: / {
      if (seen_pr == 1) { bad = "pr"; exit }
      seen_pr = 1
      repo_pr = substr($0, 12)
    }
    stage == 7 {
      if ($0 == "") next
      if ($0 ~ /^Repo \/ PR: /) next
      if (seen == 1) { bad = "verdict"; exit }
      if ($0 != "PASS" && $0 != "PRODUCT_FAIL" && $0 != "INFRA_FAIL" && $0 != "FLAKY" && $0 != "BLOCKED" && $0 != "ENVIRONMENT_NOT_READY" && $0 != "INCOMPLETE") { bad = "verdict"; exit }
      seen = 1
      verdict = $0
      next
    }
    stage > 0 && stage != 7 && $0 != "" && $0 !~ /^Repo \/ PR: / { seen = 1 }
    END {
      if (bad != "") { print "bad " bad; exit }
      if (seen_pr != 1) { print "bad pr"; exit }
      if (stage != 9 || seen == 0 || tested == "") { print "bad order"; exit }
      print tested
      print verdict
      print repo_pr
    }
  ' "$report") || die "could not read report $report"
  case "$head" in
    bad\ *) die "report shape refused (${head#bad })" ;;
  esac
  printf '%s\n' "$head"
}

review_record_path() {
  local url=$1 sum
  sum=$(printf '%s' "$url" | sha256sum)
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || die "could not name the review record"
  case "$sum" in
    *[!0-9a-f]*) die "could not name the review record" ;;
  esac
  printf '%s\n' "$STATE/zt-pr-$sum.zt-verified"
}

write_record() {
  local path=$1 pr=$2 head=$3 verdict=$4 tmp
  mkdir -p -- "$STATE"
  tmp=$path.tmp.$$
  printf 'pr=%s\nhead=%s\nverdict=%s\n' "$pr" "$head" "$verdict" >"$tmp"
  mv -f -- "$tmp" "$path"
}

read_record() {
  local path=$1 pr='' head='' verdict='' line key value
  [ -f "$path" ] && [ ! -L "$path" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      pr)
        [ -z "$pr" ] || return 1
        pr=$value
        ;;
      head)
        [ -z "$head" ] || return 1
        head=$value
        ;;
      verdict)
        [ -z "$verdict" ] || return 1
        verdict=$value
        ;;
      *)
        return 1
        ;;
    esac
  done <"$path"
  [ -n "$pr" ] && hex40 "$head" || return 1
  case "$verdict" in
    PASS|PRODUCT_FAIL|INFRA_FAIL|FLAKY|BLOCKED|ENVIRONMENT_NOT_READY|INCOMPLETE) ;;
    *) return 1 ;;
  esac
  printf '%s\n%s\n%s\n' "$pr" "$head" "$verdict"
}

cmd=${1:-}
[ -n "$cmd" ] || die "missing command"
shift || true

case "$cmd" in
  identity)
    if [ "${1:-}" = --check ]; then
      skill_bytes >/dev/null
    elif [ -n "${1:-}" ]; then
      die "unknown identity option ${1}"
    fi
    identity_line
    ;;
  show-skill)
    skill_bytes
    ;;
  staff)
    [ "$#" -eq 1 ] || die "staff needs one diff file"
    print_staff "$1"
    ;;
  staff-check)
    [ "$#" -eq 2 ] || die "staff-check needs a diff file and one|two|sliced"
    require_staffing "$1" "$2"
    print_staff "$1"
    ;;
  brief)
    parse_brief_opts "$@"
    [ -z "$OUT_DIR" ] || die "brief does not take --out"
    [ -z "$STAFF" ] || die "brief does not take --staff"
    BRIEF_TMP=
    trap cleanup_brief EXIT
    BRIEF_TMP=$(mktemp)
    write_brief "$RUN_ID" "$REPO" "$PR_URL" "$HEAD_SHA" "$BASE_BRANCH" "$MERGE_BASE" \
      "$DIFF_FILE" "$INTENT_FILE" "$SURFACE" "$EVIDENCE" "$BRIEF_TMP"
    cat -- "$BRIEF_TMP"
    rm -f -- "$BRIEF_TMP"
    BRIEF_TMP=
    trap - EXIT
    ;;
  prepare)
    parse_brief_opts "$@"
    [ -n "$OUT_DIR" ] || die "prepare needs --out"
    [ -n "$STAFF" ] || die "prepare needs --staff one|two|sliced"
    require_staffing "$DIFF_FILE" "$STAFF"
    [ ! -e "$OUT_DIR" ] || die "prepare refuses an existing path: $OUT_DIR"
    parent=$(dirname -- "$OUT_DIR")
    [ -d "$parent" ] || die "prepare parent is not a directory: $parent"
    parent=$(CDPATH='' cd -- "$parent" && pwd -P)
    if inside_worktree "$parent"; then
      die "refusing to build a blind review directory inside a git checkout: $parent"
    fi
    PREPARE_BYTES=
    PREPARE_DIR=
    trap cleanup_prepare EXIT
    PREPARE_BYTES=$(mktemp)
    skill_bytes >"$PREPARE_BYTES"
    mkdir -- "$OUT_DIR"
    PREPARE_DIR=$OUT_DIR
    write_brief "$RUN_ID" "$REPO" "$PR_URL" "$HEAD_SHA" "$BASE_BRANCH" "$MERGE_BASE" \
      "$DIFF_FILE" "$INTENT_FILE" "$SURFACE" "$EVIDENCE" "$OUT_DIR/brief.md"
    mv -- "$PREPARE_BYTES" "$OUT_DIR/skill.md"
    PREPARE_BYTES=
    assert_blind "$OUT_DIR"
    PREPARE_DIR=
    trap - EXIT
    measure=$(print_staff "$DIFF_FILE")
    printf 'directory=%s\n%s\n' "$(CDPATH='' cd -- "$OUT_DIR" && pwd -P)" "$measure"
    ;;
  assert)
    [ "$#" -eq 1 ] || die "assert needs one directory"
    assert_blind "$1"
    printf 'ok\n'
    ;;
  launch)
    [ "$#" -ge 1 ] || die "launch needs a directory"
    dir=$1
    shift
    launch_blind "$dir" "$@"
    ;;
  record-report)
    [ "$#" -eq 3 ] || die "record-report needs a task id, a report file, and a pull request URL"
    fm_pr_task_id_valid "$1" || die "invalid task id"
    require_text_arg "pr-url" "$3"
    parsed=$(report_ok "$2")
    tested=$(printf '%s\n' "$parsed" | awk 'NR == 1 { print; exit }')
    verdict=$(printf '%s\n' "$parsed" | awk 'NR == 2 { print; exit }')
    report_pr=$(printf '%s\n' "$parsed" | awk 'NR == 3 { print; exit }')
    [ "$report_pr" = "$3" ] || die "report Repo / PR is $report_pr, not $3"
    path=$(review_record_path "$3")
    write_record "$path" "$3" "$tested" "$verdict"
    printf 'recorded=%s\nhead=%s\nverdict=%s\n' "$path" "$tested" "$verdict"
    ;;
  check-merge)
    [ "$#" -eq 3 ] || die "check-merge needs a task id, a pull request URL, and a live head"
    fm_pr_task_id_valid "$1" || die "invalid task id"
    require_text_arg "pr-url" "$2"
    hex40 "$3" || die "live head is not 40 hex characters"
    path=$(review_record_path "$2")
    if [ ! -e "$path" ]; then
      printf 'no-review\n'
      exit 0
    fi
    if ! parsed=$(read_record "$path"); then
      die "review record $path is unreadable, so the merge is refused"
    fi
    recorded_pr=$(printf '%s\n' "$parsed" | awk 'NR == 1 { print; exit }')
    recorded_head=$(printf '%s\n' "$parsed" | awk 'NR == 2 { print; exit }')
    recorded_verdict=$(printf '%s\n' "$parsed" | awk 'NR == 3 { print; exit }')
    if [ "$recorded_pr" != "$2" ]; then
      die "review record $path does not match $2, so the merge is refused"
    fi
    if [ "$recorded_verdict" != PASS ]; then
      die "refusing to merge $2 because the review verdict is $recorded_verdict, not PASS"
    fi
    if [ "$recorded_head" != "$3" ]; then
      die "refusing to merge $2 because the live head $3 is not the reviewed head $recorded_head"
    fi
    printf 'reviewed-head=%s\n' "$recorded_head"
    ;;
  *)
    die "unknown command $cmd"
    ;;
esac
