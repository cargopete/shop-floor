#!/usr/bin/env bash
# launch-worker.sh: run one headless Claude Code worker on one GitHub issue.
#
#   launch-worker.sh <name> <brief-file> [model]    start a worker in tmux
#   launch-worker.sh --review <name> <brief-file> [model]
#                                                   fresh-context review of agent/<name>
#   launch-worker.sh --status                       one line per run
#
# Run it from inside the repo the worker should change (or set SF_REPO).
# Each run gets its own git worktree, a branch agent/<name> cut from the
# default branch, a tmux session sf-<name> on its own tmux server (so the
# worker gets this shell's environment; watch it with tmux -L sf-<name> attach)
# and a log directory. The worker commits only. When it exits, this script checks the result, pushes the
# branch and opens one PR with the text the worker wrote. A run that exits
# cleanly without commits or PR text is recorded as FAILED, not done.
# A review run (review-<name>) gets a detached checkout of agent/<name>,
# no Edit or Write tools by default, and its verdict as the result; it never pushes.
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
#   SF_TOOLS       allowed tools (default: "Bash Edit Write Read Glob Grep";
#                  reviews get "Bash Read Glob Grep")
#   SF_CONTINUE=1  carry on an existing agent/<name> (e.g. to address a review);
#                  the push updates its PR, and the run fails without new commits
#   SF_PUSH=0      leave the branch local, don't open a PR
#   SF_ALLOW_ATTRIBUTION=1  push even if commits carry AI co-author trailers
#   SF_GH          the gh command for labels and the PR (default: gh), e.g.
#                  "sudo -n -u someone -H gh" when workers run as their own user
#   SF_GH_REPO     owner/repo for gh (default: read from origin's URL)
#   SF_PUBLISH     a script to push and open the PR instead of the built-in
#                  step. It gets SF_NAME, SF_BRANCH, SF_WORKTREE, SF_BASE,
#                  SF_GH_REPO, SF_PR_TITLE and SF_PR_BODY_FILE in its env and
#                  prints the PR URL as its last line
#
# Needs: git, tmux, jq, claude, and gh for labels and the PR step.
set -euo pipefail

die() { echo "launch-worker: $*" >&2; exit 1; }
SF_DIR="${SF_DIR:-$HOME/.shop-floor}"
# Each run has its own tmux server: a shared server would hand the worker the
# environment of whoever started that server, not yours.
tm() { local name=$1; shift; tmux -L "sf-$name" "$@"; }

status() {
  shopt -s nullglob
  local f any=0
  for f in "$SF_DIR"/logs/*/meta; do
    any=1
    local d name state
    d=$(dirname "$f"); name=$(basename "$d")
    if tm "$name" has-session -t "sf-$name" 2>/dev/null; then state="running"
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
  # Runs started by an older copy of this script have fewer keys.
  MODE=${MODE:-work} GH_CMD=${GH_CMD:-gh} GH_REPO=${GH_REPO:-} PUBLISH=${PUBLISH:-}
  local -a GH; read -r -a GH <<<"$GH_CMD"
  local res="$d/result" summary
  # The log mixes claude's JSON lines with anything it printed to stderr.
  summary=$(jq -Rrn --arg t "$MAX_TURNS" '
    [inputs | fromjson? | objects | select(.type=="result")] | last // empty |
    if .subtype=="success" then .result
    elif .subtype=="error_max_turns" then "CAP HIT: max turns (" + $t + ")"
    elif .subtype=="error_max_budget_usd" then "CAP HIT: max budget"
    else "ERROR: " + (.subtype // "unknown") end' "$d/run.jsonl" 2>/dev/null || true)
  local commits new
  commits=$(git -C "$WT" log --oneline "$BASE..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  new=$(git -C "$WT" log --oneline "${START:-$BASE}..HEAD" 2>/dev/null | wc -l | tr -d ' ')

  local verdict
  if [ "$MODE" = review ]; then
    if [ -z "$summary" ]; then
      verdict="ABORTED: no result record (timeout after ${TIMEOUT}s or crash). See $d/run.jsonl"
    elif [[ "$summary" == CAP\ HIT* || "$summary" == ERROR* ]]; then
      verdict="$summary"
    else
      verdict="REVIEWED: $(grep -m 1 -v '^[[:space:]]*$' <<<"$summary" | tr -d '*#`' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-120)"
    fi
    [ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ] || verdict="$verdict (note: the review changed tracked files)"
    { echo "$verdict"; [ -n "$summary" ] && { echo; echo "$summary"; }; } > "$res"
    return 0
  fi
  if [ -z "$summary" ]; then
    verdict="ABORTED: no result record (timeout after ${TIMEOUT}s or crash). See $d/run.jsonl"
  elif [[ "$summary" == CAP\ HIT* || "$summary" == ERROR* ]]; then
    verdict="$summary. Work so far is on agent/$name ($commits commits)"
  elif [ "$commits" = 0 ]; then
    verdict="FAILED: clean exit but no commits, so no PR"
  elif [ "$new" = 0 ]; then
    verdict="FAILED: clean exit but no new commits on agent/$name"
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
    if [ -n "$PUBLISH" ]; then
      url=$(SF_NAME="$name" SF_BRANCH="agent/$name" SF_WORKTREE="$WT" SF_BASE="${BASE#origin/}" \
            SF_GH_REPO="$GH_REPO" SF_PR_TITLE="$title" SF_PR_BODY_FILE="$d/pr-body.md" \
            "$PUBLISH" 2>"$d/push.err" | tail -n 1) || true
      [[ "$url" == http* ]] || url=""
    elif git -C "$WT" push -q -u origin "agent/$name" 2>"$d/push.err"; then
      url=$("${GH[@]}" pr list -R "$GH_REPO" --head "agent/$name" --state open --json url -q '.[0].url' 2>>"$d/push.err") || url=""
      if [ -n "$url" ]; then
        "${GH[@]}" pr edit "$url" --title "$title" --body-file "$d/pr-body.md" >/dev/null 2>>"$d/push.err" || true
      else
        url=$("${GH[@]}" pr create -R "$GH_REPO" --base "${BASE#origin/}" --head "agent/$name" \
              --title "$title" --body-file "$d/pr-body.md" 2>>"$d/push.err") || url=""
      fi
    fi
    if [ -n "$url" ]; then
      verdict="DONE: $url"
    else
      verdict="FAILED: push or PR step failed, see $d/push.err"
    fi
  fi
  { echo "$verdict"; [ -n "$summary" ] && { echo; echo "$summary"; }; } > "$res"

  if [ -n "$ISSUE" ]; then
    local ok=1
    "${GH[@]}" issue edit "$ISSUE" -R "$GH_REPO" --remove-label worker-running >/dev/null 2>>"$d/labels.err" || ok=0
    case "$verdict" in DONE*) ;; *)
      "${GH[@]}" issue edit "$ISSUE" -R "$GH_REPO" --add-label worker-failed >/dev/null 2>>"$d/labels.err" || ok=0 ;;
    esac
    [ "$ok" = 1 ] || printf '\nnote: could not update the labels on #%s, see %s\n' "$ISSUE" "$d/labels.err" >> "$res"
  fi
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --finish) finish "$2"; exit 0 ;;
  ""|-h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

MODE=work
if [ "$1" = --review ]; then MODE=review; shift; fi
NAME=${1:-}; BRIEF=${2:-}; MODEL=${3:-sonnet}
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "name must match [A-Za-z0-9._-]+"
SRC=$NAME
if [ "$MODE" = review ]; then NAME="review-$SRC"; SF_ISSUE=""; SF_PUSH=0; fi
[ -f "$BRIEF" ] || die "brief file not found: $BRIEF"
for c in git tmux jq claude; do command -v "$c" >/dev/null || die "$c is not installed"; done
MAX_TURNS=${SF_MAX_TURNS:-60}; TIMEOUT=${SF_TIMEOUT:-5400}; ISSUE=${SF_ISSUE:-}
[[ "$MAX_TURNS$TIMEOUT" =~ ^[0-9]+$ ]] || die "SF_MAX_TURNS and SF_TIMEOUT must be whole numbers"
[ -z "${SF_MAX_BUDGET:-}" ] || [[ "$SF_MAX_BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "SF_MAX_BUDGET must be a number"
[ -z "$ISSUE" ] || [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "SF_ISSUE must be an issue number"
GH_CMD=${SF_GH:-gh}; read -r -a GH <<<"$GH_CMD"
PUBLISH=${SF_PUBLISH:-}
[ -z "$PUBLISH" ] || [ -x "$PUBLISH" ] || die "SF_PUBLISH must be an executable file: $PUBLISH"

REPO=$(git -C "${SF_REPO:-.}" rev-parse --show-toplevel 2>/dev/null) || die "not in a git repo (set SF_REPO)"
git -C "$REPO" fetch -q --prune origin
BASE=${SF_BASE:-$(git -C "$REPO" symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)}
case "$BASE" in origin/*) ;; *) BASE="origin/$BASE" ;; esac
git -C "$REPO" rev-parse -q --verify "$BASE" >/dev/null || die "base $BASE not found"
# owner/repo for gh -R, so gh never has to guess from the working directory.
GH_REPO=${SF_GH_REPO:-}
[ -n "$GH_REPO" ] || GH_REPO=$(git -C "$REPO" remote get-url origin | sed -E 's#^(https?://[^/]+/|[^@]+@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##')
[[ "$GH_REPO" =~ ^[^/]+/[^/]+$ ]] || GH_REPO=""
if [ -n "$ISSUE" ] || { [ "${SF_PUSH:-1}" = 1 ] && [ -z "$PUBLISH" ]; }; then
  [ -n "$GH_REPO" ] || die "can't tell owner/repo from origin's URL; needed for gh"
  command -v "${GH[0]}" >/dev/null || die "${GH[0]} is not installed"
fi

tm "$NAME" has-session -t "sf-$NAME" 2>/dev/null && die "sf-$NAME is still running"
D="$SF_DIR/logs/$NAME"; WT="$SF_DIR/worktrees/$(basename "$REPO")/$NAME"
mkdir -p "$D" "$(dirname "$WT")"
if [ "$MODE" = review ]; then
  HEAD_SHA=$(git -C "$REPO" rev-parse -q --verify "agent/$SRC" || git -C "$REPO" rev-parse -q --verify "origin/agent/$SRC") ||
    die "no branch agent/$SRC to review"
  [ ! -d "$WT" ] || git -C "$REPO" worktree remove --force "$WT"
  git -C "$REPO" worktree add -q --detach "$WT" "$HEAD_SHA"
elif [ "${SF_CONTINUE:-0}" = 1 ]; then
  if [ ! -d "$WT" ]; then
    if git -C "$REPO" show-ref -q --verify "refs/heads/agent/$NAME"; then
      git -C "$REPO" worktree add -q "$WT" "agent/$NAME"
    elif git -C "$REPO" rev-parse -q --verify "origin/agent/$NAME" >/dev/null; then
      git -C "$REPO" worktree add -q -b "agent/$NAME" "$WT" "origin/agent/$NAME"
    else
      die "SF_CONTINUE=1 but there is no agent/$NAME to continue"
    fi
  fi
else
  if [ -d "$WT" ] && [ -n "$(git -C "$WT" log --oneline "$BASE..HEAD")" ]; then
    die "agent/$NAME already has commits in $WT; set SF_CONTINUE=1 to carry on, or pick a new name"
  fi
  [ -d "$WT" ] || git -C "$REPO" worktree add -q -B "agent/$NAME" "$WT" "$BASE"
fi
START=$(git -C "$WT" rev-parse HEAD)
# Keep the previous run's log and result (a continue or a rerun of a review).
if [ -s "$D/run.jsonl" ]; then
  mkdir -p "$D/history"; H=$(mktemp -d "$D/history/$(date +%Y%m%d-%H%M%S).XXXX")
  for f in run.jsonl result brief.md pr.md; do [ ! -e "$D/$f" ] || cp "$D/$f" "$H/"; done
fi
rm -f "$D/result" "$D/push.err" "$D/labels.err"
[ "${SF_CONTINUE:-0}" = 1 ] || rm -f "$D/pr.md"

{
  cat "$BRIEF"
  printf '\n\n---\n'
  if [ "$MODE" = review ]; then
    printf 'This is a review run. The checkout is branch agent/%s at %s; review it against %s (git diff %s...HEAD).\n' "$SRC" "$HEAD_SHA" "$BASE" "$BASE"
    printf 'Do not edit tracked files, commit or push. You may build and run the tests.\n'
    printf 'Finish with your verdict on line 1 (APPROVE, APPROVE WITH NITS or REQUEST CHANGES), then one finding per line, most important first, as: path:line, severity, issue, fix. Severity is error, warning, nit or followup (a real problem this change did not cause and does not need to fix; followups do not change the verdict). Use path:0 if there is no line.\n'
  else
  printf 'Work in this checkout, on branch agent/%s. Commit with plain messages and no AI co-author trailers.\n' "$NAME"
  [ "${SF_CONTINUE:-0}" != 1 ] || printf 'The branch already has earlier work (git log %s..HEAD) and an open PR; build on it with new commits. Do not rewrite history.\n' "$BASE"
  printf 'Do not push and do not open the PR yourself; the launcher does that after you exit.\n'
  printf 'Before you finish, write the PR text to %s: line 1 is the title, then a blank line, then the body: what changed, why, how you checked it, and a "Closes #N" line.\n' "$D/pr.md"
  printf 'Problems outside the brief are follow-ups: do not fix them, and do not write .followups.md. List them under a "Follow-ups" heading at the end of the PR text and in your summary, one per line as: title | path:line | why it matters | suggested fix. The lead files them.\n'
  printf 'Finish with a summary of at most 10 lines. Stopping with no commits counts as a failed run, so if you are blocked, say exactly what you need decided.\n'
  fi
} > "$D/brief.md"

q() { printf '%q' "$1"; }
cat > "$D/meta" <<META
WT=$(q "$WT")
BASE=$(q "$BASE")
MAX_TURNS=$(q "$MAX_TURNS")
TIMEOUT=$(q "$TIMEOUT")
ISSUE=$(q "$ISSUE")
PUSH=$(q "${SF_PUSH:-1}")
MODE=$(q "$MODE")
START=$(q "$START")
ALLOW_ATTRIBUTION=$(q "${SF_ALLOW_ATTRIBUTION:-0}")
GH_CMD=$(q "$GH_CMD")
GH_REPO=$(q "$GH_REPO")
PUBLISH=$(q "$PUBLISH")
META

DEFAULT_TOOLS="Bash Edit Write Read Glob Grep"; [ "$MODE" = work ] || DEFAULT_TOOLS="Bash Read Glob Grep"
ARGS=(--model "$MODEL" --max-turns "$MAX_TURNS"
      --permission-mode acceptEdits --allowedTools "${SF_TOOLS:-$DEFAULT_TOOLS}"
      --output-format stream-json --verbose)
[ -z "${SF_MAX_BUDGET:-}" ] || ARGS+=(--max-budget-usd "$SF_MAX_BUDGET")
[ -z "${SF_EFFORT:-}" ] || ARGS+=(--effort "$SF_EFFORT")
# The brief is read when the session starts, so long briefs never hit tmux limits.
# The worker runs without GitHub tokens in its env, with SF_WORKER=1 so
# file-followup.sh hands follow-ups back instead of filing them; the PR step afterwards uses
# your normal gh login (or SF_GH / SF_PUBLISH).
CMD="cd $(q "$WT") && (unset GH_TOKEN GITHUB_TOKEN; export SF_WORKER=1; timeout $(q "$TIMEOUT") claude -p \"\$(cat $(q "$D/brief.md"))\""
for a in "${ARGS[@]}"; do CMD+=" $(q "$a")"; done
CMD+=" > $(q "$D/run.jsonl") 2>&1); SF_DIR=$(q "$SF_DIR") bash $(q "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")") --finish $(q "$NAME")"

if [ -n "$ISSUE" ]; then
  "${GH[@]}" issue edit "$ISSUE" -R "$GH_REPO" --add-label worker-running >/dev/null 2>>"$D/labels.err" ||
    echo "launch-worker: warning: could not add worker-running to #$ISSUE (see $D/labels.err)" >&2
  # Only drop worker-failed if it's there; gh errors on removing a missing label.
  if "${GH[@]}" issue view "$ISSUE" -R "$GH_REPO" --json labels -q '.labels[].name' 2>/dev/null | grep -qx worker-failed; then
    "${GH[@]}" issue edit "$ISSUE" -R "$GH_REPO" --remove-label worker-failed >/dev/null 2>>"$D/labels.err" || true
  fi
fi
tm "$NAME" new-session -d -s "sf-$NAME" "$CMD"
echo "started sf-$NAME: model=$MODEL turns=$MAX_TURNS timeout=${TIMEOUT}s${SF_MAX_BUDGET:+ budget=$SF_MAX_BUDGET}"
echo "worktree $WT   (watch: tmux -L sf-$NAME attach)"
echo "result   $D/result  (launch-worker.sh --status for all runs)"
