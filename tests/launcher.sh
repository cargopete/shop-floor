#!/usr/bin/env bash
# Runs launch-worker.sh against a throwaway repo with fake claude and gh binaries.
set -euo pipefail
L="$(cd "$(dirname "$0")/.." && pwd)/skills/shop-floor-lead/launch-worker.sh"
T=$(mktemp -d)
export SF_DIR="$T/sf" TMUX_TMPDIR="$T" SF_GH_REPO=o/r
# shellcheck disable=SC2317  # called from the trap
cleanup() {
  for s in "$T"/tmux-*/*; do [ -S "$s" ] && tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
git config --global user.email >/dev/null 2>&1 || { git config --global user.email ci@example.com; git config --global user.name ci; }
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
git -C "$T/repo" commit -q --allow-empty -m init
git -C "$T/repo" push -q origin main
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
brief="$2"
echo "some stderr noise" >&2
case "$brief" in
  *REVIEWME*) printf '%s\n' '{"type":"result","subtype":"success","result":"**APPROVE WITH NITS**\n- f:1 nit"}'; exit 0 ;;
  *MORE*) echo y >> f; git add f; git commit -qm "address review"; pr=$(grep -o '/[^ ]*pr.md' <<<"$brief" | head -n 1); printf 'Add f\n\nCloses #1\n' > "$pr" ;;
  *CAP*) echo '{"type":"result","subtype":"error_max_turns"}'; exit 0 ;;
  *ENV*) [ "${SF_TEST_AUTH:-}" = from-launcher ] || { echo '{"type":"result","subtype":"error_during_execution"}'; exit 1; }
         echo x > f; git add f; git commit -qm "add f" ;;
  *TRAILER*) echo x > f; git add f; git commit -qm "add f" -m "Co-Authored-By: Claude <noreply@anthropic.com>" ;;
  *COMMIT*) echo x > f; git add f; git commit -qm "add f" ;;
esac
pr=$(grep -o '/[^ ]*pr.md' <<<"$brief" | head -n 1)
case "$brief" in *COMMIT*|*TRAILER*|*ENV*) printf 'Add f\n\nCloses #1\n' > "$pr" ;; esac
echo '{"type":"result","subtype":"success","result":"did the thing"}'
FAKE
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$SF_DIR/gh.log"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/9" ;;
  "issue view") echo worker-failed ;;
esac
FAKE
cat > "$T/publish" <<'FAKE'
#!/usr/bin/env bash
echo "publishing $SF_BRANCH to $SF_GH_REPO: $SF_PR_TITLE"
[ -s "$SF_PR_BODY_FILE" ] && echo "https://github.com/o/r/pull/77"
FAKE
chmod +x "$T/bin/claude" "$T/bin/gh" "$T/publish"
export PATH="$T/bin:$PATH"

# A tmux server that already runs with a different environment must not leak
# into the worker: that was a real bug.
env -u SF_TEST_AUTH tmux new-session -d -s unrelated "sleep 60"

cd "$T/repo"
for b in nothing COMMIT TRAILER CAP ENV; do echo "$b" > "$T/$b.md"; done
"$L" nothing "$T/nothing.md" >/dev/null
SF_ISSUE=1 "$L" commit "$T/COMMIT.md" >/dev/null
"$L" trailer "$T/TRAILER.md" >/dev/null
SF_ISSUE=2 "$L" cap "$T/CAP.md" >/dev/null
SF_PUSH=0 "$L" local "$T/COMMIT.md" >/dev/null
SF_TEST_AUTH=from-launcher "$L" env "$T/ENV.md" >/dev/null
SF_PUBLISH="$T/publish" "$L" publish "$T/COMMIT.md" >/dev/null

for _ in $(seq 50); do
  n=$(find "$SF_DIR/logs" -name result | wc -l)
  [ "$n" -ge 7 ] && break; sleep 0.2
done
echo REVIEWME > "$T/REVIEWME.md"
"$L" --review commit "$T/REVIEWME.md" >/dev/null
for _ in $(seq 50); do [ -s "$SF_DIR/logs/review-commit/result" ] && break; sleep 0.2; done
fail=0
expect() {
  local got; got=$(head -n 1 "$SF_DIR/logs/$1/result" 2>/dev/null || echo "(no result)")
  if [[ "$got" == $2* ]]; then echo "ok   $1: $got"; else echo "FAIL $1: wanted '$2...', got '$got'"; fail=1; fi
}
has() { if grep -qF -- "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3"; fail=1; fi; }
expect nothing "FAILED: clean exit but no commits"
expect commit  "DONE: https://github.com/o/r/pull/9"
expect trailer "FAILED: commits or PR text carry an AI attribution"
expect cap     "CAP HIT: max turns"
expect local   "DONE (local)"
expect env     "DONE: https://github.com/o/r/pull/9"
expect publish "DONE: https://github.com/o/r/pull/77"
expect review-commit "REVIEWED: APPROVE WITH NITS"
if [ "$(git -C "$SF_DIR/worktrees/repo/review-commit" rev-parse HEAD)" = "$(git -C "$T/repo" rev-parse agent/commit)" ]; then
  echo "ok   review checks out the worker's branch"
else echo "FAIL review checkout"; fail=1; fi
git -C "$T/repo" rev-parse -q --verify agent/review-commit >/dev/null && { echo "FAIL review made a branch"; fail=1; }
git -C "$T/origin.git" rev-parse -q --verify agent/commit >/dev/null || { echo "FAIL commit branch not pushed"; fail=1; }
! git -C "$T/origin.git" rev-parse -q --verify agent/trailer >/dev/null || { echo "FAIL trailer branch was pushed"; fail=1; }
! git -C "$T/origin.git" rev-parse -q --verify agent/publish >/dev/null || { echo "FAIL built-in push ran despite SF_PUBLISH"; fail=1; }
has "$SF_DIR/gh.log" "issue edit 1 -R o/r --add-label worker-running" "worker-running added at launch"
has "$SF_DIR/gh.log" "issue edit 1 -R o/r --remove-label worker-running" "worker-running removed at the end"
has "$SF_DIR/gh.log" "issue edit 2 -R o/r --add-label worker-failed" "worker-failed added when the run ends without a PR"
has "$SF_DIR/gh.log" "pr create -R o/r --base main --head agent/commit" "PR opened against the right repo and base"
grep -q "issue edit 1 -R o/r --add-label worker-failed" "$SF_DIR/gh.log" && { echo "FAIL worker-failed added to a DONE run"; fail=1; }
if grep -qE "^commit +DONE" <<<"$("$L" --status)"; then echo "ok   --status shows the verdict"; else echo "FAIL --status"; "$L" --status; fail=1; fi
echo MORE > "$T/MORE.md"
if "$L" commit "$T/nothing.md" >/dev/null 2>&1; then echo "FAIL relaunch over commits was allowed"; fail=1; else echo "ok   relaunch over existing commits refused"; fi
rm "$SF_DIR/logs/commit/result"; SF_CONTINUE=1 "$L" commit "$T/MORE.md" >/dev/null
for _ in $(seq 50); do [ -s "$SF_DIR/logs/commit/result" ] && break; sleep 0.2; done
expect commit "DONE: https://github.com/o/r/pull/9"
if [ "$(git -C "$T/repo" rev-list --count main..agent/commit)" = 2 ]; then echo "ok   continue added a commit on the same branch"
else echo "FAIL continue"; fail=1; fi
SF_CONTINUE=1 "$L" commit "$T/nothing.md" >/dev/null
for _ in $(seq 50); do [ -s "$SF_DIR/logs/commit/result" ] && break; sleep 0.2; done
expect commit "FAILED: clean exit but no new commits"
if [ "$(find "$SF_DIR/logs/commit/history" -name run.jsonl | wc -l)" -ge 2 ]; then echo "ok   earlier runs kept in history"; else echo "FAIL history"; fail=1; fi
exit $fail
