#!/usr/bin/env bash
# post-edit-check.sh: run the project's typecheck/lint after edits. Fail
# loudly (non-zero, with the command and its output) when it fails.
#
# Workers run this as a required step. For Claude Code it can also be a
# PostToolUse hook; kitbag does not carry hooks, so copy
# claude-code-hook.json into ~/.claude/settings.json or the project's
# .claude/settings.json yourself. From a git source, kitbag does not make
# skill scripts executable; call this with bash.
#
# Which command, in order:
#   1. SF_CHECK, if set (run with bash -c)
#   2. .shop-floor-check at the repo root (run with bash)
#   3. auto-detect at the repo root, then one directory down:
#      cargo check, a package.json "typecheck" script, tsc --noEmit,
#      go build ./...
# If nothing applies, exit 0.
#
# When stdin is a Claude Code hook event, a doc/media/lockfile edit is
# skipped. Other hook failures use exit 2 so Claude sees the output.
set -euo pipefail

hook=0
file=""
start=$PWD

if [ ! -t 0 ]; then
  input=$(cat || true)
  if [ -n "$input" ]; then
    event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null || true)
    if [ -n "$event" ]; then
      hook=1
      file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null || true)
      cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)
      [ -z "$cwd" ] || start=$cwd
    fi
  fi
fi

fail_exit=1
[ "$hook" = 1 ] && fail_exit=2

skip_file() {
  local base
  base=$(basename "$1")
  case "$base" in
    LICENSE*|COPYING*|NOTICE*|README*|CHANGELOG*|*.md|*.markdown|*.txt|*.rst|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp|*.ico|*.pdf|*.lock|package-lock.json|pnpm-lock.yaml|bun.lockb|go.sum|*.sum|.gitignore|.gitattributes|.editorconfig)
      return 0 ;;
  esac
  return 1
}

if [ -n "$file" ] && skip_file "$file"; then
  echo "shop-floor post-edit check: skipping $file" >&2
  exit 0
fi

cd "$start"
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

failed=0
ran=0

# run <dir> <cmd> [args...]
run() {
  local dir=$1
  shift
  echo "shop-floor post-edit check: $*" >&2
  ran=1
  if (cd "$dir" && "$@"); then
    return 0
  fi
  echo "shop-floor post-edit check FAILED: $*" >&2
  failed=1
  return 0
}

typecheck_script() {
  local dir=$1 pkg=$1/package.json
  [ -f "$pkg" ] || return 1
  grep -q '"typecheck"[[:space:]]*:' "$pkg" || return 1
  if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
    run "$dir" bun run typecheck
  elif [ -f "$dir/pnpm-lock.yaml" ]; then
    run "$dir" pnpm run typecheck
  elif [ -f "$dir/yarn.lock" ]; then
    run "$dir" yarn typecheck
  else
    run "$dir" npm run typecheck
  fi
  return 0
}

tsc_check() {
  local dir=$1
  [ -f "$dir/tsconfig.json" ] || return 1
  if [ -x "$dir/node_modules/.bin/tsc" ]; then
    run "$dir" ./node_modules/.bin/tsc --noEmit
  elif command -v tsc >/dev/null; then
    run "$dir" tsc --noEmit
  elif command -v bun >/dev/null; then
    run "$dir" bun x tsc --noEmit
  else
    echo "shop-floor post-edit check FAILED: tsconfig.json in $dir but tsc is not installed" >&2
    ran=1
    failed=1
  fi
  return 0
}

detect() {
  local dir=$1 found=0
  if [ -f "$dir/Cargo.toml" ]; then
    if command -v cargo >/dev/null; then
      run "$dir" cargo check
    else
      echo "shop-floor post-edit check FAILED: Cargo.toml in $dir but cargo is not installed" >&2
      ran=1
      failed=1
    fi
    found=1
  fi
  if typecheck_script "$dir"; then
    found=1
  elif tsc_check "$dir"; then
    found=1
  fi
  if [ -f "$dir/go.mod" ]; then
    if command -v go >/dev/null; then
      run "$dir" go build ./...
    else
      echo "shop-floor post-edit check FAILED: go.mod in $dir but go is not installed" >&2
      ran=1
      failed=1
    fi
    found=1
  fi
  [ "$found" = 1 ]
}

if [ -n "${SF_CHECK:-}" ]; then
  echo "shop-floor post-edit check: $SF_CHECK" >&2
  ran=1
  if ! bash -c "cd \"$root\" && $SF_CHECK"; then
    echo "shop-floor post-edit check FAILED: $SF_CHECK" >&2
    failed=1
  fi
elif [ -f "$root/.shop-floor-check" ]; then
  echo "shop-floor post-edit check: bash $root/.shop-floor-check" >&2
  ran=1
  if ! bash "$root/.shop-floor-check"; then
    echo "shop-floor post-edit check FAILED: bash $root/.shop-floor-check" >&2
    failed=1
  fi
else
  if ! detect "$root"; then
    # Only walk one level down inside a git repo, so a crate in a
    # subdirectory is found and a random parent directory is not scanned.
    if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
      shopt -s nullglob
      for d in "$root"/*/; do
        case "$(basename "$d")" in
          node_modules|target|dist|build|out|vendor|.git|.venv|venv) continue ;;
        esac
        detect "$d" || true
      done
    fi
  fi
fi

if [ "$failed" = 1 ]; then
  exit "$fail_exit"
fi
if [ "$ran" = 0 ]; then
  echo "shop-floor post-edit check: nothing to run (set SF_CHECK or add a .shop-floor-check)" >&2
fi
exit 0
