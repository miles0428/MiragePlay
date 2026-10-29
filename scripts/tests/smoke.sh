#!/bin/bash
# smoke.sh — Stage1 smoke test (semi-automated)
# YC: click the menu bar icon → Start → AirPlay from the iPhone yourself and watch for 10 minutes
# Logs are split: smoke-data_*.md (filled in by YC after the real test) + launch.log (console output)
#
# Deliberately NOT a testkit suite: this script hands a live app to YC for a
# 10-minute manual session, so it must leave that app running after it exits.
# testkit_teardown would kill it on the way out. The paths below therefore only
# borrow the testkit's out-of-checkout location, not its lifecycle.
set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Artifact base = the shared build cache outside the checkout, with the same
# default scripts/lib/testkit.sh owns (that file is the definition; keep these
# two spellings in step). MIRAGE_PLAY_BUILD_ROOT is what a harness run exports,
# so a build produced by a suite can be smoke-tested as-is.
BUILD_ROOT="${MIRAGE_PLAY_BUILD_ROOT:-${MIRAGE_PLAY_TEST_CACHE:-$HOME/Library/Caches/mirageplay-build}}"
BUILD_DIR="$BUILD_ROOT"
LOG_FILE="$BUILD_DIR/launch.log"
SMOKE_DATA="$BUILD_DIR/reports/smoke-data_$(date '+%Y%m%d_%H%M').md"
APP_PATH=""
EXEC_PATH=""
CAND=""

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$SMOKE_DATA")"

echo "=== smoke.sh started at $(date) ===" | tee "$LOG_FILE"
echo "Artifact base: $BUILD_DIR" | tee -a "$LOG_FILE"

# Detect app path
# Priority 1: .app bundle (produced by build-app.sh packaging step)
if [ -x "$BUILD_DIR/MiragePlay.app/Contents/MacOS/MiragePlay" ]; then
  APP_PATH="$BUILD_DIR/MiragePlay.app"
else
  # Priority 2: raw swiftpm executable (fallback). The triple directory name is
  # machine-dependent, so glob for it instead of naming one architecture.
  for CAND in "$BUILD_DIR"/app.swiftpm/*/debug/MiragePlay; do
    if [ -x "$CAND" ]; then
      EXEC_PATH="$CAND"
      echo "NOTE: Using raw swiftpm executable (no .app bundle found)" | tee -a "$LOG_FILE"
      break
    fi
  done
fi

if [ -z "$APP_PATH" ] && [ -z "$EXEC_PATH" ]; then
  echo "ERROR: Cannot find MiragePlay executable in $BUILD_DIR" | tee "$LOG_FILE"
  echo "Looked for:" | tee -a "$LOG_FILE"
  echo "  - $BUILD_DIR/MiragePlay.app/Contents/MacOS/MiragePlay" | tee -a "$LOG_FILE"
  echo "  - $BUILD_DIR/app.swiftpm/*/debug/MiragePlay" | tee -a "$LOG_FILE"
  exit 1
fi

echo "App path: ${APP_PATH:-$EXEC_PATH}" | tee -a "$LOG_FILE"

# Verify the packaged projection helper (nested helper bundle inside MiragePlay.app)
# exists before launching — this is what the app spawns; the bare build artifact
# `<build cache>/core/uxplay` is packaging input only (dock-branding).
#
# The upstream UxPlay sources are not version-controlled any more (2026-10-19
# decouple) — they live in the git-ignored agent build tree, materialized by
# scripts/build/vendor-uxplay.sh from the fork pinned in core/vendor.lock. This
# script consumes only the already-built binary and starts no uxplay process
# of its own.
UXPLAY_BINARY="${APP_PATH:-$BUILD_DIR/MiragePlay.app}/Contents/Helpers/MiragePlay Projection.app/Contents/MacOS/uxplay"
if [ ! -x "$UXPLAY_BINARY" ]; then
  echo "ERROR: projection helper binary not found or not executable at $UXPLAY_BINARY" | tee -a "$LOG_FILE"
  echo "Please run: ./scripts/build/build-app.sh --out $(printf '%q' "$BUILD_DIR") --build-dir $(printf '%q' "$BUILD_DIR")" | tee -a "$LOG_FILE"
  exit 1
fi
echo "projection helper binary verified: $UXPLAY_BINARY" | tee -a "$LOG_FILE"

# Launch the app
echo "Launching MiragePlay..." | tee -a "$LOG_FILE"
if [ -n "$EXEC_PATH" ]; then
  # Raw swiftpm executable — run directly in background (menu bar app has no terminal)
  "$EXEC_PATH" >> "$LOG_FILE" 2>&1 &
  echo "Launched via exec: $EXEC_PATH (pid=$!)" | tee -a "$LOG_FILE"
else
  # .app bundle
  open -a "$APP_PATH" 2>&1 | tee -a "$LOG_FILE"
  echo "Launched via open: $APP_PATH" | tee -a "$LOG_FILE"
fi

# Wait for app to come up — receiver is NOT auto-started (Bonjour goes up only after start)
echo "Waiting 30s for app startup (receiver idle — no Bonjour broadcast yet)..." | tee -a "$LOG_FILE"
sleep 30

echo "=== App launched. Receiver idle — Bonjour broadcast starts after Start (menu bar icon). ===" | tee -a "$LOG_FILE"
echo "=== YC: click the menu bar icon, press Start, then connect iPhone via AirPlay. ===" | tee -a "$LOG_FILE"
echo "=== YC: observe for 10 minutes. ===" | tee -a "$LOG_FILE"

# Create smoke-data template
cat > "$SMOKE_DATA" << 'TEMPLATE'
# Smoke Test Data — MiragePlay Stage1

**Test date**:
**Device**: iPhone
**iOS version**:
**Test duration**: 10 minutes
**Symptoms**:
-
**Conclusion** (filled in by YC):
TEMPLATE

echo "Smoke data template written to: $SMOKE_DATA" | tee -a "$LOG_FILE"
echo "=== smoke.sh done ===" | tee -a "$LOG_FILE"
