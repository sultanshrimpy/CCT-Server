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

