// server.js
// Entry point for dev-orchestrator.
//
// Two trust zones:
//   1. /sessions* and /deploy — management endpoints. Require the shared
//      X-Internal-Secret header. Only docker/server.js (the admin panel,
//      which has already done real user auth + role checks) should ever
//      call these. Never expose this port publicly — see compose.yml, it
//      has no published port and no Caddy route to it directly.
//   2. /sandbox/:id/* — the live preview. This IS reached directly by a
//      developer's browser (as an <iframe> src), so it's public via Caddy,
//      but gated by the per-session preview token instead of the internal
//      secret. See proxy.js.

const express = require("express");
const config = require("./config");
const sessions = require("./sessions");
const github = require("./github");
const deploy = require("./deploy");
const proxy = require("./proxy");

const app = express();
app.use(express.json({ limit: "10mb" }));

function requireInternal(req, res, next) {
  if (req.headers["x-internal-secret"] !== config.internal_secret) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
}

// ─── Session lifecycle ─────────────────────────────────────────────────────

app.post("/sessions", requireInternal, async (req, res) => {
  const { userId, username } = req.body;
  if (!userId || !username) return res.status(400).json({ error: "userId and username required" });

  try {
    const session = await sessions.create_session(userId, username);
    res.json({
      id: session.id,
      branch: session.branch,
      preview_path: `/sandbox/${session.id}/?t=${session.preview_token}`,
      terminal_path: `/sandbox/${session.id}/__terminal?t=${session.preview_token}`,
      created_at: session.created_at,
    });
  } catch (e) {
    console.error("[server] Failed to create session:", e);
    res.status(500).json({ error: e.message, stderr: e.stderr });
  }
});

app.get("/sessions", requireInternal, (req, res) => {
  res.json(sessions.list_sessions().map((s) => ({
    id: s.id,
    userId: s.userId,
    username: s.username,
    branch: s.branch,
    created_at: s.created_at,
    last_activity: s.last_activity,
    preview_path: `/sandbox/${s.id}/?t=${s.preview_token}`,
    terminal_path: `/sandbox/${s.id}/__terminal?t=${s.preview_token}`,
  })));
});

app.delete("/sessions/:id", requireInternal, async (req, res) => {
  try {
    await sessions.destroy_session(req.params.id);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post("/sessions/:id/heartbeat", requireInternal, (req, res) => {
  sessions.touch(req.params.id);
  res.json({ ok: true });
});

// ─── File API (backs the Monaco/CodeMirror editor in the admin panel) ─────

app.get("/sessions/:id/files", requireInternal, (req, res) => {
  const session = sessions.get_session(req.params.id);
  if (!session) return res.status(404).json({ error: "Session not found" });
  try {
    res.json({ entries: sessions.list_dir(session, req.query.path || "") });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.get("/sessions/:id/file", requireInternal, (req, res) => {
  const session = sessions.get_session(req.params.id);
  if (!session) return res.status(404).json({ error: "Session not found" });
  if (!req.query.path) return res.status(400).json({ error: "path required" });
  try {
    res.json({ path: req.query.path, content: sessions.read_file(session, req.query.path) });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.put("/sessions/:id/file", requireInternal, (req, res) => {
  const session = sessions.get_session(req.params.id);
  if (!session) return res.status(404).json({ error: "Session not found" });
  const { path: rel_path, content } = req.body;
  if (!rel_path || content === undefined) return res.status(400).json({ error: "path and content required" });
  try {
    sessions.write_file(session, rel_path, content);
    sessions.touch(session.id);
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

// ─── GitHub submit ──────────────────────────────────────────────────────────

app.post("/sessions/:id/github-submit", requireInternal, async (req, res) => {
  const session = sessions.get_session(req.params.id);
  if (!session) return res.status(404).json({ error: "Session not found" });

  const git = require("./git");
  try {
    const pushed = await git.commit_and_push(
      session.worktree_path,
      session.branch,
      req.body.message || `Dev session changes from ${session.username}`
    );
    if (!pushed) {
      return res.json({ ok: true, pushed: false, message: "No changes to submit." });
    }

    const pr = await github.ensure_pull_request(session.branch, {
      title: req.body.title || `[dev] ${session.username}: ${session.branch}`,
      body: req.body.body || `Submitted from the CCT admin dev sandbox by **${session.username}**.\n\nSession: \`${session.id}\``,
    });

    res.json({ ok: true, pushed: true, pr_url: pr.html_url, pr_number: pr.number });
  } catch (e) {
    console.error("[server] github-submit failed:", e);
    res.status(500).json({ error: e.message });
  }
});

// ─── Production deploy — trusts that docker/server.js already verified the
// caller is the specific owner-allowlisted user before ever hitting this ──

app.post("/deploy", requireInternal, async (req, res) => {
  const { pull_number } = req.body;
  if (!pull_number) return res.status(400).json({ error: "pull_number required" });

  try {
    const log = await deploy.deploy_pull_request(pull_number);
    res.json({ ok: true, log });
  } catch (e) {
    console.error("[server] Deploy failed:", e);
    res.status(500).json({ error: e.message, log: e.log || [] });
  }
});

// ─── Live preview proxy (public, token-gated — see proxy.js) ──────────────

app.use("/sandbox/:id", (req, res) => proxy.handle_http(req, res));

// ─── Idle reaper ────────────────────────────────────────────────────────────

setInterval(() => {
  sessions.reap_idle_sessions().catch((e) => console.warn("[server] Reaper error:", e.message));
}, 5 * 60 * 1000);

const server = app.listen(config.port, () => {
  console.log(`[dev-orchestrator] Listening on port ${config.port}`);
});

// WebSocket upgrade (Vite HMR) — handled outside Express's request cycle
server.on("upgrade", (req, socket, head) => {
  if (req.url.startsWith("/sandbox/")) {
    proxy.handle_upgrade(req, socket, head);
  } else {
    socket.destroy();
  }
});

process.on("SIGTERM", () => {
  console.log("[dev-orchestrator] Shutting down");
  process.exit(0);
});

