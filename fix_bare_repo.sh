#!/usr/bin/env bash
# fix_bare_repo.sh — fixes dev-orchestrator/src/git.js:
#   1. The bare-repo existence check used fs.existsSync() on a directory
#      that docker-compose's bind mount auto-creates as empty BEFORE the
#      container starts, so it always looked "already cloned" and skipped
#      straight to `git fetch` on what was actually just an empty folder.
#      Now checks for the HEAD file bare repos always have instead.
#   2. The initial clone never used the bot token, only the later push did
#      -- if your client repo is private, the clone would fail too. Now
#      authenticated the same way the push already was.
#
# Usage: STOAT_DIR=~/stoat ./fix_bare_repo.sh   (defaults to ~/stoat)

set -e
STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"
if [ ! -d "$STOAT_DIR" ]; then echo "STOAT_DIR not found: $STOAT_DIR"; exit 1; fi

echo "==> Writing dev-orchestrator/src/git.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/git.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/git.js" << 'CCTEOF_GITJS2'
// git.js
// Manages the persistent bare mirror + per-session git worktrees.
// Everything shells out to the real `git` CLI on purpose — it's the same
// commands you'd run by hand, so `git -C <path> status` etc. always works
// for debugging on the box directly.

const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");
const config = require("./config");

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { maxBuffer: 1024 * 1024 * 64, ...opts }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        return reject(err);
      }
      resolve({ stdout, stderr });
    });
  });
}

// Ensure the bare mirror exists and is up to date. Called before creating
// any new worktree so sessions always branch off current main.
//
// Note: the docker-compose bind mount for bare_repo_dir auto-creates it as
// an empty directory before this container even starts, so a plain
// fs.existsSync() check isn't enough to tell "not cloned yet" apart from
// "already a bare repo" — check for the HEAD file bare repos always have.
async function sync_bare_repo() {
  const is_real_bare_repo = fs.existsSync(config.bare_repo_dir) && fs.existsSync(path.join(config.bare_repo_dir, "HEAD"));

  if (!is_real_bare_repo) {
    console.log("[git] Bare mirror missing/empty, cloning fresh:", config.client_repo_url);
    fs.rmSync(config.bare_repo_dir, { recursive: true, force: true });
    fs.mkdirSync(path.dirname(config.bare_repo_dir), { recursive: true });
    const authed_url = config.client_repo_url.replace(
      "https://",
      `https://x-access-token:${config.github.token}@`
    );
    await run("git", ["clone", "--bare", authed_url, config.bare_repo_dir]);
  } else {
    console.log("[git] Fetching latest into bare mirror");
    await run("git", ["--git-dir", config.bare_repo_dir, "fetch", "--prune", "origin"]);
  }
}

function slugify(username) {
  return String(username).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "dev";
}

// Creates a new worktree on a fresh branch off origin/<client_repo_branch>,
// then initializes submodules inside it (stoat.js, solid-livekit-components,
// assets, js-lingui-solid — none of these are vendored, they're real
// submodules per .gitmodules).
async function create_worktree(session_id, username) {
  await sync_bare_repo();

  const branch = `dev/${slugify(username)}/${Date.now()}`;
  const worktree_path = path.join(config.workspaces_dir, session_id);

  fs.mkdirSync(config.workspaces_dir, { recursive: true });

  console.log(`[git] Creating worktree ${worktree_path} on branch ${branch}`);
  await run("git", [
    "--git-dir", config.bare_repo_dir,
    "worktree", "add", "-b", branch, worktree_path,
    `origin/${config.client_repo_branch}`,
  ]);

  console.log(`[git] Initializing submodules in ${worktree_path}`);
  await run("git", ["submodule", "update", "--init", "--recursive"], { cwd: worktree_path });

  return { branch, worktree_path };
}

async function remove_worktree(worktree_path) {
  try {
    await run("git", ["--git-dir", config.bare_repo_dir, "worktree", "remove", "--force", worktree_path]);
  } catch (e) {
    console.warn("[git] worktree remove failed, falling back to rm -rf:", e.message);
    fs.rmSync(worktree_path, { recursive: true, force: true });
    try {
      await run("git", ["--git-dir", config.bare_repo_dir, "worktree", "prune"]);
    } catch {}
  }
}

// Commits whatever's currently in the worktree and pushes the branch.
// Returns false if there was nothing to commit.
async function commit_and_push(worktree_path, branch, message) {
  await run("git", ["add", "-A"], { cwd: worktree_path });

  const status = await run("git", ["status", "--porcelain"], { cwd: worktree_path });
  if (!status.stdout.trim()) {
    return false;
  }

  await run("git", ["-c", "user.email=cct-dev-bot@cct.wtf", "-c", "user.name=CCT Dev Bot",
    "commit", "-m", message], { cwd: worktree_path });

  // Push using the bot token over HTTPS without ever writing it into the
  // worktree's git config (avoid the token ending up in a commit or log).
  const push_url = config.client_repo_url.replace(
    "https://",
    `https://x-access-token:${config.github.token}@`
  );
  await run("git", ["push", push_url, `HEAD:refs/heads/${branch}`], { cwd: worktree_path });

  return true;
}

module.exports = { sync_bare_repo, create_worktree, remove_worktree, commit_and_push, slugify };

CCTEOF_GITJS2

echo "==> Rebuilding + restarting dev-orchestrator..."
(cd "$STOAT_DIR" && docker compose up -d --build dev-orchestrator)

echo "==> Done. The bad empty bare-repo dir will be cleaned up automatically"
echo "    on the next session-create attempt -- no manual cleanup needed."
