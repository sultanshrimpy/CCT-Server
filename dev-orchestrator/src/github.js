// github.js
// Talks to the GitHub REST API using the shared bot token for:
//   - opening/updating a PR when a developer "submits to GitHub"
//   - merging that PR as the last step of a production deploy
//
// All admin-console users who trigger a submit share this one bot identity
// on GitHub — commits/PRs show up as authored by the bot, not by the
// individual developer. That's a deliberate simplification (per your
// decision to use one shared token rather than per-user OAuth).

const config = require("./config");

const API = "https://api.github.com";

async function gh(path, opts = {}) {
  const res = await fetch(`${API}${path}`, {
    ...opts,
    headers: {
      Authorization: `Bearer ${config.github.token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(opts.body ? { "Content-Type": "application/json" } : {}),
      ...opts.headers,
    },
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const err = new Error(`GitHub API ${path} failed: ${res.status} ${data.message || text}`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

// Opens a PR for the branch if one doesn't exist yet, otherwise returns the
// existing open PR. Safe to call repeatedly (e.g. re-submitting after more
// edits + another push).
async function ensure_pull_request(branch, { title, body }) {
  const { owner, repo } = config.github;

  const existing = await gh(
    `/repos/${owner}/${repo}/pulls?head=${owner}:${encodeURIComponent(branch)}&state=open`
  );
  if (existing.length > 0) {
    return existing[0];
  }

  return gh(`/repos/${owner}/${repo}/pulls`, {
    method: "POST",
    body: JSON.stringify({
      title,
      body,
      head: branch,
      base: config.client_repo_branch,
    }),
  });
}

async function merge_pull_request(pull_number) {
  const { owner, repo } = config.github;
  return gh(`/repos/${owner}/${repo}/pulls/${pull_number}/merge`, {
    method: "PUT",
    body: JSON.stringify({ merge_method: "squash" }),
  });
}

async function get_pull_request(pull_number) {
  const { owner, repo } = config.github;
  return gh(`/repos/${owner}/${repo}/pulls/${pull_number}`);
}

module.exports = { ensure_pull_request, merge_pull_request, get_pull_request };

