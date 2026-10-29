#!/bin/bash
# deps.sh — Install brew dependencies for mirrorboard
set -e

echo "Installing brew dependencies..."
# librsvg provides the rsvg-convert binary, required by
# scripts/build/make-appicon.sh on every appicon build (deps.lock:6).
brew install cmake openssl@3 libplist gstreamer librsvg

# Set openssl@3 flags for cmake
export CMAKE_PREFIX_PATH="/opt/homebrew/opt/openssl@3"

echo "deps.sh done."
