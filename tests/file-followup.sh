#!/usr/bin/env bash
# file-followup.sh against a fake gh and throwaway repos.
# shellcheck disable=SC2016  # backticks in patterns are Markdown
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)/skills/shop-floor-followups/file-followup.sh"
T=$(mktemp -d)
# shellcheck disable=SC2317,SC2329  # called from the trap
cleanup() { local rc=$?; rm -rf "$T"; exit "$rc"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

run() {
  local dir=$1
  shift
  set +e
  out=$(cd "$dir" && "$@" 2>&1)
  rc=$?
  set -e
}

mkdir -p "$T/repo"
git -C "$T/repo" init -q

# A fake gh that logs its calls. FAKE_GH_EXISTING is printed for issue list,
# FAKE_GH_CREATE_FAIL makes issue create fail.
cat >"$T/gh" <<'G'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "--version ") echo "gh version 2.0.0" ;;
  "repo view") [ -z "${FAKE_GH_NOAUTH:-}" ] || { echo "not logged in" >&2; exit 1; }; echo "o/r" ;;
  "issue list") printf '%b' "${FAKE_GH_EXISTING:-}" ;;
  "label create") exit 1 ;; # already exists; must be ignored
  "issue create")
    [ -z "${FAKE_GH_CREATE_FAIL:-}" ] || { echo "HTTP 403" >&2; exit 1; }
    for a in "$@"; do printf '%s\n' "$a"; done >"$FAKE_GH_LOG.create"
    echo "https://github.com/o/r/issues/77" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
G
chmod +x "$T/gh"
export FAKE_GH_LOG="$T/log" SF_GH="$T/gh"

# GitHub path: files an issue with the label, the details and the source.
run "$T/repo" bash "$S" --title "Parser drops a trailing comma" --where src/p.rs:12 \
  --why "configs fail to load" --fix "accept it" --from "https://github.com/o/r/pull/5"
if [ "$rc" = 0 ] && [ "$out" = "https://github.com/o/r/issues/77" ] &&
  grep -qx -- "--label" "$T/log.create" && grep -qx followup "$T/log.create" &&
  grep -q 'src/p.rs:12' "$T/log.create" && grep -q 'pull/5' "$T/log.create" &&
  [ ! -e "$T/repo/.followups.md" ]; then
  ok "files a followup issue"
else
  bad "issue path rc=$rc out=$out"
fi

# Same title already open (any case): not filed again.
rm -f "$T/log.create"
run "$T/repo" env FAKE_GH_EXISTING='https://github.com/o/r/issues/3\tparser drops a TRAILING comma\n' \
  bash "$S" --title "Parser drops a trailing comma"
if [ "$rc" = 0 ] && grep -q "already filed: https://github.com/o/r/issues/3" <<<"$out" && [ ! -e "$T/log.create" ]; then
  ok "doesn't file a duplicate"
else
  bad "dedupe rc=$rc out=$out"
fi

# gh can't create it: the finding lands in .followups.md instead of vanishing.
run "$T/repo" env FAKE_GH_CREATE_FAIL=1 bash "$S" --title "Flaky test in ci" --where tests/a.rs:3
if [ "$rc" = 0 ] && grep -qx -- "- \[ \] Flaky test in ci" "$T/repo/.followups.md" &&
  grep -q 'where: `tests/a.rs:3`' "$T/repo/.followups.md"; then
  ok "falls back to .followups.md when gh fails"
else
  bad "fallback rc=$rc out=$out"
fi

# No gh at all: file, and no duplicates there either.
run "$T/repo" env SF_GH="$T/no-such-gh" bash "$S" --title "Flaky test in ci"
n=$(grep -c -- "- \[ \] Flaky test in ci" "$T/repo/.followups.md")
if [ "$rc" = 0 ] && [ "$n" = 1 ] && grep -q "already in" <<<"$out"; then
  ok "no gh: .followups.md, deduped"
else
  bad "no-gh rc=$rc n=$n out=$out"
fi

# --file never touches GitHub, and works from a subdirectory.
mkdir -p "$T/repo/sub"
: >"$T/log"
run "$T/repo/sub" bash "$S" --file --title "Docs mention a removed flag" --from "#12"
if [ "$rc" = 0 ] && [ ! -s "$T/log" ] && grep -q "Docs mention a removed flag" "$T/repo/.followups.md" &&
  [ ! -e "$T/repo/sub/.followups.md" ] && grep -q 'from: #12' "$T/repo/.followups.md"; then
  ok "--file writes at the repo root without gh"
else
  bad "--file rc=$rc out=$out"
fi

# gh installed but not logged in: the file, not an error.
run "$T/repo" env FAKE_GH_NOAUTH=1 bash "$S" --title "Unauthed finding"
if [ "$rc" = 0 ] && grep -qx -- "- \[ \] Unauthed finding" "$T/repo/.followups.md"; then
  ok "gh without a login falls back to .followups.md"
else
  bad "no-auth rc=$rc out=$out"
fi

# --repo skips repo view (which would fail here) and goes to GitHub.
rm -f "$T/log.create"
run "$T/repo" env FAKE_GH_NOAUTH=1 bash "$S" --repo x/y --title "Explicit repo" --why "line one
line two"
if [ "$rc" = 0 ] && [ "$out" = "https://github.com/o/r/issues/77" ] &&
  grep -q "x/y" "$T/log.create" && grep -q "line one line two" "$T/log.create"; then
  ok "--repo is used as given, newlines flattened"
else
  bad "--repo rc=$rc out=$out"
fi

# A same-title entry in the file, in another case, isn't added twice.
before=$(wc -l <"$T/repo/.followups.md")
run "$T/repo" bash "$S" --file --title "FLAKY TEST IN CI"
if [ "$rc" = 0 ] && [ "$(wc -l <"$T/repo/.followups.md")" = "$before" ]; then
  ok ".followups.md dedupe ignores case"
else
  bad "file dedupe case rc=$rc out=$out"
fi

# A hand-edited star entry with trailing spaces still counts as the same title.
printf '* [ ] Hand Edited   \n' >>"$T/repo/.followups.md"
before=$(wc -l <"$T/repo/.followups.md")
run "$T/repo" bash "$S" --file --title "hand edited"
if [ "$rc" = 0 ] && [ "$(wc -l <"$T/repo/.followups.md")" = "$before" ]; then
  ok ".followups.md dedupe matches star bullets and trailing spaces"
else
  bad "file dedupe star rc=$rc out=$out"
fi

# A headless worker files nothing and gets the line for its PR text.
: >"$T/log"
cp "$T/repo/.followups.md" "$T/before.md"
run "$T/repo" env SF_WORKER=1 bash "$S" --title "Worker finding" --where a.rs:1 --why "a|b" --fix f
if [ "$rc" = 0 ] && [ ! -s "$T/log" ] && cmp -s "$T/before.md" "$T/repo/.followups.md" &&
  grep -qx -- "- Worker finding | a.rs:1 | a/b | f" <<<"$out"; then
  ok "SF_WORKER=1 hands the follow-up back"
else
  bad "worker rc=$rc out=$out"
fi

# Usage errors.
run "$T/repo" bash "$S" --title --where x
if [ "$rc" = 2 ] && grep -q -- "--title needs a value" <<<"$out"; then
  ok "a flag isn't taken as a value"
else
  bad "flag as value rc=$rc out=$out"
fi
run "$T/repo" bash "$S" --title
if [ "$rc" = 2 ] && grep -q -- "--title needs a value" <<<"$out"; then
  ok "a flag without a value is a usage error"
else
  bad "missing value rc=$rc out=$out"
fi
run "$T/repo" bash "$S" --where x
if [ "$rc" = 2 ] && grep -q -- "--title is required" <<<"$out"; then
  ok "--title is required"
else
  bad "no title rc=$rc out=$out"
fi
run "$T/repo" bash "$S" --help
if [ "$rc" = 0 ] && grep -q -- "--from" <<<"$out" && ! grep -Eq "set -euo|shellcheck" <<<"$out"; then
  ok "--help prints the header"
else
  bad "help rc=$rc out=$out"
fi

exit "$fail"
