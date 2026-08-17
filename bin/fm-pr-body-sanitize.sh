#!/usr/bin/env bash
# Remove known validation-tool structures from a GitHub pull request body.
# Read the body through gh-axi, preserve legitimate subject matter, and flag
# residual tooling vocabulary for human review instead of deleting it.
# Usage: fm-pr-body-sanitize.sh <owner/repo> <pr-number> [--dry-run]
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <owner/repo> <pr-number> [--dry-run]

Remove known tooling structures from a pull request body and flag residual
references that require human review.
EOF
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage >&2
  exit 2
fi

TARGET=$1
PR_NUMBER=$2
DRY_RUN=0
if [ "$#" -eq 3 ]; then
  [ "$3" = --dry-run ] || {
    usage >&2
    exit 2
  }
  DRY_RUN=1
fi

if [[ ! "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: repository must be owner/repo" >&2
  exit 2
fi
if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: pull request number must be a positive integer" >&2
  exit 2
fi

command -v gh-axi >/dev/null 2>&1 || {
  echo "error: gh-axi is required" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to decode gh-axi output" >&2
  exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-body-sanitize.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
RAW_FILE=$TMP_ROOT/raw
BODY_FILE=$TMP_ROOT/body
SANITIZED_FILE=$TMP_ROOT/sanitized
FLAGS_FILE=$TMP_ROOT/flags
GH_ERROR=$TMP_ROOT/gh-error

if ! gh-axi api "/repos/$TARGET/pulls/$PR_NUMBER" --jq .body > "$RAW_FILE" 2>"$GH_ERROR"; then
  echo "error: could not read pull request $TARGET#$PR_NUMBER through gh-axi" >&2
  cat "$GH_ERROR" >&2
  exit 1
fi

if ! python3 - "$RAW_FILE" "$BODY_FILE" <<'PY'
import json
import re
import sys

raw_path, body_path = sys.argv[1:]
with open(raw_path, "r", encoding="utf-8", newline="") as stream:
    raw = stream.read()
matches = re.findall(r"(?m)^[ \t]*body:[ \t]*(.*)$", raw)
if len(matches) != 1:
    print("gh-axi response did not contain exactly one pull request body", file=sys.stderr)
    raise SystemExit(1)
value = matches[0].strip()
if value == "null":
    body = ""
else:
    try:
        body = json.loads(value)
    except json.JSONDecodeError as error:
        print(f"gh-axi returned an invalid pull request body: {error}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(body, str):
        print("gh-axi returned a non-string pull request body", file=sys.stderr)
        raise SystemExit(1)
with open(body_path, "w", encoding="utf-8", newline="") as stream:
    stream.write(body)
PY
then
  echo "error: could not decode the pull request body returned by gh-axi" >&2
  exit 1
fi

if ! python3 - "$BODY_FILE" "$SANITIZED_FILE" "$FLAGS_FILE" <<'PY'
import html
import re
import sys

body_path, sanitized_path, flags_path = sys.argv[1:]
with open(body_path, "r", encoding="utf-8", newline="") as stream:
    body = stream.read()

pipeline_heading = re.compile(
    r"(?im)^##[ \t]+Pipeline[ \t]*#*[ \t]*(?:\r?\n|$)"
)
same_level_heading = re.compile(r"(?m)^##(?!#)[ \t]+\S.*(?:\r?\n|$)")
while True:
    match = pipeline_heading.search(body)
    if match is None:
        break
    following = same_level_heading.search(body, match.end())
    end = following.start() if following is not None else len(body)
    body = body[: match.start()] + body[end:]

attestation_comment = re.compile(
    r"<!--[ \t]*no-mistakes-pipeline-attestation:.*?-->", re.IGNORECASE | re.DOTALL
)
body = attestation_comment.sub("", body)

path_line = re.compile(r"(?im)^[^\r\n]*/tmp/no-mistakes-evidence/[^\r\n]*(?:\r?\n|$)")
body = path_line.sub("", body)

coauthor_line = re.compile(
    r"(?im)^[ \t]*(?:[-*][ \t]+)?Co-Authored-By:[^\r\n]*(?:\r?\n|$)"
)
body = coauthor_line.sub("", body)

details_tag = re.compile(r"<(/?)details\b[^>]*>", re.IGNORECASE)
summary_tag = re.compile(r"<summary\b[^>]*>(.*?)</summary\s*>", re.IGNORECASE | re.DOTALL)

def tooling_evidence_summary(summary):
    text = html.unescape(re.sub(r"<[^>]*>", " ", summary))
    text = re.sub(r"\s+", " ", text).strip().lower()
    if "no-mistakes" in text:
        return True
    evidence_word = re.search(r"\b(?:evidence|attestation|log|output|report)\b", text)
    return "pipeline" in text and evidence_word is not None

def evidence_ranges(text):
    stack = []
    ranges = []
    for match in details_tag.finditer(text):
        if match.group(1):
            if not stack:
                continue
            start, content_start = stack.pop()
            summary = summary_tag.search(text, content_start, match.start())
            if summary is not None and tooling_evidence_summary(summary.group(1)):
                ranges.append((start, match.end()))
        else:
            stack.append((match.start(), match.end()))
    selected = []
    for start, end in sorted(ranges):
        if selected and start < selected[-1][1]:
            selected[-1] = (selected[-1][0], max(selected[-1][1], end))
        else:
            selected.append((start, end))
    return selected

for start, end in reversed(evidence_ranges(body)):
    body = body[:start] + body[end:]

flag_patterns = [
    re.compile(r"\bno[- ]mistakes\b", re.IGNORECASE),
    re.compile(r"\battestation\b", re.IGNORECASE),
    re.compile(
        r"\b(?:claude|codex|chatgpt|gpt(?:-[0-9.]+)?|openai|anthropic|copilot|cursor|"
        r"grok|kimi|gemini|mistral|deepseek|llama|ollama|perplexity)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:generated|produced|written|authored|created|implemented|reviewed|tested|"
        r"built|developed|edited)\s+(?:by|with|using)\s+(?:an?\s+)?"
        r"(?:ai|assistant|agent|llm|language model|model|tool|automation)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:ai|assistant|agent|llm)[ -](?:generated|produced|written|authored|"
        r"created|assisted)\b",
        re.IGNORECASE,
    ),
]

with open(flags_path, "w", encoding="utf-8", newline="") as flags:
    for number, line in enumerate(body.splitlines(), 1):
        if any(pattern.search(line) for pattern in flag_patterns):
            flags.write(f"flagged residual tooling reference at line {number}: {line}\n")

with open(sanitized_path, "w", encoding="utf-8", newline="") as stream:
    stream.write(body)
PY
then
  echo "error: could not sanitize the pull request body" >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$SANITIZED_FILE"
  if [ -s "$FLAGS_FILE" ]; then
    printf '\n'
    cat "$FLAGS_FILE"
  fi
  [ ! -s "$FLAGS_FILE" ]
  exit $?
fi

if [ ! -s "$BODY_FILE" ]; then
  if [ -s "$FLAGS_FILE" ]; then
    cat "$FLAGS_FILE" >&2
    exit 1
  fi
  exit 0
fi

changed=0
if ! cmp -s "$BODY_FILE" "$SANITIZED_FILE"; then
  changed=1
  if ! gh-axi pr edit "$PR_NUMBER" --repo "$TARGET" --body-file "$SANITIZED_FILE"; then
    echo "error: could not update pull request $TARGET#$PR_NUMBER through gh-axi" >&2
    exit 1
  fi
fi

if [ -s "$FLAGS_FILE" ]; then
  cat "$FLAGS_FILE" >&2
  exit 1
fi

if [ "$changed" -eq 1 ]; then
  printf 'sanitized pull request body for %s#%s\n' "$TARGET" "$PR_NUMBER"
fi
