#!/usr/bin/env bash
# Runs the real CCT client dev server against whatever worktree is bind-
# mounted at /workspace. This mirrors .mise/tasks/dev + its dependencies
# exactly (install:assets, the submodule package builds, then vite) rather
# than reinventing the build — if the mise tasks change, update this too.
set -e
cd /workspace

echo "[sandbox] Installing dependencies (pnpm install)..."
pnpm install --no-frozen-lockfile

echo "[sandbox] Setting up client assets..."
pnpm --filter client exec node scripts/copyAssets.mjs || echo "[sandbox] asset copy skipped (non-fatal)"

echo "[sandbox] Building workspace dependencies..."
pnpm --filter stoat.js build || echo "[sandbox] stoat.js build failed (non-fatal, continuing)"
pnpm --filter solid-livekit-components build || echo "[sandbox] solid-livekit-components build failed (non-fatal, continuing)"
pnpm --filter @lingui-solid/babel-plugin-lingui-macro build || true
pnpm --filter @lingui-solid/babel-plugin-extract-messages build || true

echo "[sandbox] Starting dev server on 0.0.0.0:${PORT:-5173}"
exec pnpm --filter client exec vite --host 0.0.0.0 --port "${PORT:-5173}"

