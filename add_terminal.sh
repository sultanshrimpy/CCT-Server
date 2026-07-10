#!/usr/bin/env bash
# add_terminal.sh — adds an in-browser terminal to the Dev Sandbox tab.
# Connects via websocket straight into the session's sandbox container
# (docker exec -it ... bash) using node-pty for a real interactive shell.
# Gated by the same per-session preview token the live-preview iframe
# already uses -- no new secrets or trust boundary.
#
# Usage: CLIENT_DIR=~/client STOAT_DIR=~/stoat ./add_terminal.sh
# (defaults to ~/client and ~/stoat)

set -e
CLIENT_DIR="${CLIENT_DIR:-$HOME/client}"
STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"
if [ ! -d "$CLIENT_DIR" ]; then echo "CLIENT_DIR not found: $CLIENT_DIR"; exit 1; fi
if [ ! -d "$STOAT_DIR" ]; then echo "STOAT_DIR not found: $STOAT_DIR"; exit 1; fi

echo "==> Writing files"

echo "  -> $STOAT_DIR/dev-orchestrator/package.json"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/package.json")"
cat > "$STOAT_DIR/dev-orchestrator/package.json" << 'CCTEOF_DOPKGJSON2'
{
  "name": "cct-dev-orchestrator",
  "version": "1.0.0",
  "private": true,
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "http-proxy": "^1.18.1",
    "node-pty": "^1.0.0",
    "ws": "^8.18.0"
  }
}

CCTEOF_DOPKGJSON2

echo "  -> $STOAT_DIR/dev-orchestrator/Dockerfile"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/Dockerfile")"
cat > "$STOAT_DIR/dev-orchestrator/Dockerfile" << 'CCTEOF_DODOCKERFILE2'
FROM node:20-bookworm-slim

# git — for worktree management
# docker CLI + compose plugin — this container talks to the host Docker
# daemon via the bind-mounted /var/run/docker.sock, it needs the client
# binaries to do so (this does NOT install/run a nested Docker daemon)
# python3/make/g++ — needed to compile node-pty's native bindings (used for
# the in-browser terminal feature)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl gnupg python3 make g++ \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

EXPOSE 8700
CMD ["node", "src/server.js"]

CCTEOF_DODOCKERFILE2

echo "  -> $STOAT_DIR/dev-orchestrator/src/proxy.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/proxy.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/proxy.js" << 'CCTEOF_DOPROXY2'
// proxy.js
// Proxies /sandbox/:sessionId/* (HTTP + WebSocket, the latter needed for
// Vite's HMR client AND the in-browser terminal) straight through to that
// session's container over the docker network, by container name — no host
// ports are published for sandbox containers at all, this proxy is the
// only way in.
//
// Auth here is the per-session preview_token (query param `t=`), not the
// admin JWT — the browser tab showing the live preview/terminal is either
// an <iframe> or a raw WebSocket, neither carries the admin panel's
// Authorization header, so this reuses the same token issued at session
// creation instead of inventing a second auth path.
//
// One special path is intercepted before reaching the vite proxy target:
// /sandbox/:id/__terminal — hands off to terminal.js instead of forwarding
// to the sandbox's dev server, since that's not a vite route at all.

const httpProxy = require("http-proxy");
const WebSocket = require("ws");
const sessions = require("./sessions");
const config = require("./config");
const terminal = require("./terminal");

const proxy = httpProxy.createProxyServer({ ws: true, changeOrigin: true });
const wss = new WebSocket.Server({ noServer: true });

proxy.on("error", (err, req, res) => {
  console.warn("[proxy] Error:", err.message);
  if (res && res.writeHead) {
    res.writeHead(502, { "Content-Type": "text/plain" });
    res.end("Sandbox preview unavailable (session may have ended).");
  }
});

const TERMINAL_PATH = "/__terminal";

function parse_session_path(url) {
  // /sandbox/<sessionId>/rest/of/path?query
  const match = url.match(/^\/sandbox\/([^/?]+)(\/.*)?$/);
  if (!match) return null;
  return { session_id: match[1], rest: match[2] || "/" };
}

function authorize(req, res) {
  const parsed = parse_session_path(req.url);
  if (!parsed) {
    res.writeHead(404).end();
    return null;
  }
  const session = sessions.get_session(parsed.session_id);
  if (!session) {
    res.writeHead(404, { "Content-Type": "text/plain" }).end("Sandbox session not found or expired.");
    return null;
  }
  const url = new URL(req.url, "http://internal");
  const token = url.searchParams.get("t");
  if (token !== session.preview_token) {
    res.writeHead(403, { "Content-Type": "text/plain" }).end("Invalid preview token.");
    return null;
  }
  sessions.touch(session.id);
  return { session, rest: parsed.rest + url.search.replace(/([?&])t=[^&]*&?/, "$1").replace(/[?&]$/, "") };
}

function handle_http(req, res) {
  const result = authorize(req, res);
  if (!result) return;
  const { session, rest } = result;
  req.url = rest;
  proxy.web(req, res, { target: `http://${session.container_name}:${config.sandbox.port}` });
}

function handle_upgrade(req, socket, head) {
  const parsed = parse_session_path(req.url);
  if (!parsed) return socket.destroy();
  const session = sessions.get_session(parsed.session_id);
  if (!session) return socket.destroy();

  const url = new URL(req.url, "http://internal");
  if (url.searchParams.get("t") !== session.preview_token) return socket.destroy();

  sessions.touch(session.id);

  if (parsed.rest.split("?")[0] === TERMINAL_PATH) {
    wss.handleUpgrade(req, socket, head, (ws) => terminal.attach_terminal(ws, session));
    return;
  }

  req.url = parsed.rest;
  proxy.ws(req, socket, head, { target: `http://${session.container_name}:${config.sandbox.port}` });
}

module.exports = { handle_http, handle_upgrade };

CCTEOF_DOPROXY2

echo "  -> $STOAT_DIR/dev-orchestrator/src/server.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/server.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/server.js" << 'CCTEOF_DOSERVER2'
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

CCTEOF_DOSERVER2

echo "  -> $STOAT_DIR/dev-orchestrator/src/terminal.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/terminal.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/terminal.js" << 'CCTEOF_DOTERMINAL'
// terminal.js
// Gives an in-browser terminal a real shell inside a session's sandbox
// container. Uses node-pty (not a plain pipe) so the shell behaves like a
// real terminal — colors, cursor control, resizing, interactive programs
// all work, since node-pty allocates an actual pseudo-tty locally and
// `docker exec -it` allocates the matching one inside the container.
//
// Wire protocol over the websocket (both directions), JSON text frames:
//   { type: "data", data: "<bytes as string>" }   — terminal I/O
//   { type: "resize", cols, rows }                 — sent by the client
//     when the browser terminal element resizes

const pty = require("node-pty");

function attach_terminal(ws, session) {
  console.log(`[terminal] Opening shell in ${session.container_name}`);

  const shell = pty.spawn("docker", ["exec", "-it", session.container_name, "bash"], {
    name: "xterm-256color",
    cols: 80,
    rows: 24,
    cwd: process.cwd(),
    env: process.env,
  });

  shell.onData((data) => {
    if (ws.readyState === ws.OPEN) {
      ws.send(JSON.stringify({ type: "data", data }));
    }
  });

  shell.onExit(({ exitCode }) => {
    console.log(`[terminal] Shell in ${session.container_name} exited (${exitCode})`);
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg.type === "data") {
      shell.write(msg.data);
    } else if (msg.type === "resize" && msg.cols > 0 && msg.rows > 0) {
      try {
        shell.resize(msg.cols, msg.rows);
      } catch (e) {
        console.warn("[terminal] resize failed:", e.message);
      }
    }
  });

  ws.on("close", () => {
    try {
      shell.kill();
    } catch {}
  });

  ws.on("error", (e) => {
    console.warn("[terminal] websocket error:", e.message);
    try {
      shell.kill();
    } catch {}
  });
}

module.exports = { attach_terminal };

CCTEOF_DOTERMINAL

echo "  -> $CLIENT_DIR/docker/admin/index.html"
mkdir -p "$(dirname "$CLIENT_DIR/docker/admin/index.html")"
cat > "$CLIENT_DIR/docker/admin/index.html" << 'CCTEOF_ADMININDEX2'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>CCT Admin Panel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.8.0/dist/tabler-icons.min.css"/>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.5.0/css/xterm.min.css"/>
<script src="https://cdn.jsdelivr.net/npm/localforage@1.10.0/dist/localforage.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm@5.5.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.10.0/lib/xterm-addon-fit.min.js"></script>
<style>
:root{--bg:#1a1a18;--surface:#232320;--surface2:#2b2b28;--surface3:#343430;--border:rgba(255,255,255,0.07);--border2:rgba(255,255,255,0.13);--text:#e8e4d8;--text2:#9a9488;--text3:#5a5650;--gold:#c9b878;--gold2:#a8975a;--gold3:#7a6e42;--orange:#d4742a;--green:#7ab87a;--amber:#c8a040;--red:#c85050;--blue:#5880c8;--purple:#8870b8;}
*{box-sizing:border-box;margin:0;padding:0;}
html,body{height:100%;background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;}
.shell{display:flex;height:100vh;background:var(--bg);}
.sidebar{width:215px;flex-shrink:0;background:var(--surface);border-right:1px solid var(--border);display:flex;flex-direction:column;}
.brand{padding:14px 14px 12px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;}
.brand-logo{width:36px;height:36px;border-radius:50%;border:2px solid var(--gold3);background:#2a2820;display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:10px;font-weight:900;color:var(--gold);letter-spacing:-.5px;}
.brand-name{font-size:13px;font-weight:600;color:var(--gold);letter-spacing:.04em;}
.brand-sub{font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:.06em;}
.nav-sec{padding:10px 8px 2px;}
.nav-lbl{font-size:10px;font-weight:600;color:var(--text3);text-transform:uppercase;letter-spacing:.08em;padding:0 8px 5px;}
.ni{display:flex;align-items:center;gap:8px;padding:7px 10px;border-radius:7px;cursor:pointer;color:var(--text2);font-size:13px;transition:background .1s,color .1s;user-select:none;}
.ni:hover{background:var(--surface2);color:var(--text);}
.ni.active{background:rgba(201,184,120,0.1);color:var(--gold);}
.ni i{font-size:16px;flex-shrink:0;}
.ni .ct{margin-left:auto;font-size:11px;background:var(--surface3);color:var(--text2);border-radius:10px;padding:1px 7px;}
.ni.active .ct{background:rgba(201,184,120,0.18);color:var(--gold);}
.ni.alert .ct{background:rgba(200,80,80,0.18);color:var(--red);}
.sf{margin-top:auto;padding:10px 8px;border-top:1px solid var(--border);}
.main{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0;}
.topbar{height:48px;background:var(--surface);border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 18px;gap:10px;flex-shrink:0;}
.tb-title{font-size:14px;font-weight:600;color:var(--text);}
.tb-sub{font-size:11px;color:var(--text3);}
.tb-act{margin-left:auto;display:flex;gap:7px;align-items:center;}
.btn{display:inline-flex;align-items:center;gap:5px;padding:5px 12px;border-radius:7px;font-size:12px;cursor:pointer;font-weight:500;border:none;transition:opacity .15s,transform .1s;font-family:inherit;}
.btn:active{transform:scale(.97);}
.btn-gold{background:var(--gold2);color:#1a1a18;}
.btn-gold:hover{opacity:.88;}
.btn-ghost{background:var(--surface2);color:var(--text2);border:1px solid var(--border);}
.btn-ghost:hover{background:var(--surface3);color:var(--text);}
.btn-danger{background:rgba(200,80,80,0.13);color:var(--red);border:1px solid rgba(200,80,80,0.22);}
.btn-danger:hover{background:rgba(200,80,80,0.22);}
.btn-sm{padding:3px 9px;font-size:11px;}
.content{flex:1;overflow-y:auto;padding:16px;}
.content::-webkit-scrollbar{width:5px;}
.content::-webkit-scrollbar-thumb{background:var(--surface3);border-radius:4px;}
.page{display:none;}
.page.active{display:block;}
.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-bottom:16px;}
.sc{background:var(--surface);border:1px solid var(--border);border-radius:9px;padding:12px 14px;}
.sc-lbl{font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;}
.sc-val{font-size:24px;font-weight:600;color:var(--text);line-height:1;}
.sc-sub{font-size:11px;color:var(--text3);margin-top:3px;}
.dot{display:inline-block;width:6px;height:6px;border-radius:50%;margin-right:4px;}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:9px;margin-bottom:14px;}
.ph{padding:12px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:8px;}
.pt{font-size:13px;font-weight:600;color:var(--text);}
.pa{margin-left:auto;display:flex;gap:7px;align-items:center;}
.sb{display:flex;align-items:center;gap:8px;padding:9px 14px;border-bottom:1px solid var(--border);}
.sb i{color:var(--text3);font-size:15px;}
.sb input{background:none;border:none;outline:none;color:var(--text);font-size:13px;flex:1;font-family:inherit;}
.sb input::placeholder{color:var(--text3);}
table{width:100%;border-collapse:collapse;table-layout:fixed;}
th{font-size:10px;font-weight:600;color:var(--text3);text-transform:uppercase;letter-spacing:.06em;padding:7px 14px;text-align:left;border-bottom:1px solid var(--border);}
td{padding:9px 14px;border-bottom:1px solid var(--border);color:var(--text);font-size:12.5px;vertical-align:middle;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
tr:last-child td{border-bottom:none;}
tr:hover td{background:rgba(255,255,255,0.02);}
.av{width:26px;height:26px;border-radius:50%;display:inline-flex;align-items:center;justify-content:center;font-size:10px;font-weight:600;flex-shrink:0;}
.uc{display:flex;align-items:center;gap:8px;}
.un{font-weight:500;font-size:13px;}
.uh{font-size:11px;color:var(--text3);}
.pill{display:inline-flex;align-items:center;gap:3px;padding:2px 8px;border-radius:20px;font-size:10px;font-weight:500;}
.p-gold{background:rgba(201,184,120,0.13);color:var(--gold);}
.p-blue{background:rgba(88,128,200,0.13);color:var(--blue);}
.p-green{background:rgba(122,184,122,0.13);color:var(--green);}
.p-amber{background:rgba(200,160,64,0.13);color:var(--amber);}
.p-red{background:rgba(200,80,80,0.13);color:var(--red);}
.p-gray{background:rgba(255,255,255,0.06);color:var(--text3);}
.ab{background:none;border:none;color:var(--text3);cursor:pointer;padding:3px 5px;border-radius:5px;font-size:14px;transition:background .1s,color .1s;font-family:inherit;}
.ab:hover{background:var(--surface2);color:var(--text);}
.ab.d:hover{background:rgba(200,80,80,0.12);color:var(--red);}
.field{margin-bottom:12px;}
.field label{font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:.06em;display:block;margin-bottom:5px;}
.field input,.field select,.field textarea{width:100%;background:var(--bg);border:1px solid var(--border2);border-radius:7px;padding:8px 10px;color:var(--text);font-size:13px;outline:none;font-family:inherit;transition:border-color .15s;}
.field input:focus,.field select:focus,.field textarea:focus{border-color:var(--gold2);}
.field select{appearance:none;cursor:pointer;}
.field textarea{resize:vertical;min-height:80px;}
.tog{position:relative;width:34px;height:18px;flex-shrink:0;}
.tog input{opacity:0;width:0;height:0;}
.tog-t{position:absolute;inset:0;background:var(--surface3);border-radius:20px;cursor:pointer;transition:background .2s;}
.tog input:checked+.tog-t{background:var(--gold2);}
.tog-t::after{content:'';position:absolute;width:12px;height:12px;border-radius:50%;background:#fff;top:3px;left:3px;transition:transform .2s;}
.tog input:checked+.tog-t::after{transform:translateX(16px);}
.sr{display:flex;align-items:center;padding:12px 14px;border-bottom:1px solid var(--border);}
.sr:last-child{border-bottom:none;}
.si{flex:1;}
.sn{font-size:13px;font-weight:500;color:var(--text);margin-bottom:2px;}
.sd{font-size:11px;color:var(--text3);}
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;z-index:50;}
.modal{background:var(--surface);border:1px solid var(--border2);border-radius:11px;padding:22px;width:400px;max-width:90vw;}
.modal h3{font-size:14px;font-weight:600;color:var(--text);margin-bottom:14px;}
.modal-acts{display:flex;gap:8px;margin-top:16px;justify-content:flex-end;}
.logline{font-family:'Consolas',monospace;font-size:11px;padding:2px 14px;line-height:1.7;color:var(--text2);}
.logline:hover{background:rgba(255,255,255,0.02);}
.lts{color:var(--text3);margin-right:8px;}
.li{color:var(--blue);}
.lw{color:var(--amber);}
.le{color:var(--red);}
.lo{color:var(--green);}
.snd-card{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;display:flex;align-items:center;gap:10px;margin-bottom:8px;}
.snd-icon{width:32px;height:32px;border-radius:7px;background:rgba(201,184,120,0.1);display:flex;align-items:center;justify-content:center;flex-shrink:0;color:var(--gold);font-size:16px;}
.snd-info{flex:1;min-width:0;}
.snd-name{font-size:13px;font-weight:500;color:var(--text);}
.snd-meta{font-size:11px;color:var(--text3);}
.drop-zone{border:1px dashed var(--border2);border-radius:9px;padding:28px;text-align:center;color:var(--text3);font-size:13px;cursor:pointer;transition:border-color .15s,background .15s;margin-bottom:12px;}
.drop-zone:hover,.drop-zone.drag{border-color:var(--gold2);background:rgba(201,184,120,0.05);color:var(--gold2);}
.mongo-row{font-family:'Consolas',monospace;font-size:11px;padding:5px 14px;border-bottom:1px solid var(--border);color:var(--text2);}
.mongo-row:last-child{border-bottom:none;}
.mk{color:var(--gold2);}
.mv{color:var(--green);}
.ms{color:var(--text3);}
.lk-room{padding:10px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;}
.lk-room:last-child{border-bottom:none;}
.lk-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;}
.files-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:8px;padding:14px;}
.file-card{background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:10px 8px;text-align:center;cursor:pointer;transition:border-color .15s;}
.file-card:hover{border-color:var(--gold3);}
.file-card i{font-size:22px;color:var(--text3);display:block;margin-bottom:5px;}
.file-card .fn{font-size:10px;color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.file-card .fs{font-size:10px;color:var(--text3);}
.login-screen{position:fixed;inset:0;background:var(--bg);display:flex;align-items:center;justify-content:center;z-index:100;}
.login-card{background:var(--surface);border:1px solid var(--border2);border-radius:13px;padding:32px 28px;width:320px;}
.login-logo{display:flex;align-items:center;gap:12px;margin-bottom:24px;}
.login-logom{width:44px;height:44px;border-radius:50%;border:2px solid var(--gold3);background:#2a2820;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:900;color:var(--gold);}
.li-err{font-size:11px;color:var(--red);margin-bottom:8px;display:none;}
.li-btn{width:100%;background:var(--gold2);color:#1a1a18;border:none;border-radius:7px;padding:10px;font-size:14px;font-weight:600;cursor:pointer;margin-top:6px;transition:opacity .15s;font-family:inherit;}
.li-btn:hover{opacity:.88;}
.tab-bar{display:flex;border-bottom:1px solid var(--border);}
.tab{padding:8px 14px;font-size:12px;color:var(--text2);cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-1px;transition:color .1s,border-color .1s;}
.tab.active{color:var(--gold);border-color:var(--gold);}
.tab:hover:not(.active){color:var(--text);}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid var(--border2);border-top-color:var(--gold);border-radius:50%;animation:spin .6s linear infinite;vertical-align:middle;}
@keyframes spin{to{transform:rotate(360deg);}}
.err-banner{background:rgba(200,80,80,0.1);border:1px solid rgba(200,80,80,0.25);border-radius:7px;padding:8px 12px;font-size:12px;color:var(--red);margin-bottom:10px;}
</style>
</head>
<body>

<div class="login-screen" id="LS">
  <div class="login-card">
    <div class="login-logo">
      <div class="login-logom">CCT</div>
      <div>
        <div style="font-size:16px;font-weight:700;color:var(--gold);">CCT Admin</div>
        <div style="font-size:11px;color:var(--text3);">Chaos Cult Tacticians</div>
      </div>
    </div>
    <div class="field"><label>Username</label><input type="text" id="lu" placeholder="admin" /></div>
    <div class="field"><label>Password</label><input type="password" id="lp" placeholder="••••••••" /></div>
    <div class="li-err" id="le">Invalid credentials.</div>
    <button class="li-btn" id="liBtn" onclick="doLogin()">Sign in</button>
    <div style="margin-top:10px;text-align:center;">
      <span style="font-size:11px;color:var(--text3);">— or —</span>
    </div>
    <button class="li-btn" id="sessionBtn" onclick="doSessionLogin()" style="margin-top:8px;background:rgba(201,184,120,0.13);color:var(--gold);border:1px solid rgba(201,184,120,0.25);">
      <i class="ti ti-shield-check" style="vertical-align:middle;margin-right:5px;"></i>Use current CCT session
    </button>
    <div style="font-size:10px;color:var(--text3);text-align:center;margin-top:6px;">Logs you in using your active CCT account (must be a promoted admin)</div>
  </div>
</div>

<div class="shell" id="MS" style="display:none;">
  <div class="sidebar">
    <div class="brand">
      <div class="brand-logo">CCT</div>
      <div>
        <div class="brand-name">CCT Admin</div>
        <div class="brand-sub">stoat.local/admin</div>
      </div>
    </div>
    <div class="nav-sec">
      <div class="nav-lbl">Overview</div>
      <div class="ni active" onclick="nav(this,'pgDash')"><i class="ti ti-layout-dashboard"></i> Dashboard</div>
    </div>
    <div class="nav-sec">
      <div class="nav-lbl">Manage</div>
      <div class="ni" onclick="nav(this,'pgUsers')"><i class="ti ti-users"></i> Users <span class="ct" id="siUsers">—</span></div>
      <div class="ni" onclick="nav(this,'pgServers')"><i class="ti ti-server-2"></i> Servers <span class="ct" id="siServers">—</span></div>
      <div class="ni" onclick="nav(this,'pgMotd')"><i class="ti ti-speakerphone"></i> Msg of Day</div>
      <div class="ni" onclick="nav(this,'pgSounds')"><i class="ti ti-volume"></i> Sounds</div>
      <div class="ni alert" onclick="nav(this,'pgReports')"><i class="ti ti-flag"></i> Reports <span class="ct" id="siReports">—</span></div>
    </div>
    <div class="nav-sec">
      <div class="nav-lbl">Backend</div>
      <div class="ni" onclick="nav(this,'pgMongo')"><i class="ti ti-database"></i> MongoDB</div>
      <div class="ni" onclick="nav(this,'pgLiveKit')"><i class="ti ti-radio"></i> LiveKit</div>
      <div class="ni" onclick="nav(this,'pgFiles')"><i class="ti ti-folder"></i> Media storage</div>
    </div>
    <div class="nav-sec">
      <div class="nav-lbl">System</div>
      <div class="ni" onclick="nav(this,'pgLogs')"><i class="ti ti-terminal-2"></i> Logs</div>
      <div class="ni" onclick="nav(this,'pgSettings')"><i class="ti ti-settings"></i> Settings</div>
    </div>
    <div class="nav-sec" id="devNavSec" style="display:none;">
      <div class="nav-lbl">Development</div>
      <div class="ni" onclick="nav(this,'pgDev')"><i class="ti ti-code"></i> Dev Sandbox</div>
    </div>
    <div class="sf">
      <div class="ni" style="color:var(--red)" onclick="doLogout()"><i class="ti ti-logout"></i> Sign out</div>
    </div>
  </div>

  <div class="main">
    <div class="topbar">
      <span class="tb-title" id="ttl">Dashboard</span>
      <span class="tb-sub">· chaos cult tacticians</span>
      <div class="tb-act" id="tbAct"></div>
    </div>
    <div class="content">

      <div class="page active" id="pgDash">
        <div class="stats">
          <div class="sc"><div class="sc-lbl">Users</div><div class="sc-val" id="dUsers">—</div><div class="sc-sub"><span class="dot" style="background:var(--green)"></span>online now</div></div>
          <div class="sc"><div class="sc-lbl">Servers</div><div class="sc-val" id="dServers">—</div><div class="sc-sub">total</div></div>
          <div class="sc"><div class="sc-lbl">Messages</div><div class="sc-val" id="dMessages">—</div><div class="sc-sub">all time</div></div>
          <div class="sc"><div class="sc-lbl">Reports</div><div class="sc-val" id="dReports" style="color:var(--red)">—</div><div class="sc-sub">open</div></div>
        </div>
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-speakerphone"></i> &nbsp;Current MOTD</span><span class="pa"><button class="btn btn-ghost btn-sm" onclick="nav(document.querySelector('[onclick*=pgMotd]'),\'pgMotd\')">Edit</button></span></div>
          <div style="padding:12px 14px;font-size:13px;color:var(--text2);font-style:italic;" id="dashMotd">Loading...</div>
        </div>
      </div>

      <div class="page" id="pgUsers">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-users"></i> &nbsp;Users</span><span class="pa"><button class="btn btn-gold btn-sm" onclick="openNewUser()"><i class="ti ti-plus"></i> New user</button></span></div>
          <div class="sb"><i class="ti ti-search"></i><input type="text" placeholder="Search users..." onkeyup="filterUsers(this.value)"/></div>
          <div style="overflow-x:auto;">
            <table>
              <thead><tr><th style="width:34%">User</th><th style="width:13%">Role</th><th style="width:15%">Status</th><th style="width:18%">Joined</th><th style="width:20%">Actions</th></tr></thead>
              <tbody id="uBody"><tr><td colspan="5" style="text-align:center;color:var(--text3);padding:20px;"><span class="spinner"></span> Loading...</td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="page" id="pgServers">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-server-2"></i> &nbsp;Servers</span></div>
          <div style="overflow-x:auto;">
            <table>
              <thead><tr><th style="width:30%">Server</th><th style="width:18%">Owner</th><th style="width:12%">Members</th><th style="width:12%">Channels</th><th style="width:14%">Created</th><th style="width:14%">Actions</th></tr></thead>
              <tbody id="sBody"><tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;"><span class="spinner"></span> Loading...</td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="page" id="pgMotd">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-speakerphone"></i> &nbsp;Message of the Day</span></div>
          <div style="padding:14px;">
            <div class="field"><label>MOTD text</label><textarea id="motdTxt" oninput="document.getElementById('motdPrev').textContent=this.value"></textarea></div>
            <div style="display:flex;gap:8px;align-items:center;">
              <button class="btn btn-gold" onclick="saveMotd()"><i class="ti ti-check"></i> Save &amp; publish</button>
              <span id="motdOk" style="font-size:12px;color:var(--green);display:none;"><i class="ti ti-check"></i> Published</span>
            </div>
            <div style="background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px 12px;display:flex;gap:9px;margin-top:14px;">
              <i class="ti ti-speakerphone" style="color:var(--gold);font-size:17px;margin-top:1px;"></i>
              <div><div style="font-size:10px;color:var(--text3);margin-bottom:3px;text-transform:uppercase;letter-spacing:.06em;">Preview</div><div style="font-size:13px;color:var(--text2);" id="motdPrev"></div></div>
            </div>
          </div>
        </div>
      </div>

      <div class="page" id="pgSounds">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-volume"></i> &nbsp;Notification sounds</span><span class="pa"><button class="btn btn-gold btn-sm" onclick="openUploadSound()"><i class="ti ti-upload"></i> Upload sound</button></span></div>
          <div style="padding:14px;">
            <div style="font-size:11px;color:var(--text3);margin-bottom:12px;padding:8px 10px;background:rgba(201,184,120,0.07);border:1px solid rgba(201,184,120,0.15);border-radius:7px;"><i class="ti ti-info-circle"></i> &nbsp;Sounds are served from <code style="color:var(--gold2)">/sounds/</code> and fetched at runtime from <code style="color:var(--gold2)">/api/config/sounds</code> — no rebuild required.</div>
            <div id="soundList"><span class="spinner"></span> Loading...</div>
          </div>
        </div>
      </div>

      <div class="page" id="pgReports">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-flag"></i> &nbsp;Reports</span></div>
          <div style="overflow-x:auto;">
            <table>
              <thead><tr><th style="width:16%">Reporter</th><th style="width:18%">Target</th><th style="width:22%">Reason</th><th style="width:16%">Date</th><th style="width:14%">Status</th><th style="width:14%">Actions</th></tr></thead>
              <tbody id="repBody"><tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;"><span class="spinner"></span> Loading...</td></tr></tbody>
            </table>
          </div>
        </div>
      </div>

      <div class="page" id="pgMongo">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-database"></i> &nbsp;MongoDB browser</span><span class="pa">
            <select id="mongoCol" onchange="loadMongo()" style="background:var(--bg);border:1px solid var(--border2);border-radius:6px;padding:4px 8px;color:var(--text);font-size:12px;outline:none;font-family:inherit;">
              <option>users</option><option>servers</option><option>channels</option><option>messages</option><option>sessions</option><option>reports</option>
            </select>
            <button class="btn btn-ghost btn-sm" onclick="loadMongo()"><i class="ti ti-refresh"></i> Refresh</button>
          </span></div>
          <div class="sb"><i class="ti ti-search"></i><input type="text" id="mongoFilter" placeholder='Filter by field value...' onkeyup="mongoFilterRows(this.value)"/></div>
          <div style="max-height:320px;overflow-y:auto;" id="mongoBody"><div style="padding:20px;text-align:center;color:var(--text3);"><span class="spinner"></span> Loading...</div></div>
          <div style="padding:8px 14px;border-top:1px solid var(--border);display:flex;align-items:center;">
            <span style="font-size:11px;color:var(--text3);" id="mongoCount"></span>
            <div style="margin-left:auto;display:flex;gap:6px;">
              <button class="btn btn-ghost btn-sm" onclick="mongoPage(-1)"><i class="ti ti-chevron-left"></i></button>
              <button class="btn btn-ghost btn-sm" onclick="mongoPage(1)"><i class="ti ti-chevron-right"></i></button>
            </div>
          </div>
        </div>
      </div>

      <div class="page" id="pgLiveKit">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-radio"></i> &nbsp;LiveKit rooms</span><span class="pa"><button class="btn btn-ghost btn-sm" onclick="loadLK()"><i class="ti ti-refresh"></i> Refresh</button></span></div>
          <div id="lkBody"><div style="padding:20px;text-align:center;color:var(--text3);">Connect LiveKit API key via Settings to manage rooms.</div></div>
        </div>
        <div class="panel">
          <div class="ph"><span class="pt">LiveKit connection</span></div>
          <div class="sr"><div class="si"><div class="sn">LiveKit URL</div><div class="sd" id="lkUrl">—</div></div></div>
          <div class="sr"><div class="si"><div class="sn">API Key</div></div><input id="lkKey" style="background:var(--bg);border:1px solid var(--border2);border-radius:6px;padding:5px 9px;color:var(--text);font-size:12px;outline:none;width:200px;font-family:inherit;" placeholder="devkey" /></div>
        </div>
      </div>

      <div class="page" id="pgFiles">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-folder"></i> &nbsp;Media storage</span></div>
          <div class="tab-bar">
            <div class="tab active" onclick="fileTab('sounds',this)">Sounds</div>
          </div>
          <div class="files-grid" id="filesGrid"><div style="padding:20px;color:var(--text3);"><span class="spinner"></span> Loading...</div></div>
        </div>
      </div>

      <div class="page" id="pgLogs">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-terminal-2"></i> &nbsp;System logs</span><span class="pa">
            <button class="btn btn-ghost btn-sm" onclick="filterLog('all',this)">All</button>
            <button class="btn btn-ghost btn-sm" onclick="filterLog('i',this)">Info</button>
            <button class="btn btn-ghost btn-sm" onclick="filterLog('w',this)">Warn</button>
            <button class="btn btn-ghost btn-sm" onclick="filterLog('e',this)">Error</button>
          </span></div>
          <div style="background:var(--bg);border-radius:0 0 9px 9px;padding:6px 0;" id="logBody"></div>
        </div>
      </div>

      <div class="page" id="pgSettings">
        <div class="panel">
          <div class="ph"><span class="pt"><i class="ti ti-settings"></i> &nbsp;Instance settings</span><span class="pa"><button class="btn btn-gold btn-sm" onclick="saveSettings()"><i class="ti ti-check"></i> Save</button></span></div>
          <div id="settingsBody"><div style="padding:20px;text-align:center;color:var(--text3);"><span class="spinner"></span> Loading...</div></div>
        </div>
      </div>

      <div class="page" id="pgDev">
        <div class="panel">
          <div class="ph">
            <span class="pt"><i class="ti ti-code"></i> &nbsp;Dev sandbox sessions</span>
            <span class="pa">
              <button class="btn btn-gold btn-sm" onclick="createDevSession()" id="devNewBtn"><i class="ti ti-plus"></i> New session</button>
            </span>
          </div>
          <div id="devSessionList"><div style="padding:20px;text-align:center;color:var(--text3);">No active sessions.</div></div>
        </div>

        <div class="panel" id="devWorkspace" style="display:none;">
          <div class="ph">
            <span class="pt"><i class="ti ti-git-branch"></i> &nbsp;<span id="devBranchName"></span></span>
            <span class="pa">
              <button class="btn btn-ghost btn-sm" onclick="devSaveFile()"><i class="ti ti-device-floppy"></i> Save file</button>
              <button class="btn btn-ghost btn-sm" onclick="devSubmitToGithub()"><i class="ti ti-brand-github"></i> Submit to GitHub</button>
              <button class="btn btn-ghost btn-sm" id="devDeployBtn" style="display:none;" onclick="devOpenDeployModal()"><i class="ti ti-rocket"></i> Deploy to Production</button>
              <button class="btn btn-danger btn-sm" onclick="devEndSession()"><i class="ti ti-square-x"></i> End session</button>
            </span>
          </div>
          <div style="display:flex;gap:4px;padding:8px 10px 0;border-top:1px solid var(--border);">
            <div class="ni" id="devTabFiles" style="width:auto;display:inline-flex;padding:5px 12px;" onclick="devSwitchTab('files')"><i class="ti ti-folder"></i> Files</div>
            <div class="ni" id="devTabTerminal" style="width:auto;display:inline-flex;padding:5px 12px;" onclick="devSwitchTab('terminal')"><i class="ti ti-terminal-2"></i> Terminal</div>
          </div>
          <div style="display:flex;height:560px;border-top:1px solid var(--border);">
            <div style="flex:1;display:flex;min-width:0;" id="devFilesView">
              <div style="width:200px;flex-shrink:0;overflow-y:auto;border-right:1px solid var(--border);padding:8px;" id="devFileTree"></div>
              <div style="flex:1;display:flex;flex-direction:column;min-width:0;">
                <div style="padding:6px 10px;font-size:11px;color:var(--text3);border-bottom:1px solid var(--border);font-family:'Consolas',monospace;" id="devCurrentFile">Select a file to edit</div>
                <textarea id="devEditor" style="flex:1;width:100%;background:var(--bg);color:var(--text);border:none;outline:none;font-family:'Consolas',monospace;font-size:12.5px;padding:10px;resize:none;" spellcheck="false" placeholder="Select a file from the tree to start editing..."></textarea>
              </div>
            </div>
            <div style="flex:1;display:none;min-width:0;padding:10px;background:#000;" id="devTerminalView">
              <div id="devTerminalEl" style="width:100%;height:100%;"></div>
            </div>
            <div style="width:340px;flex-shrink:0;border-left:1px solid var(--border);display:flex;flex-direction:column;">
              <div style="padding:6px 10px;font-size:11px;color:var(--text3);border-bottom:1px solid var(--border);">Live preview <span style="color:var(--text2);" id="devPreviewHint"></span></div>
              <iframe id="devPreviewFrame" style="flex:1;border:none;background:#fff;"></iframe>
            </div>
          </div>
        </div>
      </div>

    </div>
  </div>
</div>

<div class="modal-overlay" id="MO" style="display:none;">
  <div class="modal">
    <h3 id="mTitle"></h3>
    <div id="mContent"></div>
    <div class="modal-acts" id="mActs"></div>
  </div>
</div>

<div id="toast" style="position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--surface3);color:var(--text);padding:7px 18px;border-radius:7px;font-size:12px;z-index:200;border:1px solid var(--border2);opacity:0;transition:opacity .3s;white-space:nowrap;pointer-events:none;"></div>

<script>
let TOKEN = localStorage.getItem('cct_admin_token') || '';
let mongoPage_ = 0;
let allUsers = [];

async function api(method, path, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN } };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch('/api/admin' + path, opts);
  if (r.status === 401) { doLogout(); return null; }
  return r.ok ? r.json() : null;
}

async function doLogin() {
  const u = document.getElementById('lu').value, p = document.getElementById('lp').value;
  const err = document.getElementById('le'), btn = document.getElementById('liBtn');
  if (!u || !p) return;
  btn.innerHTML = '<span class="spinner"></span>';
  btn.disabled = true;
  try {
    const r = await fetch('/api/admin/login', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({username:u, password:p}) });
    const d = await r.json();
    if (r.ok && d.token) {
      TOKEN = d.token;
      localStorage.setItem('cct_admin_token', TOKEN);
      err.style.display = 'none';
      document.getElementById('LS').style.display = 'none';
      document.getElementById('MS').style.display = 'flex';
      initPanel();
    } else {
      err.textContent = d.error || 'Login failed.';
      err.style.display = 'block';
    }
  } catch(e) { err.textContent = 'Server unreachable.'; err.style.display = 'block'; }
  btn.innerHTML = 'Sign in'; btn.disabled = false;
}

function doLogout() {
  TOKEN = ''; localStorage.removeItem('cct_admin_token');
  document.getElementById('MS').style.display = 'none';
  document.getElementById('LS').style.display = 'flex';
}

document.addEventListener('keydown', e => { if (e.key === 'Enter' && document.getElementById('LS').style.display !== 'none') doLogin(); });

if (TOKEN) {
  document.getElementById('LS').style.display = 'none';
  document.getElementById('MS').style.display = 'flex';
  initPanel();
}

async function initPanel() {
  loadStats(); loadMotd(); loadUsers(); loadServers(); loadReports(); loadSounds(); loadLogs(); loadSettings();
  loadMongo();
  loadMe();
}

let ME = null;
async function loadMe() {
  ME = await api('GET', '/me');
  if (!ME) return;
  document.getElementById('devNavSec').style.display = ME.roles.includes('developer') || ME.roles.includes('admin') ? 'block' : 'none';
  document.getElementById('devDeployBtn').style.display = ME.canDeployToProduction ? 'inline-flex' : 'none';
}

async function loadStats() {
  const d = await api('GET', '/stats');
  if (!d) return;
  document.getElementById('dUsers').textContent = d.users;
  document.getElementById('dServers').textContent = d.servers;
  document.getElementById('dMessages').textContent = d.messages?.toLocaleString() || '—';
  document.getElementById('dReports').textContent = d.reports;
  document.getElementById('siUsers').textContent = d.users;
  document.getElementById('siServers').textContent = d.servers;
  document.getElementById('siReports').textContent = d.reports;
}

async function loadMotd() {
  const d = await api('GET', '/motd');
  if (!d) return;
  document.getElementById('motdTxt').value = d.text || '';
  document.getElementById('motdPrev').textContent = d.text || '';
  document.getElementById('dashMotd').textContent = d.text || '(no MOTD set)';
}

async function saveMotd() {
  const text = document.getElementById('motdTxt').value;
  await api('PUT', '/motd', { text, enabled: true });
  document.getElementById('dashMotd').textContent = text;
  const ok = document.getElementById('motdOk');
  ok.style.display = 'inline'; setTimeout(() => ok.style.display = 'none', 2000);
  showToast('MOTD published.');
}

async function loadUsers() {
  const d = await api('GET', '/users');
  allUsers = d || [];
  renderUsers(allUsers);
}
function filterUsers(q) { renderUsers(allUsers.filter(u => (u.username||'').toLowerCase().includes(q.toLowerCase()) || (u.email||'').toLowerCase().includes(q.toLowerCase()))); }
function rc(r){return r==='admin'?'p-gold':r==='mod'?'p-blue':'p-gray';}
function sc2(s){return s==='Online'?'p-green':s==='Idle'?'p-amber':'p-gray';}
function renderUsers(list) {
  document.getElementById('uBody').innerHTML = list.length === 0
    ? '<tr><td colspan="5" style="text-align:center;color:var(--text3);padding:20px;">No users found</td></tr>'
    : list.map(u => `<tr>
      <td><div class="uc"><div class="av" style="background:#c9b87822;color:var(--gold);">${(u.username||'?')[0].toUpperCase()}</div><div><div class="un">${u.username||'unknown'}</div><div class="uh">${u.email||''}</div></div></div></td>
      <td><span class="pill ${u.privileged?'p-gold':'p-gray'}">${u.privileged?'admin':'user'}</span></td>
      <td><span class="pill p-gray">offline</span>${u.banned?'&nbsp;<span class="pill p-red">banned</span>':''}</td>
      <td style="color:var(--text3)">${u.createdAt ? new Date(u.createdAt).toLocaleDateString() : '—'}</td>
      <td>
        <button class="ab" title="Reset password" onclick='openResetPw("${u._id}","${u.username}")'><i class="ti ti-key"></i></button>
        <button class="ab" title="${u.cctAdmin?'Revoke admin panel access':'Grant admin panel access'}" onclick='toggleAdmin("${u._id}","${u.username}",${!u.cctAdmin})' style="${u.cctAdmin?'color:var(--gold)':''}"><i class="ti ti-shield-check"></i></button>
        <button class="ab" title="${u.cctDeveloper?'Revoke dev sandbox access':'Grant dev sandbox access'}" onclick='toggleDeveloper("${u._id}","${u.username}",${!u.cctDeveloper})' style="${u.cctDeveloper?'color:var(--gold)':''}"><i class="ti ti-code"></i></button>
        <button class="ab" title="${u.banned?'Unban':'Ban'}" onclick='toggleBan("${u._id}",${!u.banned})' style="${u.banned?'color:var(--green)':''}"><i class="ti ti-${u.banned?'user-check':'ban'}"></i></button>
        <button class="ab d" title="Delete" onclick='delUser("${u._id}","${u.username}")'><i class="ti ti-trash"></i></button>
      </td></tr>`).join('');
}
async function toggleBan(id, banned) {
  await api('PATCH', '/users/' + id, { banned });
  loadUsers(); showToast(banned ? 'User banned.' : 'User unbanned.');
}
async function toggleDeveloper(id, name, enabled) {
  const r = await api('POST', '/users/' + id + '/set-developer', { enabled });
  if (r) { loadUsers(); showToast(enabled ? name + ' granted dev sandbox access.' : name + ' dev sandbox access revoked.'); }
}
async function confirmDelUser(id, name) {
  await api('DELETE', '/users/' + id);
  closeModal(); loadUsers(); showToast(name + ' deleted.');
}
function delUser(id, name) { showModal('Delete user', `<p style="color:var(--text2);font-size:13px;">Permanently delete <strong>${name}</strong>? This cannot be undone.</p>`, `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-danger" onclick='confirmDelUser("${id}","${name}")'>Delete</button>`); }
function openResetPw(id, name) { showModal('Reset password — ' + name, `<div class="field"><label>New password</label><input type="password" id="np1" placeholder="New password..."/></div><div class="field"><label>Confirm</label><input type="password" id="np2" placeholder="Confirm..."/></div>`, `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-gold" onclick='doReset("${id}","${name}")'>Reset</button>`); }
async function doReset(id, name) {
  const a = document.getElementById('np1').value, b = document.getElementById('np2').value;
  if (!a) return; if (a !== b) { showToast('Passwords do not match.', true); return; }
  await api('POST', '/users/' + id + '/reset-password', { password: a });
  closeModal(); showToast('Password for ' + name + ' reset.');
}
function openNewUser() { showModal('New user', `<div class="field"><label>Username</label><input type="text" id="nu" placeholder="username"/></div><div class="field"><label>Email</label><input type="email" id="ne" placeholder="user@example.com"/></div><div class="field"><label>Password</label><input type="password" id="npw" placeholder="••••••••"/></div>`, `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-gold" onclick="createUser()">Create</button>`); }
async function createUser() { const n=document.getElementById('nu').value; if(!n) return; showToast('Creating user... (wire to delta API)'); closeModal(); }

async function loadServers() {
  const d = await api('GET', '/servers');
  const list = d || [];
  document.getElementById('sBody').innerHTML = list.length === 0
    ? '<tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;">No servers</td></tr>'
    : list.map(s => `<tr>
      <td><div class="uc"><div class="av" style="background:rgba(88,128,200,0.2);color:var(--blue);border-radius:7px;">${(s.name||'?')[0].toUpperCase()}</div><div class="un">${s.name||s._id}</div></div></td>
      <td style="color:var(--text2)">${s.owner||'—'}</td><td>${s.members||'—'}</td><td>${s.channels||'—'}</td>
      <td style="color:var(--text3)">${s.createdAt ? new Date(s.createdAt).toLocaleDateString() : '—'}</td>
      <td><button class="ab d" onclick='delServer("${s._id}","${s.name||s._id}")'><i class="ti ti-trash"></i></button></td></tr>`).join('');
}
function delServer(id, name) { showModal('Delete server', `<p style="color:var(--text2);font-size:13px;">Delete <strong>${name}</strong> and all its data?</p>`, `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-danger" onclick='confirmDelServer("${id}","${name}")'>Delete</button>`); }
async function confirmDelServer(id, name) { await api('DELETE', '/servers/' + id); closeModal(); loadServers(); showToast(name + ' deleted.'); }

async function loadReports() {
  const d = await api('GET', '/reports');
  const list = d || [];
  document.getElementById('siReports').textContent = list.filter(r => r.status !== 'resolved').length;
  document.getElementById('dReports').textContent = list.filter(r => r.status !== 'resolved').length;
  document.getElementById('repBody').innerHTML = list.length === 0
    ? '<tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;">No reports</td></tr>'
    : list.map(r => `<tr>
      <td style="color:var(--text2)">${r.author_id||'unknown'}</td>
      <td><strong>${r.content?.id||'—'}</strong></td>
      <td>${r.additional_context||r.reason||'—'}</td>
      <td style="color:var(--text3)">${r.createdAt ? new Date(r.createdAt).toLocaleDateString() : '—'}</td>
      <td><span class="pill ${r.status==='Resolved'?'p-green':'p-amber'}">${r.status||'pending'}</span></td>
      <td>${r.status !== 'Resolved' ? `<button class="btn btn-ghost btn-sm" onclick='resolveRep("${r._id}")'>Resolve</button>` : ''}</td></tr>`).join('');
}
async function resolveRep(id) { await api('PATCH', '/reports/' + id, { status: 'Resolved' }); loadReports(); showToast('Report resolved.'); }

async function loadSounds() {
  const d = await api('GET', '/sounds');
  const list = (d && d.sounds) || [];
  document.getElementById('soundList').innerHTML = list.length === 0
    ? '<div style="color:var(--text3);font-size:13px;">No sounds uploaded yet.</div>'
    : list.map(s => `<div class="snd-card">
        <div class="snd-icon"><i class="ti ti-music"></i></div>
        <div class="snd-info"><div class="snd-name">${s.filename}</div><div class="snd-meta">${s.event} · ${Math.round(s.size/1024)} KB</div></div>
        <audio id="aud_${s.filename.replace(/\W/g,'_')}" src="${s.url}" preload="none"></audio>
        <button class="btn btn-ghost btn-sm" onclick='document.getElementById("aud_${s.filename.replace(/\W/g,'_')}").play()'><i class="ti ti-player-play"></i> Preview</button>
        <label class="tog" style="margin-left:8px;"><input type="checkbox" ${s.active?'checked':''} onchange='patchSound("${s.filename}",this.checked)'><div class="tog-t"></div></label>
        <button class="ab d" style="margin-left:4px;" onclick='delSound("${s.filename}")'><i class="ti ti-trash"></i></button>
      </div>`).join('');
  renderFilesFromSounds(list);
}
async function patchSound(filename, active) { await api('PATCH', '/sounds/' + encodeURIComponent(filename), { active }); }
async function delSound(filename) { await api('DELETE', '/sounds/' + encodeURIComponent(filename)); loadSounds(); showToast('Sound removed.'); }
function renderFilesFromSounds(list) {
  document.getElementById('filesGrid').innerHTML = list.length === 0
    ? '<div style="padding:20px;color:var(--text3);">No sounds uploaded.</div>'
    : list.map(s => `<div class="file-card"><i class="ti ti-music"></i><div class="fn">${s.filename}</div><div class="fs">${Math.round(s.size/1024)} KB</div></div>`).join('');
}
function fileTab(t, btn) { document.querySelectorAll('.tab').forEach(tb => tb.classList.remove('active')); btn.classList.add('active'); }

function openUploadSound() {
  showModal('Upload notification sound',
    `<div class="drop-zone" id="dz"><i class="ti ti-cloud-upload" style="font-size:24px;display:block;margin-bottom:8px;"></i>Drop .mp3 or .ogg here<br><small style="color:var(--text3)">or click Browse</small></div>
     <input type="file" id="soundFile" accept=".mp3,.ogg,.wav" style="display:none" onchange="handleFileSelect(this)"/>
     <button class="btn btn-ghost btn-sm" onclick="document.getElementById('soundFile').click()" style="margin-bottom:12px;"><i class="ti ti-folder-open"></i> Browse</button>
     <span id="soundFileName" style="font-size:12px;color:var(--gold2);margin-left:8px;"></span>
     <div class="field" style="margin-top:8px;"><label>Event type</label><select id="soundEvent"><option value="message">New message</option><option value="mention">Mention</option><option value="join">User join</option><option value="leave">User leave</option><option value="stage">Stage channel start</option></select></div>`,
    `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-gold" onclick="doUploadSound()">Upload</button>`);
  const dz = document.getElementById('dz');
  dz.addEventListener('dragover', e => { e.preventDefault(); dz.classList.add('drag'); });
  dz.addEventListener('dragleave', () => dz.classList.remove('drag'));
  dz.addEventListener('drop', e => { e.preventDefault(); dz.classList.remove('drag'); const f=e.dataTransfer.files[0]; if(f) { document.getElementById('soundFileName').textContent=f.name; dz._file=f; } });
}
function handleFileSelect(inp) { if (inp.files[0]) document.getElementById('soundFileName').textContent = inp.files[0].name; }
async function doUploadSound() {
  const inp = document.getElementById('soundFile');
  const dz = document.getElementById('dz');
  const file = inp.files[0] || dz._file;
  if (!file) { showToast('Select a file first.', true); return; }
  const event = document.getElementById('soundEvent').value;
  const fd = new FormData();
  fd.append('file', file);
  fd.append('event', event);
  const r = await fetch('/api/admin/sounds', { method:'POST', headers:{'Authorization':'Bearer '+TOKEN}, body:fd });
  if (r.ok) { closeModal(); loadSounds(); showToast('Sound uploaded!'); }
  else showToast('Upload failed.', true);
}

async function loadMongo() {
  const col = document.getElementById('mongoCol').value;
  const d = await api('GET', '/db/' + col + '?page=' + mongoPage_ + '&limit=20');
  if (!d) return;
  document.getElementById('mongoCount').textContent = `Showing ${d.docs.length} of ${d.total} documents`;
  document.getElementById('mongoBody').innerHTML = d.docs.length === 0
    ? '<div style="padding:20px;text-align:center;color:var(--text3);">No documents</div>'
    : d.docs.map(doc => `<div class="mongo-row">{&nbsp;${Object.entries(doc).slice(0,6).map(([k,v])=>`<span class="mk">"${k}"</span><span class="ms">:</span>&nbsp;<span class="mv">${JSON.stringify(v).substring(0,50)}</span>`).join('&nbsp;<span class="ms">,</span>&nbsp;')}&nbsp;}</div>`).join('');
}
function mongoFilterRows(q) {
  document.querySelectorAll('.mongo-row').forEach(r => { r.style.display = r.textContent.toLowerCase().includes(q.toLowerCase()) ? '' : 'none'; });
}
function mongoPage(dir) { mongoPage_ = Math.max(0, mongoPage_ + dir); loadMongo(); }

function loadLK() { document.getElementById('lkBody').innerHTML = '<div style="padding:14px;color:var(--text3);font-size:13px;">LiveKit admin API integration requires your LK API key/secret. Set them above and rooms will load here. You can also manage rooms via the LiveKit dashboard at your LiveKit URL.</div>'; }

const sampleLogs = [
  {ts:'startup',lvl:'o',msg:'CCT Admin server started on port 5000'},
  {ts:'startup',lvl:'i',msg:'MongoDB connection established'},
  {ts:'startup',lvl:'i',msg:'Static files served from dist_injected/'},
  {ts:'runtime',lvl:'i',msg:'GET /api/config/sounds 200 2ms'},
  {ts:'runtime',lvl:'i',msg:'POST /api/admin/login 200 45ms'},
  {ts:'runtime',lvl:'w',msg:'MongoDB slow query: users.find() 280ms'},
];
function loadLogs() {
  const cls={i:'li',o:'lo',w:'lw',e:'le'}, lbl={i:'INFO',o:'OK  ',w:'WARN',e:'ERR '};
  document.getElementById('logBody').innerHTML = sampleLogs.map(l => `<div class="logline" data-lvl="${l.lvl}"><span class="lts">[${l.ts}]</span><span class="${cls[l.lvl]}">[${lbl[l.lvl]}]</span>&nbsp;&nbsp;${l.msg}</div>`).join('');
}
function filterLog(f, btn) {
  document.querySelectorAll('#pgLogs .btn').forEach(b => b.style.color = '');
  btn.style.color = 'var(--gold)';
  document.querySelectorAll('.logline').forEach(l => l.style.display = (f==='all' || l.dataset.lvl===f) ? '' : 'none');
}

let currentSettings = {};
async function loadSettings() {
  const d = await api('GET', '/settings');
  currentSettings = d || {};
  const fields = [
    ['openRegistration','Open registration','Allow anyone to create an account'],
    ['inviteOnly','Invite-only mode','Require invite link to register'],
    ['stageChannels','Stage channels','Enable LiveKit-powered stage audio'],
    ['maintenanceMode','Maintenance mode','Block logins, show maintenance banner'],
  ];
  document.getElementById('settingsBody').innerHTML = fields.map(([k,name,desc]) => `<div class="sr"><div class="si"><div class="sn">${name}</div><div class="sd">${desc}</div></div><label class="tog"><input type="checkbox" id="set_${k}" ${currentSettings[k]?'checked':''}><div class="tog-t"></div></label></div>`).join('')
    + `<div class="sr"><div class="si"><div class="sn">Instance name</div></div><input id="set_instanceName" style="background:var(--bg);border:1px solid var(--border2);border-radius:6px;padding:5px 9px;color:var(--text);font-size:12px;outline:none;width:180px;font-family:inherit;" value="${currentSettings.instanceName||'CCT'}"/></div>`;
}
async function saveSettings() {
  const body = { instanceName: document.getElementById('set_instanceName').value };
  ['openRegistration','inviteOnly','stageChannels','maintenanceMode'].forEach(k => { body[k] = document.getElementById('set_'+k).checked; });
  await api('PUT', '/settings', body);
  showToast('Settings saved.');
}

function nav(el, pg) {
  document.querySelectorAll('.ni').forEach(n => n.classList.remove('active'));
  if (el) el.classList.add('active');
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.getElementById(pg).classList.add('active');
  const t = {pgDash:'Dashboard',pgUsers:'Users',pgServers:'Servers',pgMotd:'Message of the Day',pgSounds:'Notification Sounds',pgReports:'Reports',pgMongo:'MongoDB',pgLiveKit:'LiveKit',pgFiles:'Media Storage',pgLogs:'Logs',pgSettings:'Settings',pgDev:'Dev Sandbox'};
  document.getElementById('ttl').textContent = t[pg] || pg;
  if (pg === 'pgDev') loadDevSessions();
}

async function doSessionLogin() {
  const err = document.getElementById('le'), btn = document.getElementById('sessionBtn');
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Checking session...';
  try {
    // Read the session token from localforage (same key/store the Revolt client uses)
    const authData = await localforage.getItem('auth');
    const token = authData?.session?.token;
    if (!token) {
      err.textContent = 'No active CCT session found. Make sure you are logged into CCT in this browser.';
      err.style.display = 'block';
      btn.innerHTML = '<i class="ti ti-shield-check" style="vertical-align:middle;margin-right:5px;"></i>Use current CCT session';
      btn.disabled = false;
      return;
    }
    const r = await fetch('/api/admin/login', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ sessionToken: token }) });
    const d = await r.json();
    if (r.ok && d.token) {
      TOKEN = d.token;
      localStorage.setItem('cct_admin_token', TOKEN);
      err.style.display = 'none';
      document.getElementById('LS').style.display = 'none';
      document.getElementById('MS').style.display = 'flex';
      initPanel();
    } else {
      err.textContent = d.error || 'Session login failed.';
      err.style.display = 'block';
    }
  } catch(e) {
    err.textContent = 'Error: ' + e.message;
    err.style.display = 'block';
  }
  btn.innerHTML = '<i class="ti ti-shield-check" style="vertical-align:middle;margin-right:5px;"></i>Use current CCT session';
  btn.disabled = false;
}

async function toggleAdmin(id, name, promote) {
  const endpoint = promote ? '/promote' : '/demote';
  const r = await api('POST', '/users/' + id + endpoint, {});
  if (r) { loadUsers(); showToast(promote ? name + ' can now access the admin panel.' : name + ' admin access revoked.'); }
}

function showModal(t, c, a) { document.getElementById('mTitle').textContent=t; document.getElementById('mContent').innerHTML=c; document.getElementById('mActs').innerHTML=a; document.getElementById('MO').style.display='flex'; }
function closeModal() { document.getElementById('MO').style.display='none'; }

let tt;
function showToast(msg, err) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.style.borderColor = err ? 'var(--red)' : 'var(--border2)';
  t.style.opacity = '1';
  clearTimeout(tt);
  tt = setTimeout(() => t.style.opacity = '0', 2500);
}

// ─── Dev sandbox ──────────────────────────────────────────────────────────────

let devSessions = [];
let devActiveSession = null;
let devHeartbeatTimer = null;

async function loadDevSessions() {
  const list = await api('GET', '/dev/sessions');
  if (!list) return;
  devSessions = list;
  const el = document.getElementById('devSessionList');
  el.innerHTML = list.length === 0
    ? '<div style="padding:20px;text-align:center;color:var(--text3);">No active sessions. Start one to edit the client codebase in a live sandbox.</div>'
    : list.map(s => `
      <div class="sr">
        <div class="si">
          <div class="sn">${s.username} <span style="color:var(--text3);font-weight:400;">— ${s.branch}</span></div>
          <div class="sd">Started ${new Date(s.created_at).toLocaleString()}</div>
        </div>
        <button class="btn btn-ghost btn-sm" onclick="openDevSession('${s.id}')"><i class="ti ti-external-link"></i> Open</button>
        <button class="btn btn-danger btn-sm" style="margin-left:6px;" onclick="devEndSession('${s.id}')"><i class="ti ti-x"></i></button>
      </div>
    `).join('');
}

async function createDevSession() {
  const btn = document.getElementById('devNewBtn');
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Starting...';
  try {
    const session = await api('POST', '/dev/sessions', {});
    if (session) {
      showToast('Sandbox session starting — first install can take a minute or two.');
      await loadDevSessions();
      openDevSession(session.id);
    }
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="ti ti-plus"></i> New session';
  }
}

async function openDevSession(id) {
  devActiveSession = devSessions.find(s => s.id === id) || (await api('GET', '/dev/sessions')).find(s => s.id === id);
  if (!devActiveSession) { showToast('Session not found — it may have expired.', true); return; }

  document.getElementById('devWorkspace').style.display = 'block';
  document.getElementById('devBranchName').textContent = devActiveSession.branch;
  document.getElementById('devPreviewFrame').src = devActiveSession.preview_path;
  document.getElementById('devPreviewHint').textContent = '(first load may take a minute while it installs)';
  document.getElementById('devDeployBtn').style.display = ME?.canDeployToProduction ? 'inline-flex' : 'none';

  devCloseTerminal();
  devSwitchTab('files');
  await devLoadFileTree('');

  clearInterval(devHeartbeatTimer);
  devHeartbeatTimer = setInterval(() => {
    if (devActiveSession) api('POST', `/dev/sessions/${devActiveSession.id}/heartbeat`, {});
  }, 5 * 60 * 1000);
}

// ─── Dev sandbox: terminal tab ────────────────────────────────────────────

let devTerm = null, devTermFit = null, devTermWs = null;

function devSwitchTab(tab) {
  document.getElementById('devFilesView').style.display = tab === 'files' ? 'flex' : 'none';
  document.getElementById('devTerminalView').style.display = tab === 'terminal' ? 'block' : 'none';
  document.getElementById('devTabFiles').classList.toggle('active', tab === 'files');
  document.getElementById('devTabTerminal').classList.toggle('active', tab === 'terminal');
  if (tab === 'terminal') devConnectTerminal();
}

function devConnectTerminal() {
  if (devTermWs) return; // already connected for this session
  if (!devActiveSession) return;

  devTerm = new Terminal({
    convertEol: true,
    fontFamily: "'Consolas',monospace",
    fontSize: 13,
    theme: { background: '#000000', foreground: '#e8e4d8', cursor: '#c9b878' },
  });
  devTermFit = new FitAddon.FitAddon();
  devTerm.loadAddon(devTermFit);
  devTerm.open(document.getElementById('devTerminalEl'));
  devTermFit.fit();
  devTerm.writeln('Connecting to sandbox container...');

  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  devTermWs = new WebSocket(proto + '//' + location.host + devActiveSession.terminal_path);

  devTermWs.onopen = () => {
    devTerm.reset();
    const send_resize = () => {
      devTermFit.fit();
      devTermWs.send(JSON.stringify({ type: 'resize', cols: devTerm.cols, rows: devTerm.rows }));
    };
    send_resize();
    devTerm._resizeObserver = new ResizeObserver(send_resize);
    devTerm._resizeObserver.observe(document.getElementById('devTerminalEl'));
  };
  devTermWs.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === 'data') devTerm.write(msg.data);
  };
  devTermWs.onclose = () => devTerm?.writeln('\r\n\x1b[90m[connection closed]\x1b[0m');
  devTermWs.onerror = () => devTerm?.writeln('\r\n\x1b[31m[connection error]\x1b[0m');

  devTerm.onData((data) => {
    if (devTermWs.readyState === WebSocket.OPEN) devTermWs.send(JSON.stringify({ type: 'data', data }));
  });
}

function devCloseTerminal() {
  if (devTermWs) { devTermWs.close(); devTermWs = null; }
  if (devTerm) { devTerm._resizeObserver?.disconnect(); devTerm.dispose(); devTerm = null; }
  devTermFit = null;
}

async function devLoadFileTree(relPath) {
  const d = await api('GET', `/dev/sessions/${devActiveSession.id}/files?path=${encodeURIComponent(relPath)}`);
  if (!d) return;
  const tree = document.getElementById('devFileTree');
  const rows = d.entries.map(e => `
    <div style="padding:4px 6px;font-size:12px;cursor:pointer;border-radius:5px;color:${e.type==='dir'?'var(--gold)':'var(--text2)'};" 
         onclick="${e.type==='dir' ? `devLoadFileTree('${e.path}')` : `devOpenFile('${e.path}')`}"
         onmouseover="this.style.background='var(--surface2)'" onmouseout="this.style.background=''">
      <i class="ti ti-${e.type==='dir'?'folder':'file'}" style="font-size:13px;margin-right:5px;"></i>${e.name}
    </div>
  `).join('');
  tree.innerHTML = (relPath ? `<div style="padding:4px 6px;font-size:12px;cursor:pointer;color:var(--text3);" onclick="devLoadFileTree('${relPath.split('/').slice(0,-1).join('/')}')">.. up</div>` : '') + rows;
}

let devCurrentFilePath = null;
async function devOpenFile(relPath) {
  const d = await api('GET', `/dev/sessions/${devActiveSession.id}/file?path=${encodeURIComponent(relPath)}`);
  if (!d) return;
  devCurrentFilePath = relPath;
  document.getElementById('devCurrentFile').textContent = relPath;
  document.getElementById('devEditor').value = d.content;
}

async function devSaveFile() {
  if (!devCurrentFilePath) { showToast('No file open.', true); return; }
  const content = document.getElementById('devEditor').value;
  const r = await api('PUT', `/dev/sessions/${devActiveSession.id}/file`, { path: devCurrentFilePath, content });
  if (r) showToast('Saved — the sandbox preview will hot-reload.');
}

async function devSubmitToGithub() {
  const r = await api('POST', `/dev/sessions/${devActiveSession.id}/github-submit`, {
    message: prompt('Commit message:', `Changes from ${devActiveSession.username}`) || 'Dev sandbox changes',
  });
  if (!r) return;
  if (!r.pushed) { showToast('No changes to submit.'); return; }
  showModal('Submitted to GitHub', `<p style="font-size:13px;color:var(--text2);">Pull request is open:</p><p style="margin-top:8px;"><a href="${r.pr_url}" target="_blank" style="color:var(--gold);">${r.pr_url}</a></p>`, `<button class="btn btn-ghost" onclick="closeModal()">Close</button>`);
}

function devOpenDeployModal() {
  showModal(
    'Deploy to production',
    `<p style="font-size:13px;color:var(--text2);margin-bottom:10px;">This merges the PR and rebuilds + restarts the live site. Enter the PR number to deploy:</p>
     <input id="devDeployPr" type="number" placeholder="PR number" style="width:100%;background:var(--bg);border:1px solid var(--border2);border-radius:7px;padding:8px 10px;color:var(--text);font-size:13px;outline:none;"/>`,
    `<button class="btn btn-ghost" onclick="closeModal()">Cancel</button><button class="btn btn-danger" onclick="devConfirmDeploy()">Deploy</button>`
  );
}

async function devConfirmDeploy() {
  const pr = parseInt(document.getElementById('devDeployPr').value);
  if (!pr) return;
  closeModal();
  showToast('Deploying — this can take a minute...');
  const r = await api('POST', '/dev/deploy', { pull_number: pr });
  if (!r) return;
  showModal('Deploy log', `<pre style="font-family:'Consolas',monospace;font-size:11px;white-space:pre-wrap;max-height:340px;overflow-y:auto;color:var(--text2);">${(r.log||[]).join('\n')}</pre>`, `<button class="btn btn-ghost" onclick="closeModal()">Close</button>`);
}

async function devEndSession(id) {
  const sessionId = id || devActiveSession?.id;
  if (!sessionId) return;
  if (!confirm('End this dev session? Unsaved sandbox state (not yet submitted to GitHub) will be lost.')) return;
  await api('DELETE', `/dev/sessions/${sessionId}`);
  if (devActiveSession?.id === sessionId) {
    devActiveSession = null;
    clearInterval(devHeartbeatTimer);
    devCloseTerminal();
    document.getElementById('devWorkspace').style.display = 'none';
  }
  loadDevSessions();
  showToast('Session ended.');
}

</script>
</body>
</html>
CCTEOF_ADMININDEX2


echo "==> Rebuilding dev-orchestrator (node-pty needs a real npm install + native compile, this will take a bit longer than usual)..."
(cd "$STOAT_DIR" && docker compose up -d --build dev-orchestrator)

echo "==> Rebuilding admin/web frontend..."
(cd "$CLIENT_DIR" && docker build --no-cache -t cct-frontend .)
(cd "$STOAT_DIR" && docker compose up -d web)

echo "==> Done. Open a dev sandbox session and click the Terminal tab."
