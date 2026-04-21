#!/bin/bash
# update-server.sh
# Run this on your server to pull the latest stage-bridge from GitHub
# and rebuild the container.
#
# Usage:
#   bash update-server.sh
#
# Make it executable once with:
#   chmod +x update-server.sh

set -e  # exit immediately if any command fails

REPO="https://github.com/sultanshrimpy/friendly-broccoli.git"
STOAT_DIR="$HOME/stoat"
TMP_DIR="/tmp/friendly-broccoli-update"

# ── Clean up any leftover temp dir from a previous failed run ────────────────
if [ -d "$TMP_DIR" ]; then
  echo "[update] Cleaning up previous temp directory..."
  rm -rf "$TMP_DIR"
fi

# ── Pull stage-bridge from GitHub ────────────────────────────────────────────
echo "[update] Pulling latest stage-bridge from GitHub..."
git clone --no-checkout "$REPO" "$TMP_DIR"
cd "$TMP_DIR"
git sparse-checkout init --cone
git sparse-checkout set stage-bridge
git checkout main

# ── Copy into stoat directory ─────────────────────────────────────────────────
echo "[update] Copying stage-bridge to $STOAT_DIR..."
cp -r stage-bridge "$STOAT_DIR/stage-bridge"

# ── Clean up temp dir ────────────────────────────────────────────────────────
cd ~
rm -rf "$TMP_DIR"

# ── Rebuild and restart just the stage-bridge container ──────────────────────
echo "[update] Rebuilding stage-bridge container..."
cd "$STOAT_DIR"
docker compose up -d --build stage-bridge

echo ""
echo "[update] Done! stage-bridge is up to date."
echo "[update] Check logs with: docker compose logs -f stage-bridge"
