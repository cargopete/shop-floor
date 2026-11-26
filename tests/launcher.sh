#!/usr/bin/env bash
# Runs launch-worker.sh against a throwaway repo with fake claude and gh binaries.
set -euo pipefail
L="$(cd "$(dirname "$0")/.." && pwd)/skills/shop-floor-lead/launch-worker.sh"
T=$(mktemp -d); trap 'tmux kill-server 2>/dev/null || true; rm -rf "$T"' EXIT
export SF_DIR="$T/sf" TMUX_TMPDIR="$T"
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
  *CAP*) echo '{"type":"result","subtype":"error_max_turns"}'; exit 0 ;;
  *TRAILER*) echo x > f; git add f; git commit -qm "add f" -m "Co-Authored-By: Claude <noreply@anthropic.com>" ;;
  *COMMIT*) echo x > f; git add f; git commit -qm "add f" ;;
esac
pr=$(grep -o '/[^ ]*pr.md' <<<"$brief" | head -n 1)
case "$brief" in *COMMIT*|*TRAILER*) printf 'Add f\n\nCloses #1\n' > "$pr" ;; esac
echo '{"type":"result","subtype":"success","result":"did the thing"}'
FAKE
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in "pr create") echo "https://github.com/o/r/pull/9" ;; esac
FAKE
chmod +x "$T/bin/claude" "$T/bin/gh"
export PATH="$T/bin:$PATH"

cd "$T/repo"
for b in nothing COMMIT TRAILER CAP; do echo "$b" > "$T/$b.md"; done
"$L" nothing "$T/nothing.md" >/dev/null
"$L" commit "$T/COMMIT.md" >/dev/null
"$L" trailer "$T/TRAILER.md" >/dev/null
"$L" cap "$T/CAP.md" >/dev/null
SF_PUSH=0 "$L" local "$T/COMMIT.md" >/dev/null

for _ in $(seq 50); do
  n=$(find "$SF_DIR/logs" -name result | wc -l)
  [ "$n" -ge 5 ] && break; sleep 0.2
done
fail=0
expect() {
  local got; got=$(head -n 1 "$SF_DIR/logs/$1/result" 2>/dev/null || echo "(no result)")
  if [[ "$got" == $2* ]]; then echo "ok   $1: $got"; else echo "FAIL $1: wanted '$2...', got '$got'"; fail=1; fi
}
expect nothing "FAILED: clean exit but no commits"
expect commit  "DONE: https://github.com/o/r/pull/9"
expect trailer "FAILED: commits or PR text carry an AI attribution"
expect cap     "CAP HIT: max turns"
expect local   "DONE (local)"
git -C "$T/origin.git" rev-parse -q --verify agent/commit >/dev/null || { echo "FAIL commit branch not pushed"; fail=1; }
! git -C "$T/origin.git" rev-parse -q --verify agent/trailer >/dev/null || { echo "FAIL trailer branch was pushed"; fail=1; }
"$L" commit "$T/COMMIT.md" >/dev/null 2>&1 && { echo "FAIL relaunch over commits was allowed"; fail=1; } || echo "ok   relaunch over existing commits refused"
exit $fail
