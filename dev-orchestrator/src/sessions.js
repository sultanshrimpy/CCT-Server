// sessions.js
// In-memory session registry. Sessions are ephemeral by design (a container +
// a worktree), so losing this state on an orchestrator restart just means
// existing sandboxes become orphaned — acceptable for a dev tool. If that
// ever becomes a problem, swap the Map for a Redis hash; nothing else here
// needs to change.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const config = require("./config");
const git = require("./git");
const docker = require("./docker");

const sessions = new Map(); // session_id -> session

function new_session_id() {
  return crypto.randomUUID();
}

function new_preview_token() {
  return crypto.randomBytes(16).toString("hex");
}

async function create_session(userId, username) {
  const session_id = new_session_id();
  const { branch, worktree_path } = await git.create_worktree(session_id, username);
  const { container_name } = await docker.start_sandbox(session_id, worktree_path);

  const session = {
    id: session_id,
    userId,
    username,
    branch,
    worktree_path,
    container_name,
    preview_token: new_preview_token(),
    created_at: Date.now(),
    last_activity: Date.now(),
  };
  sessions.set(session_id, session);
  return session;
}

async function destroy_session(session_id) {
  const session = sessions.get(session_id);
  if (!session) return;
  await docker.stop_sandbox(session_id);
  await git.remove_worktree(session.worktree_path);
  sessions.delete(session_id);
}

function get_session(session_id) {
  return sessions.get(session_id);
}

function list_sessions() {
  return Array.from(sessions.values());
}

function touch(session_id) {
  const session = sessions.get(session_id);
  if (session) session.last_activity = Date.now();
}

// Resolve a relative path within a session's worktree, refusing anything
// that would escape it (../.., absolute paths, symlink tricks are still a
// risk in theory but this is a trusted-developer tool, not a public
// multi-tenant sandbox).
function resolve_in_worktree(session, relative_path) {
  const target = path.resolve(session.worktree_path, "." + path.sep + relative_path);
  if (!target.startsWith(path.resolve(session.worktree_path) + path.sep) &&
      target !== path.resolve(session.worktree_path)) {
    throw new Error("Path escapes worktree");
  }
  return target;
}

const IGNORED_DIRS = new Set(["node_modules", ".git", "dist", ".pnpm-store"]);

function list_dir(session, relative_path = "") {
  const dir = resolve_in_worktree(session, relative_path);
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => !IGNORED_DIRS.has(entry.name))
    .map((entry) => ({
      name: entry.name,
      path: path.join(relative_path, entry.name),
      type: entry.isDirectory() ? "dir" : "file",
    }))
    .sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "dir" ? -1 : 1));
}

function read_file(session, relative_path) {
  const file = resolve_in_worktree(session, relative_path);
  return fs.readFileSync(file, "utf-8");
}

function write_file(session, relative_path, content) {
  const file = resolve_in_worktree(session, relative_path);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, "utf-8");
}

// Tears down any session that hasn't had a heartbeat/file-write in
// config.idle_timeout_ms. Call periodically from server.js.
async function reap_idle_sessions() {
  const now = Date.now();
  for (const session of sessions.values()) {
    if (now - session.last_activity > config.idle_timeout_ms) {
      console.log(`[sessions] Reaping idle session ${session.id} (${session.username})`);
      try {
        await destroy_session(session.id);
      } catch (e) {
        console.warn(`[sessions] Failed to reap ${session.id}:`, e.message);
      }
    }
  }
}

module.exports = {
  create_session, destroy_session, get_session, list_sessions, touch,
  list_dir, read_file, write_file, reap_idle_sessions,
};

