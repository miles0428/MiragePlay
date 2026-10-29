#!/bin/bash
# vendor-uxplay.sh — materialize the pinned UxPlay source tree, verified byte-for-byte.
#
# Reads core/vendor.lock (URL / branch / commit / tree / file count / manifest),
# clones the pinned commit into DEST, then fails closed unless all of:
#   git rev-parse HEAD == VENDOR_COMMIT
#   git rev-parse HEAD^{tree} == VENDOR_TREE
#   tracked file count == VENDOR_FILE_COUNT
#   shasum -a 256 -c manifest passes for every line (90/90)
#
# Usage: scripts/build/vendor-uxplay.sh [--check] [DEST]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$SCRIPT_DIR/../lib/_canonical-path.sh"
# Canonical spelling: DEFAULT_DEST (derived from REPO_ROOT below) is the tree
# build-core.sh hands to cmake. See scripts/lib/_canonical-path.sh.
SCRIPT_DIR="$(mp_canonical_dir "$SCRIPT_DIR")" || {
  echo "vendor-uxplay: could not resolve $SCRIPT_DIR to its on-disk spelling" >&2
  exit 1
}
REPO_ROOT="$(mp_canonical_dir "$SCRIPT_DIR/../..")" || {
  echo "vendor-uxplay: could not resolve the repository root ($SCRIPT_DIR/../..)" >&2
  exit 1
}

LOCK_FILE="${VENDOR_LOCK:-$REPO_ROOT/core/vendor.lock}"
DEFAULT_DEST="$REPO_ROOT/_build/uxplay"

CHECK_ONLY=0
DEST=""

usage() {
  cat <<'EOF'
Usage: scripts/build/vendor-uxplay.sh [--check] [DEST]

  DEST      output directory (default: <repo>/_build/uxplay)
  --check   verify DEST against core/vendor.lock only; clone nothing, write nothing

Environment:
  VENDOR_LOCK           override lock file (default: <repo>/core/vendor.lock)
  VENDOR_MANIFEST_PATH  override manifest file (default: <repo>/.task_state/<name>)
EOF
}

# ---------- args ----------
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) [ -z "$DEST" ] || { echo "error: only one DEST may be given" >&2; exit 2; }
       DEST="$arg" ;;
  esac
done
[ -n "$DEST" ] || DEST="$DEFAULT_DEST"

# DEST is the UxPlay source tree: build-core.sh hands it to `cmake -S` and bakes
# it into the binary through -ffile-prefix-map. A caller-typed spelling here
# would defeat the canonical repo root upstream. It normally does not exist yet
# (this script creates it), so resolve the longest existing ancestor.
DEST="$(mp_canonical_path "$DEST")" || {
  echo "error: cannot resolve DEST '$DEST' to its on-disk spelling" >&2
  exit 1
}

# ---------- lock ----------
[ -f "$LOCK_FILE" ] || { echo "FAIL: lock file not found: $LOCK_FILE" >&2; exit 1; }

lock_get() {
  local key="$1" line
  line="$(grep -E "^${key}=" "$LOCK_FILE" | tail -n 1)" || true
  [ -n "$line" ] || { echo "FAIL: $LOCK_FILE has no key ${key}" >&2; exit 1; }
  printf '%s' "${line#*=}"
}

VENDOR_REPO_URL="$(lock_get VENDOR_REPO_URL)"
VENDOR_BRANCH="$(lock_get VENDOR_BRANCH)"
VENDOR_COMMIT="$(lock_get VENDOR_COMMIT)"
VENDOR_TREE="$(lock_get VENDOR_TREE)"
VENDOR_FILE_COUNT="$(lock_get VENDOR_FILE_COUNT)"
VENDOR_MANIFEST="$(lock_get VENDOR_MANIFEST)"
VENDOR_MANIFEST_SHA256="$(lock_get VENDOR_MANIFEST_SHA256)"

if [ -n "${VENDOR_MANIFEST_PATH:-}" ]; then
  MANIFEST_PATH="$VENDOR_MANIFEST_PATH"
elif [ -f "$REPO_ROOT/.task_state/$VENDOR_MANIFEST" ]; then
  MANIFEST_PATH="$REPO_ROOT/.task_state/$VENDOR_MANIFEST"
elif [ -f "$REPO_ROOT/$VENDOR_MANIFEST" ]; then
  MANIFEST_PATH="$REPO_ROOT/$VENDOR_MANIFEST"
else
  echo "FAIL: manifest not found: .task_state/$VENDOR_MANIFEST (set VENDOR_MANIFEST_PATH)" >&2
  exit 1
fi

BAK=""
STAGE=""
STAGE_CREATED=0
STATUS_LINE_PRINTED=0

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$STAGE_CREATED" = 1 ] && [ -d "$STAGE" ]; then
      rm -rf "$STAGE"
      echo "  rollback: removed staging dir $STAGE"
    fi
    if [ -n "$BAK" ] && [ -d "$BAK" ]; then
      if [ -e "$DEST" ]; then rm -rf "$DEST"; fi
      mv "$BAK" "$DEST"
      BAK=""
      echo "  rollback: previous tree restored at $DEST"
    fi
    if [ "$STATUS_LINE_PRINTED" = 0 ]; then echo "FAIL"; fi
  fi
  exit "$rc"
}
trap on_exit EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

# ---------- preflight ----------
echo "=== vendor-uxplay ==="
echo "  lock     = $LOCK_FILE"
echo "  dest     = $DEST"
echo "  mode     = $([ "$CHECK_ONLY" = 1 ] && echo check-only || echo materialize)"
echo "  manifest = $MANIFEST_PATH"
echo "  pin      = $VENDOR_COMMIT (tree $VENDOR_TREE, $VENDOR_FILE_COUNT files)"

echo "--- preflight: manifest self-checksum ---"
[ -f "$MANIFEST_PATH" ] || die "manifest missing: $MANIFEST_PATH"
ACTUAL_MANIFEST_SHA="$(shasum -a 256 "$MANIFEST_PATH" | cut -d' ' -f1)"
if [ "$ACTUAL_MANIFEST_SHA" != "$VENDOR_MANIFEST_SHA256" ]; then
  die "manifest sha256 mismatch: actual=$ACTUAL_MANIFEST_SHA expected=$VENDOR_MANIFEST_SHA256"
fi
echo "  manifest sha256 OK: $ACTUAL_MANIFEST_SHA"
MANIFEST_LINES="$(grep -c '' "$MANIFEST_PATH" || true)"
[ "$MANIFEST_LINES" = "$VENDOR_FILE_COUNT" ] \
  || die "manifest line count: actual=$MANIFEST_LINES expected=$VENDOR_FILE_COUNT"
echo "  manifest lines OK: $MANIFEST_LINES"

# ---------- verifier ----------
verify_dir() {
  local dir="$1" head tree count ok=0 partial out okcnt manifest_sha
  [ -d "$dir" ] || { echo "  verify: $dir does not exist"; return 1; }
  [ -d "$dir/.git" ] || { echo "  verify: $dir is not a git worktree"; return 1; }

  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '<unreadable>')"
  tree="$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || echo '<unreadable>')"
  count="$(git -C "$dir" ls-files 2>/dev/null | wc -l | tr -d ' ')"

  echo "  HEAD   actual=$head"
  echo "         expect=$VENDOR_COMMIT"
  echo "  tree   actual=$tree"
  echo "         expect=$VENDOR_TREE"
  echo "  files  actual=$count expect=$VENDOR_FILE_COUNT"

  [ "$head" = "$VENDOR_COMMIT" ] || { echo "  MISMATCH: commit"; ok=1; }
  [ "$tree" = "$VENDOR_TREE" ] || { echo "  MISMATCH: tree"; ok=1; }
  [ "$count" = "$VENDOR_FILE_COUNT" ] || { echo "  MISMATCH: file count"; ok=1; }
  [ "$ok" -eq 0 ] || return 1
  echo "  git identity OK"

  manifest_sha="$(shasum -a 256 "$MANIFEST_PATH" | cut -d' ' -f1)"
  [ "$manifest_sha" = "$VENDOR_MANIFEST_SHA256" ] \
    || { echo "  MISMATCH: manifest sha256 $manifest_sha"; return 1; }

  if out="$(cd "$dir" && shasum -a 256 -c "$MANIFEST_PATH" 2>&1)"; then
    :
  else
    echo "  manifest verification FAILED; offending entries:"
    printf '%s\n' "$out" | grep -v ': OK$' | head -n 20 | sed 's/^/    /'
    return 1
  fi
  okcnt="$(printf '%s\n' "$out" | grep -c ': OK$' || true)"
  [ "$okcnt" = "$VENDOR_FILE_COUNT" ] \
    || { echo "  MISMATCH: manifest OK count $okcnt != $VENDOR_FILE_COUNT"; return 1; }
  echo "  manifest OK: $okcnt/$VENDOR_FILE_COUNT files match sha256"
  return 0
}

# ---------- check-only ----------
if [ "$CHECK_ONLY" = 1 ]; then
  echo "--- check: verifying $DEST (no writes) ---"
  if verify_dir "$DEST"; then
    echo "  result: already matches vendor.lock — nothing to fetch"
    STATUS_LINE_PRINTED=1
    echo "PASS"
    exit 0
  fi
  die "existing tree at $DEST does not match vendor.lock"
fi

# ---------- existing dest ----------
if [ -e "$DEST" ]; then
  echo "--- existing destination found, verifying first ---"
  if verify_dir "$DEST"; then
    echo "  result: already matches vendor.lock — skipping fetch"
    STATUS_LINE_PRINTED=1
    echo "PASS"
    exit 0
  fi
  BAK="$DEST.bak"
  if [ -e "$BAK" ]; then
    BAK="$DEST.bak.$(date +%Y%m%d%H%M%S)"
  fi
  echo "  moving mismatched tree aside: $DEST -> $BAK"
  mv "$DEST" "$BAK"
fi

# ---------- fetch ----------
mkdir -p "$(dirname "$DEST")"
STAGE="$DEST.vendor-tmp.$$"
STAGE_CREATED=1

echo "--- [1/4] clone $VENDOR_REPO_URL (branch $VENDOR_BRANCH, blob-filtered, no checkout) ---"
git clone --quiet --filter=blob:none --no-checkout --branch "$VENDOR_BRANCH" \
  "$VENDOR_REPO_URL" "$STAGE"

echo "--- [2/4] checkout pinned commit $VENDOR_COMMIT ---"
git -C "$STAGE" checkout --quiet --detach "$VENDOR_COMMIT"

echo "--- [3/4] verify commit / tree / file count / per-file sha256 ---"
verify_dir "$STAGE" || die "fetched tree does not match vendor.lock (see above)"

echo "--- [4/4] install verified tree at $DEST ---"
mv "$STAGE" "$DEST"
STAGE_CREATED=0

STATUS_LINE_PRINTED=1
echo "PASS"
