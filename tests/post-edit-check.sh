#!/usr/bin/env bash
# post-edit-check.sh against throwaway trees and a fake cargo.
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)/skills/shop-floor-worker/post-edit-check.sh"
T=$(mktemp -d)
# shellcheck disable=SC2317,SC2329  # called from the trap
cleanup() { local rc=$?; rm -rf "$T"; exit "$rc"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Run the check without set -e aborting on a non-zero exit.
# Usage: check <dir> [env assignments are already in the environment] -- then $out $rc
check() {
  local dir=$1
  shift
  set +e
  out=$(cd "$dir" && "$@" 2>&1)
  rc=$?
  set -e
}

# An empty tree has nothing to run.
mkdir -p "$T/empty"
check "$T/empty" bash "$S" </dev/null
if [ "$rc" = 0 ] && grep -q "nothing to run" <<<"$out"; then
  ok "empty tree is a no-op"
else
  bad "empty tree rc=$rc out=$out"
fi

# SF_CHECK overrides detection and can pass or fail.
check "$T/empty" env SF_CHECK=true bash "$S" </dev/null
if [ "$rc" = 0 ]; then
  ok "SF_CHECK=true passes"
else
  bad "SF_CHECK=true failed: $out"
fi
check "$T/empty" env SF_CHECK=false bash "$S" </dev/null
if [ "$rc" = 1 ] && grep -q FAILED <<<"$out"; then
  ok "SF_CHECK=false fails loudly"
else
  bad "SF_CHECK=false rc=$rc out=$out"
fi

# .shop-floor-check at the repo root wins over auto-detect.
mkdir -p "$T/file/needs-me"
printf '#!/usr/bin/env bash\necho ran-the-file-check; exit 0\n' > "$T/file/.shop-floor-check"
printf '[package]\nname = "x"\nversion = "0.1.0"\nedition = "2021"\n' > "$T/file/needs-me/Cargo.toml"
# A cargo that would fail if we auto-detected instead of using the file.
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho unexpected-cargo >&2; exit 1\n' > "$T/bin/cargo"
chmod +x "$T/bin/cargo"
check "$T/file" env PATH="$T/bin:$PATH" bash "$S" </dev/null
if [ "$rc" = 0 ] && grep -q ran-the-file-check <<<"$out"; then
  ok ".shop-floor-check is used"
else
  bad ".shop-floor-check rc=$rc out=$out"
fi

# Auto-detect cargo in a subdirectory when the root has no manifest.
cat > "$T/bin/cargo" <<FAKE
#!/usr/bin/env bash
echo cargo-check "$@" > "$T/cargo.log"
exit 0
FAKE
mkdir -p "$T/sub/crate"
printf '[package]\nname = "x"\nversion = "0.1.0"\nedition = "2021"\n' > "$T/sub/crate/Cargo.toml"
git -C "$T/sub" init -q
check "$T/sub" env PATH="$T/bin:$PATH" bash "$S" </dev/null
if [ "$rc" = 0 ] && grep -q cargo-check "$T/cargo.log"; then
  ok "detects cargo one level down"
else
  bad "subdir cargo rc=$rc log=$(cat "$T/cargo.log" 2>/dev/null) out=$out"
fi

# A non-git parent of a crate is not scanned.
mkdir -p "$T/parent/crate"
printf '[package]\nname = "x"\nversion = "0.1.0"\nedition = "2021"\n' > "$T/parent/crate/Cargo.toml"
check "$T/parent" env PATH="$T/bin:$PATH" bash "$S" </dev/null
if [ "$rc" = 0 ] && grep -q "nothing to run" <<<"$out"; then
  ok "non-git parent of a crate is a no-op"
else
  bad "non-git parent rc=$rc out=$out"
fi

# Hook event: skip a markdown edit, even if SF_CHECK would fail.
hook_md='{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"README.md"},"cwd":"'"$T/empty"'"}'
check "$T/empty" env SF_CHECK=false bash "$S" <<<"$hook_md"
if [ "$rc" = 0 ] && grep -q skipping <<<"$out"; then
  ok "hook skips markdown"
else
  bad "markdown hook rc=$rc out=$out"
fi

# Hook event: a source edit that fails uses exit 2.
hook_rs='{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"src/lib.rs"},"cwd":"'"$T/empty"'"}'
check "$T/empty" env SF_CHECK=false bash "$S" <<<"$hook_rs"
if [ "$rc" = 2 ] && grep -q FAILED <<<"$out"; then
  ok "hook failure is exit 2"
else
  bad "source hook rc=$rc out=$out"
fi

exit $fail
