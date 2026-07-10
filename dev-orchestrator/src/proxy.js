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

