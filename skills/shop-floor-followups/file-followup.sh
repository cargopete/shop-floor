#!/usr/bin/env bash
# file-followup.sh: record one out-of-scope finding so it outlives the session.
#
#   bash file-followup.sh --title "Parser drops a trailing comma" \
#     --where src/parse.rs:120 --why "configs written by tool X fail to load" \
#     --fix "accept an optional comma before the closing bracket" \
#     --from https://github.com/owner/repo/pull/42
#
# With a GitHub remote and a working gh login it opens an issue labelled
# `followup` (creating the label if the repo doesn't have it). Without one,
# or with --file, or if gh can't create the issue, it appends an entry to
# .followups.md at the repo root instead, so the finding is never dropped.
# An open issue or entry with the same title is not filed twice.
#
#   --title  required. what's wrong, in a few words
#   --where  path:line (or path, or a command) where it shows up
#   --why    why it matters
#   --fix    the fix you'd suggest
#   --from   the PR, issue or branch this was found while working on
#   --repo   owner/repo (default: the repo gh sees here)
#   --file   always write to .followups.md, never GitHub
#
# SF_GH overrides the gh command, as in launch-worker.sh. Prints the issue
# URL or the file path and exits 0; exits 2 on bad usage.
# shellcheck disable=SC2016  # the backticks are Markdown, not expansions
set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

title="" where="" why="" fix="" from="" repo="" force_file=0
while [ $# -gt 0 ]; do
  case $1 in
    --title) title=${2-}; shift 2 ;;
    --where) where=${2-}; shift 2 ;;
    --why) why=${2-}; shift 2 ;;
    --fix) fix=${2-}; shift 2 ;;
    --from) from=${2-}; shift 2 ;;
    --repo) repo=${2-}; shift 2 ;;
    --file) force_file=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "file-followup.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
title=$(tr '\n' ' ' <<<"$title" | sed 's/^ *//; s/ *$//')
[ -n "$title" ] || { echo "file-followup.sh: --title is required" >&2; exit 2; }

read -r -a GH <<<"${SF_GH:-gh}"
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

to_file() {
  local f="$root/.followups.md"
  if [ -f "$f" ] && grep -Fxq -- "- [ ] $title" "$f"; then
    echo "already in $f: $title"
    return 0
  fi
  if [ ! -s "$f" ]; then
    printf '# Follow-ups\n\nFindings that were out of scope when they were found. Tick one `[x]` when\nit is fixed, or move it to an issue. `needs-me` counts the open ones.\n' >"$f"
  fi
  {
    printf '\n- [ ] %s\n' "$title"
    [ -z "$where" ] || printf '  - where: `%s`\n' "$where"
    [ -z "$why" ] || printf '  - why: %s\n' "$why"
    [ -z "$fix" ] || printf '  - fix: %s\n' "$fix"
    [ -z "$from" ] || printf '  - from: %s\n' "$from"
    printf '  - filed: %s\n' "$(date +%F)"
  } >>"$f"
  echo "$f"
}

if [ "$force_file" = 1 ]; then
  to_file
  exit 0
fi

have_gh=1
"${GH[@]}" --version >/dev/null 2>&1 || have_gh=0
if [ "$have_gh" = 1 ] && [ -z "$repo" ]; then
  repo=$("${GH[@]}" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
if [ "$have_gh" = 0 ] || [ -z "$repo" ]; then
  echo "file-followup.sh: no gh or no GitHub repo here; writing to .followups.md" >&2
  to_file
  exit 0
fi

# Same title already open? Don't file it twice.
existing=""
want=$(tr '[:upper:]' '[:lower:]' <<<"$title")
while IFS=$'\t' read -r t u; do
  if [ "$(tr '[:upper:]' '[:lower:]' <<<"$t")" = "$want" ]; then
    existing=$u
    break
  fi
done < <("${GH[@]}" issue list --repo "$repo" --state open --label followup \
  --search "$title in:title" --limit 50 --json title,url --jq '.[] | [.title, .url] | @tsv' 2>/dev/null || true)
if [ -n "$existing" ]; then
  echo "already filed: $existing"
  exit 0
fi

# Create the label if it's missing; an existing one is left as it is.
"${GH[@]}" label create followup --repo "$repo" --color C5DEF5 \
  --description "Found while doing something else; out of scope then, worth doing" >/dev/null 2>&1 || true

body=$(
  [ -z "$where" ] || printf '**Where:** `%s`\n\n' "$where"
  [ -z "$why" ] || printf '**Why it matters:** %s\n\n' "$why"
  [ -z "$fix" ] || printf '**Suggested fix:** %s\n\n' "$fix"
  [ -z "$from" ] || printf '**Found while working on:** %s\n\n' "$from"
  printf 'Filed as a follow-up: it was out of scope for the change that found it.\n'
)
if url=$("${GH[@]}" issue create --repo "$repo" --title "$title" --label followup --body "$body" 2>&1); then
  tail -n 1 <<<"$url"
else
  echo "file-followup.sh: gh couldn't create the issue ($url); writing to .followups.md" >&2
  to_file
fi
