#!/usr/bin/env bash
# launch-worker.sh: run one headless Claude Code worker on one GitHub issue.
#
#   launch-worker.sh <name> <brief-file> [model]    start a worker in tmux
#   launch-worker.sh --status                       one line per run
#
# Run it from inside the repo the worker should change (or set SF_REPO).
# Each run gets its own git worktree, a branch agent/<name> cut from the
# default branch, a tmux session sf-<name> and a log directory. The worker
# commits only. When it exits, this script checks the result, pushes the
# branch and opens one PR with the text the worker wrote. A run that exits
# cleanly without commits or PR text is recorded as FAILED, not done.
#
# Settings (all optional):
#   SF_REPO        path to the repo                (default: the repo you're in)
#   SF_BASE        branch to cut from              (default: origin's default branch)
#   SF_DIR         where worktrees, logs, briefs go (default: ~/.shop-floor)
#   SF_ISSUE       issue number; gets worker-running while the run is on,
#                  and worker-failed if it ends without a PR
#   SF_MAX_TURNS   claude --max-turns              (default: 60)
#   SF_MAX_BUDGET  claude --max-budget-usd         (default: not passed)
#   SF_TIMEOUT     seconds before the run is killed (default: 5400)
#   SF_EFFORT      claude --effort                 (default: not passed)
#   SF_TOOLS       allowed tools (default: "Bash Edit Write Read Glob Grep")
#   SF_PUSH=0      leave the branch local, don't open a PR
#   SF_ALLOW_ATTRIBUTION=1  push even if commits carry AI co-author trailers
#
# Needs: git, tmux, jq, claude, and gh for the PR step.
set -euo pipefail

die() { echo "launch-worker: $*" >&2; exit 1; }
SF_DIR="${SF_DIR:-$HOME/.shop-floor}"

status() {
  shopt -s nullglob
  local f any=0
  for f in "$SF_DIR"/logs/*/meta; do
    any=1
    local d name state
    d=$(dirname "$f"); name=$(basename "$d")
    if tmux has-session -t "sf-$name" 2>/dev/null; then state="running"
    elif [ -s "$d/result" ]; then state=$(head -n 1 "$d/result")
    else state="no result yet"; fi
    printf '%-24s %s\n' "$name" "$state"
  done
  [ "$any" = 1 ] || echo "no runs in $SF_DIR/logs"
}

# Second half: runs inside tmux once the worker exits.
finish() {
  local name=$1 d="$SF_DIR/logs/$1"
  # shellcheck disable=SC1091
  . "$d/meta"
  local res="$d/result" summary
  # The log mixes claude's JSON lines with anything it printed to stderr.
  summary=$(jq -Rrn --arg t "$MAX_TURNS" '
    [inputs | fromjson? | objects | select(.type=="result")] | last // empty |
    if .subtype=="success" then .result
    elif .subtype=="error_max_turns" then "CAP HIT: max turns (" + $t + ")"
    elif .subtype=="error_max_budget_usd" then "CAP HIT: max budget"
    else "ERROR: " + (.subtype // "unknown") end' "$d/run.jsonl" 2>/dev/null || true)
  local commits
  commits=$(git -C "$WT" log --oneline "$BASE..HEAD" 2>/dev/null | wc -l | tr -d ' ')

  local verdict
  if [ -z "$summary" ]; then
    verdict="ABORTED: no result record (timeout after ${TIMEOUT}s or crash). See $d/run.jsonl"
  elif [[ "$summary" == CAP\ HIT* || "$summary" == ERROR* ]]; then
    verdict="$summary. Work so far is on agent/$name ($commits commits)"
  elif [ "$commits" = 0 ]; then
    verdict="FAILED: clean exit but no commits, so no PR"
  elif [ ! -s "$d/pr.md" ]; then
    verdict="FAILED: $commits commits but no PR text in $d/pr.md"
  elif [ "$PUSH" != 1 ]; then
    verdict="DONE (local): $commits commits on agent/$name, not pushed (SF_PUSH=0)"
  elif [ "$ALLOW_ATTRIBUTION" != 1 ] && grep -qiE 'co-authored-by:.*(claude|anthropic|openai|codex|gemini|cursor)|generated with (claude|codex|gemini|cursor)' \
         <<<"$(git -C "$WT" log --format=%B "$BASE..HEAD"; cat "$d/pr.md")"; then
    verdict="FAILED: commits or PR text carry an AI attribution line; not pushed (SF_ALLOW_ATTRIBUTION=1 to allow)"
  else
    local url="" title
    title=$(head -n 1 "$d/pr.md"); tail -n +3 "$d/pr.md" > "$d/pr-body.md"
    if git -C "$WT" push -q -u origin "agent/$name" 2>"$d/push.err"; then
      url=$( (cd "$WT" && gh pr list --head "agent/$name" --state open --json url -q '.[0].url' 2>>"$d/push.err") || true)
      if [ -n "$url" ]; then
        (cd "$WT" && gh pr edit "$url" --title "$title" --body-file "$d/pr-body.md" >/dev/null 2>>"$d/push.err") || true
      else
        url=$( (cd "$WT" && gh pr create --base "${BASE#origin/}" --head "agent/$name" \
              --title "$title" --body-file "$d/pr-body.md" 2>>"$d/push.err") || true)
      fi
    fi
    if [ -n "$url" ]; then
      verdict="DONE: $url"
    else
      verdict="FAILED: push or PR step failed, see $d/push.err"
    fi
  fi
  { echo "$verdict"; [ -n "$summary" ] && { echo; echo "$summary"; }; } > "$res"

  if [ -n "$ISSUE" ] && command -v gh >/dev/null; then
    (cd "$WT" && gh issue edit "$ISSUE" --remove-label worker-running >/dev/null 2>&1) || true
    case "$verdict" in DONE*) ;; *)
      (cd "$WT" && gh issue edit "$ISSUE" --add-label worker-failed >/dev/null 2>&1) || true ;;
    esac
  fi
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --finish) finish "$2"; exit 0 ;;
  ""|-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

NAME=$1; BRIEF=${2:-}; MODEL=${3:-sonnet}
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "name must match [A-Za-z0-9._-]+"
[ -f "$BRIEF" ] || die "brief file not found: $BRIEF"
for c in git tmux jq claude; do command -v "$c" >/dev/null || die "$c is not installed"; done
MAX_TURNS=${SF_MAX_TURNS:-60}; TIMEOUT=${SF_TIMEOUT:-5400}; ISSUE=${SF_ISSUE:-}
[[ "$MAX_TURNS$TIMEOUT" =~ ^[0-9]+$ ]] || die "SF_MAX_TURNS and SF_TIMEOUT must be whole numbers"
[ -z "${SF_MAX_BUDGET:-}" ] || [[ "$SF_MAX_BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "SF_MAX_BUDGET must be a number"
[ -z "$ISSUE" ] || [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "SF_ISSUE must be an issue number"

REPO=$(git -C "${SF_REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || die "not in a git repo (set SF_REPO)"
git -C "$REPO" fetch -q --prune origin
BASE=${SF_BASE:-$(git -C "$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)}
case "$BASE" in origin/*) ;; *) BASE="origin/$BASE" ;; esac
git -C "$REPO" rev-parse -q --verify "$BASE" >/dev/null || die "base $BASE not found"

tmux has-session -t "sf-$NAME" 2>/dev/null && die "sf-$NAME is still running"
D="$SF_DIR/logs/$NAME"; WT="$SF_DIR/worktrees/$(basename "$REPO")/$NAME"
mkdir -p "$D" "$(dirname "$WT")"
if [ -d "$WT" ] && [ -n "$(git -C "$WT" log --oneline "$BASE..HEAD")" ]; then
  die "agent/$NAME already has commits in $WT; pick a new name or remove the worktree"
fi
[ -d "$WT" ] || git -C "$REPO" worktree add -q -B "agent/$NAME" "$WT" "$BASE"
rm -f "$D/result" "$D/pr.md" "$D/push.err"

{
  cat "$BRIEF"
  printf '\n\n---\n'
  printf 'Work in this checkout, on branch agent/%s. Commit with plain messages and no AI co-author trailers.\n' "$NAME"
  printf 'Do not push and do not open the PR yourself; the launcher does that after you exit.\n'
  printf 'Before you finish, write the PR text to %s: line 1 is the title, then a blank line, then the body: what changed, why, how you checked it, and a "Closes #N" line.\n' "$D/pr.md"
  printf 'Finish with a summary of at most 10 lines. Stopping with no commits counts as a failed run, so if you are blocked, say exactly what you need decided.\n'
} > "$D/brief.md"

q() { printf '%q' "$1"; }
cat > "$D/meta" <<META
WT=$(q "$WT")
BASE=$(q "$BASE")
MAX_TURNS=$(q "$MAX_TURNS")
TIMEOUT=$(q "$TIMEOUT")
ISSUE=$(q "$ISSUE")
PUSH=$(q "${SF_PUSH:-1}")
ALLOW_ATTRIBUTION=$(q "${SF_ALLOW_ATTRIBUTION:-0}")
META

ARGS=(--model "$MODEL" --max-turns "$MAX_TURNS"
      --permission-mode acceptEdits --allowedTools "${SF_TOOLS:-Bash Edit Write Read Glob Grep}"
      --output-format stream-json --verbose)
[ -z "${SF_MAX_BUDGET:-}" ] || ARGS+=(--max-budget-usd "$SF_MAX_BUDGET")
[ -z "${SF_EFFORT:-}" ] || ARGS+=(--effort "$SF_EFFORT")
# The brief is read when the session starts, so long briefs never hit tmux limits.
# tmux sessions inherit the tmux server's environment, not this shell's, so PATH
# is passed on explicitly. The worker runs without GitHub tokens in its env;
# the PR step afterwards uses your normal gh login.
CMD="export PATH=$(q "$PATH"); cd $(q "$WT") && (unset GH_TOKEN GITHUB_TOKEN; timeout $(q "$TIMEOUT") claude -p \"\$(cat $(q "$D/brief.md"))\""
for a in "${ARGS[@]}"; do CMD+=" $(q "$a")"; done
CMD+=" > $(q "$D/run.jsonl") 2>&1); SF_DIR=$(q "$SF_DIR") bash $(q "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")") --finish $(q "$NAME")"

if [ -n "$ISSUE" ] && command -v gh >/dev/null; then
  (cd "$REPO" && gh issue edit "$ISSUE" --add-label worker-running >/dev/null 2>&1) || true
  (cd "$REPO" && gh issue edit "$ISSUE" --remove-label worker-failed >/dev/null 2>&1) || true
fi
tmux new-session -d -s "sf-$NAME" "$CMD"
echo "started sf-$NAME: model=$MODEL turns=$MAX_TURNS timeout=${TIMEOUT}s${SF_MAX_BUDGET:+ budget=$SF_MAX_BUDGET}"
echo "worktree $WT"
echo "result   $D/result  (launch-worker.sh --status for all runs)"
