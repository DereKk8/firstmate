#!/usr/bin/env bash
# Firstmate mechanics for the shared zero-trust review.
# The review rules stay in DereKk8/project-skills
# shared/zero-trust-review/SKILL.md at the pinned identity below.
# This script does not restate those rules. It counts the pinned diff,
# prints the staffing that count calls for, writes the shared brief,
# launches the blind reviewer in a directory that is not a repository,
# checks the report shape, keeps each pull request's verdict history, and
# refuses a merge when the latest review recorded for that pull request URL
# is not a PASS of the live head.
#
# The diff and its size come from git on the pinned commits: --source names
# a local repository that has both the merge base and the head. git's own
# --numstat gives the count, and a binary file makes the size unknown.
# staff prints agents=1|2 and slices=yes|no from the shared table. It does
# not enforce them: the coordinator assigns the roles and the slices.
#
# The blind launch checks the directory with the blind-directory checks
# (a real directory outside any git checkout that holds only brief.md and
# skill.md), then runs the command with that directory as its working
# directory and without the common forge tokens. It is not a sandbox: the
# command keeps the caller's filesystem access.
#
# identity --check also refuses a pin that is not the newest commit on the
# skill clone's origin/master that changed the skill file, which is the
# source commit /sync-zero-trust names. It reads origin/master as last
# fetched and never fetches.
#
# record-report appends one entry (head, verdict, scope, UTC date, Floor
# IDs) to the append-only review history for the pull request URL; --scope
# says whether the report covers the full change or only a delta, and carry
# writes scope=carried. history prints that
# history in order. A history from another task is the one the merge sees,
# because the record is keyed by the URL, and record-report refuses a report
# whose "Repo / PR" line is not that same URL. check-merge reads the latest
# entry: a verdict that is not PASS, or a head that is not the live head, is
# a refusal. A single-record file left by an earlier version is read only
# while no history exists. A missing review does not change merge, unless
# the home has the config/zero-trust-required presence flag, which refuses
# a merge that has no review recorded.
#
# Usage:
#   fm-zt-review.sh identity
#   fm-zt-review.sh identity --check
#   fm-zt-review.sh show-skill
#   fm-zt-review.sh staff <source-dir> <merge-base> <head>
#   fm-zt-review.sh brief --run-id ID --repo REPO --pr URL --head SHA \
#       --base BRANCH --merge-base SHA --source DIR --intent-file FILE \
#       --surface TEXT --evidence TEXT
#   fm-zt-review.sh prepare --out DIR [same brief flags] [--rescope FILE]
#   fm-zt-review.sh assert <dir>
#   fm-zt-review.sh launch <dir> -- <command> [args]
#   fm-zt-review.sh record-report <task-id> <report-file> <pr-url> --scope full|delta
#   fm-zt-review.sh history <pr-url>
#   fm-zt-review.sh recheck-gate <pr-url> <source-dir> <head> [--rescope FILE]
#   fm-zt-review.sh carry <task-id> <pr-url> <source-dir> <base-ref> <new-head>
#   fm-zt-review.sh check-merge <task-id> <pr-url> <live-head>
#
# identity --check and show-skill read the pinned commit from
# FM_ZT_SKILL_REPO, or from $FM_HOME/projects/project-skills.
# FM_ZT_PIN_OVERRIDE=1 with FM_ZT_VERSION, FM_ZT_COMMIT, and FM_ZT_BLOB
# substitutes the pin. Leave those unset for a real review.
# The config directory is FM_CONFIG_OVERRIDE, or $FM_HOME/config.
#
# prepare runs recheck-gate before it writes anything. For a pull request
# with a PRODUCT_FAIL that no PASS followed, the gate refuses a third fix round
# without the owner's re-scope decision (ZT-LOOP-6), and refuses a fixed head
# that is not built on the tested head or whose commits name, in ZT-Fixes
# trailers, IDs other than that failed report's Floor IDs (ZT-LOOP-7). carry
# records a PASS for a head whose change, read without context lines, equals
# the passed head's (ZT-LOOP-4).
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
  printf '%s\n' '6.0.0'
}

pin_commit() {
  if [ "${FM_ZT_PIN_OVERRIDE:-}" = 1 ]; then
    [ -n "${FM_ZT_COMMIT:-}" ] || die "FM_ZT_PIN_OVERRIDE=1 requires FM_ZT_COMMIT"
    printf '%s\n' "$FM_ZT_COMMIT"
    return 0
  fi
  printf '%s\n' '948a446a568c2f5353c88a74c1a44fc73cb40244'
}

pin_blob() {
  if [ "${FM_ZT_PIN_OVERRIDE:-}" = 1 ]; then
    [ -n "${FM_ZT_BLOB:-}" ] || die "FM_ZT_PIN_OVERRIDE=1 requires FM_ZT_BLOB"
    printf '%s\n' "$FM_ZT_BLOB"
    return 0
  fi
  printf '%s\n' 'e2e0757666dc1072dce4e7fb4580d2c3b0900106'
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
    | awk '!found && /^Skill version: / { print substr($0, 16); found = 1 } END { if (!found) exit 1 }') \
    || die "pinned skill has no Skill version line"
  [ "$version" = "$(pin_version)" ] || die "pinned skill version is $version, pin is $(pin_version)"
  git -C "$repo" show "${commit}:shared/zero-trust-review/SKILL.md"
}

# The pin must be the source commit /sync-zero-trust names: the newest commit
# on master that changed the skill file. This reads the clone's origin/master
# as last fetched, so a clone that was never refreshed cannot see a newer one.
require_newest_pin() {
  local repo commit newest newest_version
  repo=$(skill_repo)
  commit=$(pin_commit)
  newest=$(git -C "$repo" log -1 --format=%H refs/remotes/origin/master -- shared/zero-trust-review/SKILL.md 2>/dev/null) \
    || die "could not read origin/master in $repo"
  [ -n "$newest" ] || die "origin/master in $repo has no commit that changed shared/zero-trust-review/SKILL.md"
  [ "$newest" = "$commit" ] && return 0
  # awk reads to the end, because an early exit would end git with SIGPIPE
  # and pipefail would discard the version it printed.
  newest_version=$(git -C "$repo" show "${newest}:shared/zero-trust-review/SKILL.md" 2>/dev/null \
    | awk '!found && /^Skill version: / { print substr($0, 16); found = 1 }') || newest_version=
  die "pinned skill $(pin_version) at $commit is not the newest master change $newest (version ${newest_version:-unknown}); re-pin this script"
}

inside_worktree() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Prints size=<known|unknown> and changed_lines=<n or empty> on stdout,
# from git --numstat on the pinned commits. A binary file has no line
# count, so it makes the size unknown.
measure_diff() {
  local src=$1 merge_base=$2 head=$3 numstat
  hex40 "$merge_base" || die "merge base is not 40 hex characters"
  hex40 "$head" || die "head is not 40 hex characters"
  numstat=$(git -C "$src" diff --numstat --no-ext-diff --no-textconv "$merge_base" "$head") \
    || die "could not diff $merge_base to $head in $src"
  printf '%s\n' "$numstat" | awk -F '\t' '
    BEGIN { total = 0; unknown = 0 }
    NF >= 3 {
      if ($1 == "-" || $2 == "-") unknown = 1
      else total += $1 + $2
    }
    END {
      if (unknown) { print "size=unknown"; print "changed_lines="; exit }
      print "size=known"
      print "changed_lines=" total
    }
  '
}

# The shared staffing table: under 100 lines one agent, 100 to 800 two
# agents, and over 800 or an unknown size two agents with module slices.
print_staff() {
  local measure size lines agents=2 slices=no
  measure=$(measure_diff "$1" "$2" "$3")
  size=${measure#size=}
  size=${size%%$'\n'*}
  lines=${measure#*$'\n'changed_lines=}
  if [ "$size" != known ] || [ "$lines" -gt 800 ]; then
    slices=yes
  elif [ "$lines" -lt 100 ]; then
    agents=1
  fi
  printf 'changed_lines=%s\nsize=%s\nagents=%s\nslices=%s\n' "$lines" "$size" "$agents" "$slices"
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
  local run_id=$1 repo=$2 pr=$3 head=$4 base=$5 merge_base=$6 src=$7 intent_file=$8 surface=$9 evidence=${10} dest=${11}
  local measure size lines diff_mark intent_mark
  require_text_arg --run-id "$run_id"
  require_text_arg --repo "$repo"
  require_text_arg --pr "$pr"
  require_text_arg --base "$base"
  require_text_arg --source "$src"
  require_text_arg --surface "$surface"
  require_text_arg --evidence "$evidence"
  hex40 "$head" || die "--head is not 40 hex characters"
  hex40 "$merge_base" || die "--merge-base is not 40 hex characters"
  [ -f "$intent_file" ] && [ ! -L "$intent_file" ] || die "intent is not a regular file: $intent_file"
  measure=$(measure_diff "$src" "$merge_base" "$head")
  size=${measure#size=}
  size=${size%%$'\n'*}
  lines=${measure#*$'\n'changed_lines=}
  DIFF_TMP=$(mktemp)
  git -C "$src" diff --no-ext-diff --no-textconv --no-color "$merge_base" "$head" >"$DIFF_TMP" \
    || die "could not diff $merge_base to $head in $src"
  diff_mark=$(unique_marker 'FMZTDIFF' "$DIFF_TMP") || die "could not mark the diff"
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
    cat -- "$DIFF_TMP"
    finish_marker_line "$DIFF_TMP"
    printf '%s\n' "$diff_mark"
    printf 'Stated intent:\n'
    printf '%s\n' "$intent_mark"
    cat -- "$intent_file"
    finish_marker_line "$intent_file"
    printf '%s\n' "$intent_mark"
    printf 'Product surface to drive: %s\n' "$surface"
    printf 'Evidence location: %s\n' "$evidence"
  } >"$dest"
  rm -f -- "$DIFF_TMP"
  DIFF_TMP=
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

cleanup() {
  if [ -n "${PREPARE_DIR:-}" ]; then
    rm -rf -- "$PREPARE_DIR"
  fi
  local tmp
  for tmp in "${PREPARE_BYTES:-}" "${BRIEF_TMP:-}" "${DIFF_TMP:-}"; do
    if [ -n "$tmp" ]; then
      rm -f -- "$tmp"
    fi
  done
}

launch_blind() {
  local dir=$1
  shift
  [ "$#" -ge 1 ] && [ "$1" = -- ] || die "launch expected -- before the command"
  shift
  [ "$#" -ge 1 ] || die "launch needs a command after --"
  assert_blind "$dir"
  cd -- "$dir"
  GIT_DIR=/fm-zt-no-repository exec env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
    -u GITLAB_TOKEN -u GL_TOKEN "$@"
}

parse_brief_opts() {
  RUN_ID='' REPO='' PR_URL='' HEAD_SHA='' BASE_BRANCH='' MERGE_BASE=''
  SOURCE_DIR='' INTENT_FILE='' SURFACE='' EVIDENCE='' OUT_DIR='' RESCOPE=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id|--repo|--pr|--head|--base|--merge-base|--source|--intent-file|--surface|--evidence|--out|--rescope)
        [ "$#" -ge 2 ] || die "missing value for $1"
        case "$1" in
          --run-id) RUN_ID=$2 ;;
          --repo) REPO=$2 ;;
          --pr) PR_URL=$2 ;;
          --head) HEAD_SHA=$2 ;;
          --base) BASE_BRANCH=$2 ;;
          --merge-base) MERGE_BASE=$2 ;;
          --source) SOURCE_DIR=$2 ;;
          --intent-file) INTENT_FILE=$2 ;;
          --surface) SURFACE=$2 ;;
          --evidence) EVIDENCE=$2 ;;
          --out) OUT_DIR=$2 ;;
          --rescope) RESCOPE=$2 ;;
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
    $0 == "## Independent-review suspicions" { if (stage != 2 || seen == 0) { bad = "order"; exit } stage = 3; seen = 0; next }
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

# Each pull request URL names two files in the state directory.
# zt-pr-<sha256 of the URL>.zt-history is the append-only verdict history
# this script writes: a pr= line, then one line per recorded report.
# zt-pr-<same>.zt-verified is the single overwritten record that earlier
# versions wrote. It is read only while no history exists and never written.
review_record_base() {
  local url=$1 sum
  sum=$(printf '%s' "$url" | sha256sum)
  sum=${sum%% *}
  [ "${#sum}" -eq 64 ] || die "could not name the review record"
  case "$sum" in
    *[!0-9a-f]*) die "could not name the review record" ;;
  esac
  printf '%s\n' "$STATE/zt-pr-$sum"
}

VERDICT_WORDS='PASS|PRODUCT_FAIL|INFRA_FAIL|FLAKY|BLOCKED|ENVIRONMENT_NOT_READY|INCOMPLETE'

# Prints the URL, then each entry line in order. Returns 2 when there is no
# history and 1 when any line is malformed.
read_history() {
  local path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 2
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  awk -v words="$VERDICT_WORDS" '
    BEGIN { entry = "^head=[0-9a-f]{40} verdict=(" words ") scope=(full|delta|carried) date=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z( floor=(-|[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*))?$" }
    NR == 1 {
      if ($0 !~ /^pr=./) { bad = 1; exit }
      print substr($0, 4)
      next
    }
    $0 ~ entry { print; next }
    { bad = 1; exit }
    END { if (bad || NR == 0) exit 1 }
  ' "$path"
}

append_history() {
  local path=$1 pr=$2 head=$3 verdict=$4 scope=$5 floor=$6 tmp parsed rc=0
  mkdir -p -- "$STATE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    tmp=$path.tmp.$$
    printf 'pr=%s\n' "$pr" >"$tmp"
    # ln never replaces an existing path, so two first records write one header.
    ln -- "$tmp" "$path" 2>/dev/null || true
    rm -f -- "$tmp"
  fi
  parsed=$(read_history "$path") || rc=$?
  [ "$rc" -eq 0 ] || die "review history $path is unreadable, so nothing was recorded"
  [ "${parsed%%$'\n'*}" = "$pr" ] || die "review history $path does not match $pr, so nothing was recorded"
  printf 'head=%s verdict=%s scope=%s date=%s floor=%s\n' "$head" "$verdict" "$scope" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$floor" >>"$path"
}

read_legacy_record() {
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
  case "|$VERDICT_WORDS|" in
    *"|$verdict|"*) ;;
    *) return 1 ;;
  esac
  printf '%s\nhead=%s verdict=%s scope=unknown date=unknown\n' "$pr" "$head" "$verdict"
}

# Prints the URL and the entry lines from the history, or from the legacy
# record while no history exists. Returns 2 when neither exists and 1 when
# the one it reads is malformed.
review_entries() {
  local base=$1 rc=0 out
  out=$(read_history "$base.zt-history") || rc=$?
  # A history that holds only its pr= line lost its first entry to a crash.
  if [ "$rc" -eq 0 ] && [ "$out" != "${out%%$'\n'*}" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || return "$rc"
  read_legacy_record "$base.zt-verified"
}

# The Findings part names each reproduced finding on one line:
#   - Floor: <ID> <security|data-loss|false-success|core-path|regression> base=absent ...
#   - Below floor: <ID> <filed issue URL> ...
#   - Pre-existing: <ID> <filed issue or fix PR URL> ...
# PRODUCT_FAIL needs a Floor line and PASS allows none (ZT-SEV-1). A finding
# the merge base also has is Pre-existing, never Floor (ZT-PREEX-1). Prints
# the Floor IDs joined by commas, or - when there are none.
report_floor() {
  awk -v verdict="$2" '
    /^## Findings$/ { inf = 1; next }
    /^## / { inf = 0 }
    inf && /^- Floor: / {
      if ($0 !~ /^- Floor: [A-Za-z0-9-]+ (security|data-loss|false-success|core-path|regression) base=(absent|present)( |$)/) { bad = "a Floor line needs an ID, a floor category and base=absent"; exit }
      if ($0 ~ / base=present/) { bad = $3 " is on the merge base too, so it is a Pre-existing line, not a floor defect of the change"; exit }
      floor = floor (floor == "" ? "" : ",") $3
      next
    }
    inf && /^- (Below floor|Pre-existing): / {
      if ($0 !~ /^- (Below floor|Pre-existing): [A-Za-z0-9-]+ https:\/\/[^ ]+/) { bad = "a Below floor or Pre-existing line needs its filed issue or PR URL"; exit }
      next
    }
    END {
      if (bad != "") { print "bad " bad; exit }
      if (verdict == "PRODUCT_FAIL" && floor == "") { print "bad PRODUCT_FAIL needs a Floor line (ZT-SEV-1)"; exit }
      if (verdict == "PASS" && floor != "") { print "bad PASS with open floor defects " floor; exit }
      print (floor == "" ? "-" : floor)
    }
  ' "$1"
}

# The change of a head: its merge-base-to-head diff without context lines,
# that is each file header with its mode and rename lines and each added or
# removed line, in order. A head that only replays the change on a newer
# base has the same change id. An empty change or a binary file refuses.
change_id() {
  local src=$1 base=$2 head=$3 mb change rc=0
  mb=$(git -C "$src" merge-base "$base" "$head") || die "no merge base of $base and $head in $src"
  change=$(git -C "$src" diff -U0 --no-ext-diff --no-textconv --no-color "$mb" "$head" \
    | awk '
      /^diff --git / { hdr = 1; print; next }
      /^@@/ { hdr = 0; next }
      hdr && /^Binary files / { bin = 1; exit }
      hdr && /^(index |similarity index |dissimilarity index |--- |\+\+\+ )/ { next }
      { print }
      END { if (bin) exit 3 }
    ') || rc=$?
  [ "$rc" -ne 3 ] || die "head $head changes a binary file, so its change cannot be compared and it needs a review (ZT-LOOP-4)"
  [ "$rc" -eq 0 ] || die "cannot read the change of $head in $src"
  [ -n "$change" ] || die "head $head has no change over $base, so there is no replayed change to carry"
  printf '%s\n' "$change" | git hash-object --stdin
}

# Reads the entry lines on stdin and prints the open failure, that is the
# head and Floor IDs of the latest PRODUCT_FAIL with no PASS after it (- -
# when none is open, and ? for Floor IDs recorded before floor lines), then
# the count of failed re-checks (ZT-LOOP-6): each PRODUCT_FAIL of a head
# other than the open failure's head, over the whole history.
open_failure() {
  awk '
    { h = $1; sub(/^head=/, "", h); v = $2; sub(/^verdict=/, "", v)
      f = "?"; for (i = 3; i <= NF; i++) if ($i ~ /^floor=/) f = substr($i, 7)
      if (v == "PASS") { oh = ""; next }
      if (v == "PRODUCT_FAIL") { if (oh != "" && h != oh) n++; oh = h; of = f } }
    END { if (oh == "") print "- - " n + 0; else print oh, of, n + 0 }
  '
}

# ZT-LOOP-7: every commit on top of the tested head names, in a ZT-Fixes
# trailer, only floor defects of the change from the tested head's report.
fix_scope() {
  local src=$1 tested=$2 fixed=$3 floor=$4 sha ids id list bad=0
  git -C "$src" merge-base --is-ancestor "$tested" "$fixed" \
    || die "fixed head $fixed is not built on the tested head $tested; a fix round adds commits on top (ZT-LOOP-7)"
  [ "$floor" != - ] || die "the tested head's report names no floor defect, so no fix round is open (ZT-SEV-1)"
  while IFS=$'\t' read -r sha ids; do
    ids=${ids//[[:space:]]/}
    [ -n "$ids" ] || { printf 'error: commit %s names no ZT-Fixes ID\n' "$sha" >&2; bad=1; continue; }
    IFS=, read -ra list <<<"$ids"
    for id in "${list[@]}"; do
      case ",$floor," in
        *",$id,"*) ;;
        *) printf 'error: commit %s fixes %s, which is not a floor defect of the change; it goes to its own PR\n' "$sha" "$id" >&2; bad=1 ;;
      esac
    done
  done < <(git -C "$src" log --reverse --format='%H%x09%(trailers:key=ZT-Fixes,valueonly,separator=%x2C)' "$tested..$fixed")
  [ "$bad" -eq 0 ] || die "the fix round carries work outside the floor defects $floor (ZT-LOOP-7)"
}

# Run before a review of a pull request that already has a history. It
# refuses a third fix round without the owner's re-scope decision (ZT-LOOP-6)
# and a fix round that carries work outside the floor defects (ZT-LOOP-7).
recheck_gate() {
  local pr=$1 src=$2 head=$3 rescope=$4 base rc=0 parsed o_head o_floor failed
  require_text_arg "pr-url" "$pr"
  hex40 "$head" || die "head is not 40 hex characters"
  if [ -n "$rescope" ]; then
    [ -f "$rescope" ] && [ ! -L "$rescope" ] && [ -s "$rescope" ] || die "--rescope needs the owner's re-scope decision as a non-empty file"
  fi
  base=$(review_record_base "$pr")
  parsed=$(review_entries "$base") || rc=$?
  if [ "$rc" -eq 2 ]; then
    [ -z "$rescope" ] || die "--rescope only lifts the limit of two failed re-checks, and $pr has no review yet"
    printf 'first-review\n'
    return 0
  fi
  [ "$rc" -eq 0 ] || die "review record $base is unreadable"
  read -r o_head o_floor failed < <(printf '%s\n' "${parsed#*$'\n'}" | open_failure)
  if [ -n "$rescope" ] && { [ "$o_head" = - ] || [ "$failed" -lt 2 ]; }; then
    die "--rescope only lifts the limit of two failed re-checks (ZT-LOOP-6), and $pr has no open failure at that limit"
  fi
  if [ "$o_head" = - ]; then printf 'no-open-failure\nfailed-rechecks=%s\n' "$failed"; return 0; fi
  if [ "$failed" -ge 2 ] && [ -z "$rescope" ]; then
    die "$pr has $failed failed re-checks; the next review needs the owner's re-scope decision (ZT-LOOP-6), passed as --rescope <file>"
  fi
  if [ "$o_head" != "$head" ]; then
    if [ "$o_floor" = '?' ]; then
      printf 'note: the failed review of %s was recorded before floor lines, so the fix-round scope is not checked\n' "$o_head" >&2
    else
      fix_scope "$src" "$o_head" "$head" "$o_floor"
    fi
  fi
  printf 'recheck-of=%s\nfailed-rechecks=%s\n' "$o_head" "$failed"
}

# A home opts in with the config/zero-trust-required presence flag. A config
# directory that cannot be searched refuses rather than reading as absent.
zero_trust_required() {
  local config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  if [ -e "$config/zero-trust-required" ] || [ -L "$config/zero-trust-required" ]; then
    return 0
  fi
  if [ -d "$config" ] && [ ! -x "$config" ]; then
    die "cannot search $config for zero-trust-required, so the merge is refused"
  fi
  return 1
}

cmd=${1:-}
[ -n "$cmd" ] || die "missing command"
shift || true

case "$cmd" in
  identity)
    if [ "${1:-}" = --check ]; then
      skill_bytes >/dev/null
      require_newest_pin
    elif [ -n "${1:-}" ]; then
      die "unknown identity option ${1}"
    fi
    identity_line
    ;;
  show-skill)
    skill_bytes
    ;;
  staff)
    [ "$#" -eq 3 ] || die "staff needs a source repository, a merge base, and a head"
    print_staff "$1" "$2" "$3"
    ;;
  brief)
    parse_brief_opts "$@"
    [ -z "$OUT_DIR" ] || die "brief does not take --out"
    [ -z "$RESCOPE" ] || die "brief does not take --rescope"
    BRIEF_TMP=
    DIFF_TMP=
    trap cleanup EXIT
    BRIEF_TMP=$(mktemp)
    write_brief "$RUN_ID" "$REPO" "$PR_URL" "$HEAD_SHA" "$BASE_BRANCH" "$MERGE_BASE" \
      "$SOURCE_DIR" "$INTENT_FILE" "$SURFACE" "$EVIDENCE" "$BRIEF_TMP"
    cat -- "$BRIEF_TMP"
    ;;
  prepare)
    parse_brief_opts "$@"
    [ -n "$OUT_DIR" ] || die "prepare needs --out"
    [ ! -e "$OUT_DIR" ] || die "prepare refuses an existing path: $OUT_DIR"
    parent=$(dirname -- "$OUT_DIR")
    [ -d "$parent" ] || die "prepare parent is not a directory: $parent"
    parent=$(CDPATH='' cd -- "$parent" && pwd -P)
    if inside_worktree "$parent"; then
      die "refusing to build a blind review directory inside a git checkout: $parent"
    fi
    recheck_gate "$PR_URL" "$SOURCE_DIR" "$HEAD_SHA" "$RESCOPE" >/dev/null
    PREPARE_BYTES=
    PREPARE_DIR=
    DIFF_TMP=
    trap cleanup EXIT
    PREPARE_BYTES=$(mktemp)
    skill_bytes >"$PREPARE_BYTES"
    mkdir -- "$OUT_DIR"
    PREPARE_DIR=$OUT_DIR
    write_brief "$RUN_ID" "$REPO" "$PR_URL" "$HEAD_SHA" "$BASE_BRANCH" "$MERGE_BASE" \
      "$SOURCE_DIR" "$INTENT_FILE" "$SURFACE" "$EVIDENCE" "$OUT_DIR/brief.md"
    mv -- "$PREPARE_BYTES" "$OUT_DIR/skill.md"
    PREPARE_BYTES=
    assert_blind "$OUT_DIR"
    PREPARE_DIR=
    measure=$(print_staff "$SOURCE_DIR" "$MERGE_BASE" "$HEAD_SHA")
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
    [ "$#" -eq 5 ] && [ "$4" = --scope ] \
      || die "record-report needs a task id, a report file, a pull request URL, and --scope full|delta"
    fm_pr_task_id_valid "$1" || die "invalid task id"
    require_text_arg "pr-url" "$3"
    case "$5" in
      full|delta) ;;
      *) die "--scope must be full or delta" ;;
    esac
    parsed=$(report_ok "$2")
    tested=$(printf '%s\n' "$parsed" | awk 'NR == 1 { print; exit }')
    verdict=$(printf '%s\n' "$parsed" | awk 'NR == 2 { print; exit }')
    report_pr=$(printf '%s\n' "$parsed" | awk 'NR == 3 { print; exit }')
    [ "$report_pr" = "$3" ] || die "report Repo / PR is $report_pr, not $3"
    floor=$(report_floor "$2" "$verdict")
    case "$floor" in
      bad\ *) die "report findings refused (${floor#bad })" ;;
    esac
    path=$(review_record_base "$3").zt-history
    append_history "$path" "$3" "$tested" "$verdict" "$5" "$floor"
    printf 'recorded=%s\nhead=%s\nverdict=%s\nscope=%s\nfloor=%s\n' "$path" "$tested" "$verdict" "$5" "$floor"
    ;;
  history)
    [ "$#" -eq 1 ] || die "history needs a pull request URL"
    require_text_arg "pr-url" "$1"
    base=$(review_record_base "$1")
    rc=0
    parsed=$(review_entries "$base") || rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'no-review\n'
      exit 0
    fi
    [ "$rc" -eq 0 ] || die "review record $base is unreadable"
    [ "${parsed%%$'\n'*}" = "$1" ] || die "review record $base does not match $1"
    printf 'pr=%s\n' "$parsed"
    ;;
  recheck-gate)
    [ "$#" -eq 3 ] || { [ "$#" -eq 5 ] && [ "$4" = --rescope ]; } \
      || die "recheck-gate needs a pull request URL, a source repository, the head to review, and optionally --rescope <owner decision file>"
    recheck_gate "$1" "$2" "$3" "${5:-}"
    ;;
  carry)
    [ "$#" -eq 5 ] || die "carry needs a task id, a pull request URL, a source repository, a base ref and the new head"
    fm_pr_task_id_valid "$1" || die "invalid task id"
    require_text_arg "pr-url" "$2"
    hex40 "$5" || die "new head is not 40 hex characters"
    base=$(review_record_base "$2")
    rc=0
    parsed=$(review_entries "$base") || rc=$?
    [ "$rc" -eq 0 ] || die "no readable review history for $2, so there is nothing to carry"
    latest=${parsed##*$'\n'}
    l_head=${latest#head=}; l_head=${l_head%% *}
    case "$latest" in
      *" verdict=PASS scope=full "*|*" verdict=PASS scope=carried "*) ;;
      *) die "the latest verdict for $2 is not a full or carried PASS, so it cannot carry (ZT-LOOP-4)" ;;
    esac
    old=$(change_id "$3" "$4" "$l_head")
    new=$(change_id "$3" "$4" "$5")
    [ "$old" = "$new" ] || die "head $5 changes other lines than the passed head $l_head, so it needs a review (ZT-LOOP-4)"
    append_history "$base.zt-history" "$2" "$5" PASS carried -
    printf 'carried=%s\nfrom=%s\nchange=%s\n' "$5" "$l_head" "$new"
    ;;
  check-merge)
    [ "$#" -eq 3 ] || die "check-merge needs a task id, a pull request URL, and a live head"
    fm_pr_task_id_valid "$1" || die "invalid task id"
    require_text_arg "pr-url" "$2"
    hex40 "$3" || die "live head is not 40 hex characters"
    base=$(review_record_base "$2")
    rc=0
    parsed=$(review_entries "$base") || rc=$?
    if [ "$rc" -eq 2 ]; then
      if zero_trust_required; then
        die "refusing to merge $2 because this home requires a zero-trust review before merge and none is recorded"
      fi
      printf 'no-review\n'
      exit 0
    fi
    [ "$rc" -eq 0 ] || die "review record $base is unreadable, so the merge is refused"
    recorded_pr=${parsed%%$'\n'*}
    latest=${parsed##*$'\n'}
    if [ "$recorded_pr" != "$2" ]; then
      die "review record $base does not match $2, so the merge is refused"
    fi
    recorded_head=${latest#head=}
    recorded_head=${recorded_head%% *}
    recorded_verdict=${latest#* verdict=}
    recorded_verdict=${recorded_verdict%% *}
    if [ "$recorded_verdict" != PASS ]; then
      die "refusing to merge $2 because the latest review verdict is $recorded_verdict, not PASS"
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
