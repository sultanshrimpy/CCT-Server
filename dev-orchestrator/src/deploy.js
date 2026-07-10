// deploy.js
// The ONE path that ends with code running in production. Everything here
// mirrors the exact commands you'd run by hand (per update-server.sh):
// pull main into your real working clone, `docker build` the frontend
// image, `docker compose up -d --build web`. Nothing here is reachable
// unless the caller already passed the owner-only check in docker/server.js
// — see requireProductionDeployer in that file. This module does not
// re-check identity; it trusts server.js.

const { execFile } = require("child_process");
const config = require("./config");
const github = require("./github");

function run(cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, maxBuffer: 1024 * 1024 * 64 }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        return reject(err);
      }
      resolve(stdout);
    });
  });
}

async function deploy_pull_request(pull_number) {
  const log = [];
  const step = async (label, fn) => {
    log.push(`[deploy] ${label}...`);
    try {
      const out = await fn();
      if (out) log.push(out.trim());
      return out;
    } catch (e) {
      log.push(`[deploy] FAILED at "${label}": ${e.message}`);
      if (e.stdout) log.push(e.stdout.trim());
      if (e.stderr) log.push(e.stderr.trim());
      const err = new Error(`Deploy failed at: ${label}`);
      err.log = log;
      throw err;
    }
  };

  await step(`Merging PR #${pull_number}`, () => github.merge_pull_request(pull_number));

  await step("Pulling main into working clone", () =>
    run("git", ["pull", "origin", config.client_repo_branch], config.deploy.client_dir)
  );

  await step("Building frontend image (docker build --no-cache -t cct-frontend .)", () =>
    run("docker", ["build", "--no-cache", "-t", "cct-frontend", "."], config.deploy.client_dir)
  );

  await step("Restarting web container (docker compose up -d web)", () =>
    run("docker", ["compose", "up", "-d", "web"], config.deploy.stoat_dir)
  );

  log.push("[deploy] Done. Production is running the merged code.");
  return log;
}

module.exports = { deploy_pull_request };

