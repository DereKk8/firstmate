#!/usr/bin/env bash
# Check a pull request title and body against fleet PR conventions.
#
# This is a deterministic layout check, not a quality judge and not a
# replacement for bin/fm-pr-check.sh (merge-poll arming). It does not
# constrain the internal shape of pipeline-owned sections.
#
# Evidence sampled 2026-08-20 (merged PRs; conclusions only):
#   - oulow-os/oulow-infrastructure #122 (corrected), #121
#   - oulow-os/oulow-brain #56 (shipped as "chore: update pull request")
#   - oulow-os/oulow-body #33
#   - kunchenguid/firstmate #2659
#   - DereKk8/firstmate #72 (same placeholder title), #71
# Findings:
#   - Pipeline PRs always have a "## What Changed" heading. Its body is
#     sometimes a bullet list and sometimes a fenced code block
#     ("Final changed paths and statuses:"). Existence only is justified;
#     requiring bullets is not (that is the bin/fm-pr-check.sh bug).
#   - A one-sentence prose opener is the fleet convention and is missing
#     whenever the body starts at ## Intent. #122 was corrected to start
#     with one prose sentence; #56 and DereKk8/firstmate #72 were not.
#   - Placeholder titles "chore: update pull request" and "update pull
#     request" are an explicit reject list, not a quality heuristic.
#   - Intent / Testing / Risk Assessment / Pipeline appear often but not
#     in every sampled PR, so they are not default required sections.
#   - Oulow SOP extras (Notion id in the title, How to test, Closes #N)
#     almost never appear in sampled Oulow PRs. They are project-profile
#     rules and apply only when the caller states that a ticket or issue
#     exists. A task with no ticket is legitimate.
#
# Profiles (keep this table the declaration; do not grow a rules engine):
#   default  - opener, non-placeholder title, What Changed heading exists
#   oulow    - default, plus ticket-conditional SOP extras
# Unknown owner/repo uses default. oulow-os/* selects oulow unless
# --profile overrides it.
#
# Usage:
#   fm-pr-body-check.sh <pr-url>
#   fm-pr-body-check.sh <number> --repo <owner/repo>
#   fm-pr-body-check.sh --title <text> --body-file <path> [--repo <owner/repo>]
#   fm-pr-body-check.sh --help
#
# Fetch uses gh-axi pr view --full. Offline --title/--body-file needs no
# network. --notion-id and --issue are caller-supplied facts; this script
# never infers or invents a ticket.
#
# Exit 0: compliant (silent).
# Exit 1: non-compliant (one stdout line per violation).
# Exit 2: could not read the PR, bad usage, or unparseable input.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  printf '%s\n' \
    'usage: fm-pr-body-check.sh <pr-url>' \
    '       fm-pr-body-check.sh <number> --repo <owner/repo>' \
    '       fm-pr-body-check.sh --title <text> --body-file <path> [--repo <owner/repo>]' \
    '       fm-pr-body-check.sh --help' \
    '' \
    'optional: --profile default|oulow  --notion-id <id>  --issue <n>'
}

unread() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

TITLE=
BODY_FILE=
REPO=
PROFILE=
NOTION_ID=
ISSUE=
PR_REF=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --title)
      [ $# -ge 2 ] || unread "--title requires a value"
      TITLE=$2
      shift 2
      ;;
    --title=*)
      TITLE=${1#--title=}
      shift
      ;;
    --body-file)
      [ $# -ge 2 ] || unread "--body-file requires a path"
      BODY_FILE=$2
      shift 2
      ;;
    --body-file=*)
      BODY_FILE=${1#--body-file=}
      shift
      ;;
    --repo|-R)
      [ $# -ge 2 ] || unread "--repo requires owner/repo"
      REPO=$2
      shift 2
      ;;
    --repo=*|-R=*)
      REPO=${1#*=}
      shift
      ;;
    --profile)
      [ $# -ge 2 ] || unread "--profile requires a value"
      PROFILE=$2
      shift 2
      ;;
    --profile=*)
      PROFILE=${1#--profile=}
      shift
      ;;
    --notion-id)
      [ $# -ge 2 ] || unread "--notion-id requires a value"
      NOTION_ID=$2
      shift 2
      ;;
    --notion-id=*)
      NOTION_ID=${1#--notion-id=}
      shift
      ;;
    --issue)
      [ $# -ge 2 ] || unread "--issue requires a value"
      ISSUE=$2
      shift 2
      ;;
    --issue=*)
      ISSUE=${1#--issue=}
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      unread "unrecognized argument: $1"
      ;;
    *)
      [ -z "$PR_REF" ] || unread "unexpected extra argument: $1"
      PR_REF=$1
      shift
      ;;
  esac
done
[ $# -eq 0 ] || unread "unexpected extra argument: $1"

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

is_placeholder_title() {
  local t
  t=$(trim "$1")
  t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    'chore: update pull request'|'update pull request') return 0 ;;
    *) return 1 ;;
  esac
}

resolve_profile() {
  if [ -n "$PROFILE" ]; then
    case "$PROFILE" in
      default|oulow) printf '%s\n' "$PROFILE" ;;
      *) unread "unknown profile '$PROFILE' (expected default or oulow)" ;;
    esac
    return
  fi
  case "${REPO:-}" in
    oulow-os/*) printf '%s\n' oulow ;;
    *) printf '%s\n' default ;;
  esac
}

extract_toon_field() {
  python3 -c '
import ast, re, sys
key = sys.argv[1]
text = sys.stdin.read()
pat = "(?m)^\\s*" + re.escape(key) + ":\\s*(\"(?:\\\\.|[^\"\\\\])*\")"
m = re.search(pat, text)
if not m:
    raise SystemExit(2)
sys.stdout.write(ast.literal_eval(m.group(1)))
' "$1"
}

fetch_pr() {
  local owner=$1 repo=$2 number=$3 raw
  command -v gh-axi >/dev/null 2>&1 || unread "gh-axi is not on PATH"
  command -v python3 >/dev/null 2>&1 || unread "python3 is required to parse a fetched PR"
  raw=$(GH_PROMPT_DISABLED=1 gh-axi pr view "$number" --repo "$owner/$repo" --full 2>/dev/null) \
    || unread "could not fetch GitHub PR $owner/$repo#$number"
  FETCHED_TITLE=$(printf '%s\n' "$raw" | extract_toon_field title) \
    || unread "could not parse title from gh-axi output for $owner/$repo#$number"
  FETCHED_BODY=$(printf '%s\n' "$raw" | extract_toon_field body) \
    || unread "could not parse body from gh-axi output for $owner/$repo#$number"
}

# Offline vs fetch. Mixing the two is refused so a fixture cannot silently
# ignore a URL, and a live fetch cannot ignore an intended fixture.
if [ -n "$TITLE" ] || [ -n "$BODY_FILE" ]; then
  [ -n "$TITLE" ] || unread "--title and --body-file must be used together"
  [ -n "$BODY_FILE" ] || unread "--title and --body-file must be used together"
  [ -z "$PR_REF" ] || unread "do not mix a PR reference with --title/--body-file"
  [ -f "$BODY_FILE" ] || unread "body file is unreadable: $BODY_FILE"
  [ ! -L "$BODY_FILE" ] || unread "body file must be a regular file: $BODY_FILE"
  BODY=$(cat "$BODY_FILE") || unread "could not read body file: $BODY_FILE"
else
  [ -n "$PR_REF" ] || unread "a PR URL/number or --title/--body-file is required"
  if fm_pr_url_parse "$PR_REF"; then
    [ "$FM_PR_PROVIDER" = github ] || unread "only GitHub pull requests are supported"
    REPO="${FM_PR_OWNER}/${FM_PR_REPO}"
    fetch_pr "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER"
    TITLE=$FETCHED_TITLE
    BODY=$FETCHED_BODY
  else
    [[ "$PR_REF" =~ ^[1-9][0-9]*$ ]] || unread "not a GitHub PR URL or number: $PR_REF"
    [ -n "$REPO" ] || unread "a number requires --repo owner/repo"
    case "$REPO" in
      */*) ;;
      *) unread "--repo must be owner/repo" ;;
    esac
    fetch_pr "${REPO%%/*}" "${REPO#*/}" "$PR_REF"
    TITLE=$FETCHED_TITLE
    BODY=$FETCHED_BODY
  fi
fi

if [ -n "$REPO" ]; then
  case "$REPO" in
    */*) ;;
    *) unread "--repo must be owner/repo" ;;
  esac
fi
if [ -n "$ISSUE" ]; then
  [[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || unread "--issue must be a positive integer"
fi

EFFECTIVE_PROFILE=$(resolve_profile)
BODY=${BODY//$'\r'/}
TITLE=$(trim "$TITLE")

# --- checks -----------------------------------------------------------------

violations=()
violate() {
  violations+=("$1")
}

heading_text() {
  local line=$1
  line=${line#"${line%%[![:space:]]*}"}
  while [ "${line#"#"}" != "$line" ]; do
    line=${line#"#"}
  done
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  printf '%s' "$line"
}

line_kind() {
  local line=$1
  case "$line" in
    ''|[[:space:]]*)
      if [ -z "$(trim "$line")" ]; then
        printf '%s\n' empty
        return
      fi
      ;;
  esac
  local stripped
  stripped=${line#"${line%%[![:space:]]*}"}
  case "$stripped" in
    '#'*)
      printf '%s\n' heading
      return
      ;;
    '```'*|'~~~'*)
      printf '%s\n' fence
      return
      ;;
    '<'*)
      printf '%s\n' html
      return
      ;;
  esac
  if [[ "$stripped" =~ ^(-{3,}|\*{3,}|_{3,})[[:space:]]*$ ]]; then
    printf '%s\n' hr
    return
  fi
  if [[ "$stripped" =~ ^[-*+][[:space:]] ]] || [[ "$stripped" =~ ^[0-9]+\.[[:space:]] ]]; then
    printf '%s\n' bullet
    return
  fi
  printf '%s\n' prose
}

first_nonempty_line() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(line_kind "$line")" = empty ] && continue
    printf '%s\n' "$line"
    return 0
  done
  return 1
}

next_nonempty_after_opener() {
  local line seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$seen" -eq 0 ]; then
      [ "$(line_kind "$line")" = empty ] && continue
      seen=1
      continue
    fi
    [ "$(line_kind "$line")" = empty ] && continue
    printf '%s\n' "$line"
    return 0
  done
  return 1
}

collect_headings() {
  local line text
  HEADINGS=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(line_kind "$line")" = heading ] || continue
    text=$(heading_text "$line")
    [ -n "$text" ] || continue
    HEADINGS+=("$text")
  done
}

heading_equals_ci() {
  local want=$1 got
  got=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  [ "$got" = "$want" ]
}

heading_has_prefix_ci() {
  local want=$1 got
  got=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
  case "$got" in
    "$want"|"$want"*) return 0 ;;
    *) return 1 ;;
  esac
}

found_headings_summary() {
  if [ "${#HEADINGS[@]}" -eq 0 ]; then
    printf '%s' '(none)'
    return
  fi
  local i out=
  for i in "${HEADINGS[@]}"; do
    out="${out}${out:+, }$i"
  done
  printf '%s' "$out"
}

has_heading_what_changed() {
  local h
  for h in "${HEADINGS[@]+"${HEADINGS[@]}"}"; do
    heading_equals_ci "What Changed" "$h" && return 0
  done
  return 1
}

has_heading_how_to_test() {
  local h
  for h in "${HEADINGS[@]+"${HEADINGS[@]}"}"; do
    heading_has_prefix_ci "How to test" "$h" && return 0
  done
  return 1
}

# Title
if [ -z "$TITLE" ]; then
  violate "title: found an empty title; expected a specific non-placeholder title"
elif is_placeholder_title "$TITLE"; then
  violate "title: found placeholder '$TITLE'; expected a specific title, not 'chore: update pull request' or 'update pull request'"
fi

# Opener
OPENER=
if ! OPENER=$(printf '%s\n' "$BODY" | first_nonempty_line); then
  violate "opener: found an empty body; expected the first non-empty line to be a single prose sentence describing the change"
else
  opener_kind=$(line_kind "$OPENER")
  case "$opener_kind" in
    heading)
      violate "opener: found a heading '$OPENER'; expected a single prose sentence describing the change, not a heading"
      ;;
    bullet)
      violate "opener: found a bullet '$OPENER'; expected a single prose sentence describing the change, not a list item"
      ;;
    fence)
      violate "opener: found a code fence '$OPENER'; expected a single prose sentence describing the change, not a fence"
      ;;
    html|hr)
      violate "opener: found non-prose '$OPENER'; expected a single prose sentence describing the change"
      ;;
    prose)
      opener_trim=$(trim "$OPENER")
      case "$opener_trim" in
        *[.?!])
          NEXT_LINE=
          if NEXT_LINE=$(printf '%s\n' "$BODY" | next_nonempty_after_opener); then
            next_kind=$(line_kind "$NEXT_LINE")
            if [ "$next_kind" = prose ]; then
              violate "opener: found more prose after the first sentence ('$NEXT_LINE'); expected a single sentence, then a heading"
            fi
          fi
          ;;
        *)
          violate "opener: found a prose line that does not end in '.' '?' or '!': '$opener_trim'; expected one sentence"
          ;;
      esac
      ;;
  esac
fi

HEADINGS=()
collect_headings <<<"$BODY"

if ! has_heading_what_changed; then
  violate "section: found headings $(found_headings_summary); expected a 'What Changed' heading (any level; contents unconstrained)"
fi

if [ "$EFFECTIVE_PROFILE" = oulow ]; then
  if [ -n "$NOTION_ID" ]; then
    case "$TITLE" in
      *"$NOTION_ID"*) ;;
      *)
        violate "notion-id: found title '$TITLE'; expected the Notion task id '$NOTION_ID' in the title"
        ;;
    esac
  fi
  if [ -n "$NOTION_ID" ] || [ -n "$ISSUE" ]; then
    if ! has_heading_how_to_test; then
      violate "how-to-test: found headings $(found_headings_summary); expected a 'How to test' heading because this Oulow task has a ticket or linked issue"
    fi
  fi
  if [ -n "$ISSUE" ]; then
    if ! printf '%s\n' "$BODY" | grep -Eqi "(^|[[:space:]])Closes[[:space:]]+#${ISSUE}([[:space:]]|[[:punct:]]|$)"; then
      violate "closes: found no 'Closes #${ISSUE}' reference; expected 'Closes #${ISSUE}' because this Oulow task has linked issue ${ISSUE}"
    fi
  fi
fi

if [ "${#violations[@]}" -eq 0 ]; then
  exit 0
fi
printf '%s\n' "${violations[@]}"
exit 1
