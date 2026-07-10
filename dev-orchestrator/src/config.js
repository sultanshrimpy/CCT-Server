// config.js
// Single source of truth for dev-orchestrator env vars.

function require_env(key) {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required environment variable: ${key}`);
  return val;
}

module.exports = {
  port: parseInt(process.env.PORT || "8700"),

  // Shared secret the admin panel (docker/server.js) must send on every
  // management request. The live-preview proxy route does NOT require this
  // (it's reached directly by developers' browsers) — it's protected by the
  // per-session preview token instead.
  internal_secret: require_env("DEV_ORCHESTRATOR_SECRET"),

  // Where ephemeral git worktrees live (bind-mounted host directory)
  workspaces_dir: process.env.DEV_WORKSPACES_DIR || "/data/dev-workspaces",

  // Persistent bare mirror of the client repo, used as the fast source for
  // `git worktree add` so we don't re-clone from GitHub on every session
  bare_repo_dir: process.env.DEV_BARE_REPO_DIR || "/data/dev-bare-repo.git",

  client_repo_url: require_env("CLIENT_REPO_URL"),
  client_repo_branch: process.env.CLIENT_REPO_BRANCH || "main",

  github: {
    token: require_env("GITHUB_BOT_TOKEN"),
    owner: require_env("GITHUB_REPO_OWNER"),
    repo: require_env("GITHUB_REPO_NAME"),
  },

  sandbox: {
    image: process.env.SANDBOX_IMAGE || "cct-sandbox",
    network: process.env.SANDBOX_NETWORK || "stoat_default",
    memory: process.env.SANDBOX_MEMORY || "2g",
    cpus: process.env.SANDBOX_CPUS || "2",
    port: 5173,
  },

  idle_timeout_ms: parseInt(process.env.DEV_SESSION_IDLE_MINUTES || "45") * 60 * 1000,

  // Used by the production deploy step. CLIENT_DIR is your persistent working
  // clone (the one you already `pnpm build` from) — separate from the
  // ephemeral per-session worktrees under workspaces_dir.
  deploy: {
    client_dir: process.env.DEPLOY_CLIENT_DIR || "/deploy/client",
    stoat_dir: process.env.DEPLOY_STOAT_DIR || "/deploy/stoat",
  },
};

