// docker.js
// Spins up / tears down sandbox containers by shelling out to the `docker`
// CLI (available inside this container because /var/run/docker.sock and the
// docker CLI are provided — see Dockerfile). Using the CLI directly instead
// of a Docker SDK means you can always reproduce/debug anything this does by
// just running the same `docker` command yourself on the host.

const { execFile } = require("child_process");
const config = require("./config");

function run(args) {
  return new Promise((resolve, reject) => {
    execFile("docker", args, { maxBuffer: 1024 * 1024 * 16 }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        return reject(err);
      }
      resolve(stdout.trim());
    });
  });
}

function container_name(session_id) {
  return `cct-sandbox-${session_id}`;
}

async function start_sandbox(session_id, worktree_path) {
  const name = container_name(session_id);

  await run([
    "run", "-d",
    "--name", name,
    "--network", config.sandbox.network,
    "--memory", config.sandbox.memory,
    "--cpus", config.sandbox.cpus,
    "--restart", "no",
    "-v", `${worktree_path}:/workspace`,
    "-e", `PORT=${config.sandbox.port}`,
    config.sandbox.image,
  ]);

  return { container_name: name, internal_url: `http://${name}:${config.sandbox.port}` };
}

async function stop_sandbox(session_id) {
  const name = container_name(session_id);
  try {
    await run(["rm", "-f", name]);
  } catch (e) {
    console.warn(`[docker] Failed to remove ${name} (may already be gone):`, e.message);
  }
}

async function sandbox_logs(session_id, tail = 200) {
  const name = container_name(session_id);
  try {
    return await run(["logs", "--tail", String(tail), name]);
  } catch (e) {
    return `(no logs available: ${e.message})`;
  }
}

async function is_running(session_id) {
  const name = container_name(session_id);
  try {
    const out = await run(["inspect", "-f", "{{.State.Running}}", name]);
    return out === "true";
  } catch {
    return false;
  }
}

module.exports = { start_sandbox, stop_sandbox, sandbox_logs, is_running, container_name };

