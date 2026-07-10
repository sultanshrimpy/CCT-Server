#!/usr/bin/env bash
# fix_admin_ui.sh — patches two bugs from the last full deploy:
#   1. Dev Sandbox sidebar item was forced to display:flex (should be block),
#      which squeezed "Dev Sandbox" next to the "DEVELOPMENT" label instead
#      of stacking normally, causing the text to wrap awkwardly.
#   2. The admin promote/demote button in the Users table got wiped out by
#      the earlier full-file overwrite of admin/index.html. Restored it,
#      and fixed /promote and /demote server-side to properly merge with
#      the roles array instead of ignoring or wiping out developer role.
#
# Usage: CLIENT_DIR=~/client ./fix_admin_ui.sh   (defaults to ~/client)

set -e
CLIENT_DIR="${CLIENT_DIR:-$HOME/client}"
if [ ! -d "$CLIENT_DIR" ]; then echo "CLIENT_DIR not found: $CLIENT_DIR"; exit 1; fi

echo "==> Writing files (CLIENT_DIR=$CLIENT_DIR)"

echo "  -> $CLIENT_DIR/docker/server.js"
mkdir -p "$(dirname "$CLIENT_DIR/docker/server.js")"
cat > "$CLIENT_DIR/docker/server.js" << 'CCTEOF_ADMINSERVER'
/**
 * CCT Admin Panel - Express Server
 * Replaces sirv-cli as the static file server.
 * Serves the built Revolt frontend + /admin panel + /api/admin/* routes.
 *
 * Supports two admin login methods:
 *   1. Username + password (env ADMIN_USERNAME / ADMIN_PASSWORD_HASH)
 *   2. Revolt session token — validates against delta, checks user.privileged in MongoDB
 *      OR checks cct_admin_users collection for manually promoted users
 */

const express = require("express");
const path = require("path");
const fs = require("fs");
const multer = require("multer");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const mongoose = require("mongoose");

const app = express();
const PORT = process.env.PORT || 5000;
const JWT_SECRET = process.env.ADMIN_JWT_SECRET || "cct-admin-secret-change-me";
const ADMIN_USER = process.env.ADMIN_USERNAME || "admin";
const ADMIN_PASS_HASH = process.env.ADMIN_PASSWORD_HASH || bcrypt.hashSync("admin123", 10);
const MONGO_URL = process.env.MONGO_URL || process.env.DATABASE_URL || "mongodb://localhost:27017/revolt";
// Delta API URL — used to validate Revolt session tokens
const DELTA_URL = (process.env.VITE_API_URL || process.env.REVOLT_PUBLIC_URL || "http://delta:8000").replace(/\/$/, "");

// ─── Dev sandbox integration ────────────────────────────────────────────────
// dev-orchestrator lives on the internal docker network only (no public
// route to its management API — see Caddyfile, only /sandbox/* is public
// and that's token-gated per-session, not this secret).
const DEV_ORCHESTRATOR_URL = process.env.DEV_ORCHESTRATOR_URL || "http://dev-orchestrator:8700";
const DEV_ORCHESTRATOR_SECRET = process.env.DEV_ORCHESTRATOR_SECRET || "";

// Production deploys are gated on Revolt user ID, NOT on role, and NOT
// reachable via the shared username+password login (that login has no real
// userId — see /api/admin/login Mode A below). This is the "only I can push
// to prod" guarantee: put your own Revolt account's _id here.
const PRODUCTION_DEPLOY_USER_IDS = (process.env.PRODUCTION_DEPLOY_USER_IDS || "")
  .split(",").map((s) => s.trim()).filter(Boolean);

async function devOrchestrator(path, opts = {}) {
  const res = await fetch(`${DEV_ORCHESTRATOR_URL}${path}`, {
    ...opts,
    headers: {
      "Content-Type": "application/json",
      "X-Internal-Secret": DEV_ORCHESTRATOR_SECRET,
      ...opts.headers,
    },
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const err = new Error(data.error || `dev-orchestrator ${path} failed: ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return data;
}

const SOUNDS_DIR = path.join(__dirname, "dist_injected", "sounds");
const STATIC_DIR = path.join(__dirname, "dist_injected");
const ADMIN_DIR = path.join(__dirname, "admin");

fs.mkdirSync(SOUNDS_DIR, { recursive: true });
fs.mkdirSync(ADMIN_DIR, { recursive: true });

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ─── Multer ──────────────────────────────────────────────────────────────────
const soundStorage = multer.diskStorage({
  destination: SOUNDS_DIR,
  filename: (req, file, cb) => cb(null, file.originalname),
});
const uploadSound = multer({
  storage: soundStorage,
  fileFilter: (req, file, cb) => cb(null, /\.(mp3|ogg|wav|flac)$/i.test(file.originalname)),
  limits: { fileSize: 5 * 1024 * 1024 },
});

// ─── MongoDB ─────────────────────────────────────────────────────────────────
let db = null;
mongoose.connect(MONGO_URL).then(() => {
  db = mongoose.connection;
  console.log("[CCT Admin] MongoDB connected:", MONGO_URL);
}).catch((e) => {
  console.warn("[CCT Admin] MongoDB unavailable:", e.message);
});

// ─── Auth middleware ──────────────────────────────────────────────────────────
function requireAdmin(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth?.startsWith("Bearer ")) return res.status(401).json({ error: "Unauthorized" });
  try {
    const payload = jwt.verify(auth.slice(7), JWT_SECRET);
    if (payload.role !== "admin") throw new Error();
    req.admin = payload;
    next();
  } catch {
    res.status(401).json({ error: "Invalid or expired token" });
  }
}

// Requires the "developer" role (dev sandbox access). Anyone with the
// instance-owner `privileged` flag gets this implicitly — see login, where
// roles are computed and baked into the JWT at login time.
function requireDeveloper(req, res, next) {
  requireAdmin(req, res, () => {
    if (!req.admin.roles?.includes("developer")) {
      return res.status(403).json({ error: "This account does not have developer access." });
    }
    next();
  });
}

// The hard "only I can push to prod" gate. Deliberately independent of the
// role system: checks the actual Revolt user ID against an explicit
// allowlist read from env, and refuses anyone who logged in via the shared
// username+password mode (that mode has no real userId to check).
function requireProductionDeployer(req, res, next) {
  requireAdmin(req, res, () => {
    if (!req.admin.userId || !PRODUCTION_DEPLOY_USER_IDS.includes(req.admin.userId)) {
      return res.status(403).json({ error: "Only the instance owner can deploy to production." });
    }
    next();
  });
}

// ─── Validate a Revolt session token against delta ───────────────────────────
async function validateRevoltToken(sessionToken) {
  try {
    const res = await fetch(`${DELTA_URL}/users/@me`, {
      headers: { "X-Session-Token": sessionToken },
    });
    if (!res.ok) return null;
    return await res.json(); // { _id, username, privileged, ... }
  } catch (e) {
    console.warn("[CCT Admin] Delta validation failed:", e.message);
    return null;
  }
}

// ─── Compute a user's CCT admin-panel roles ──────────────────────────────────
// - The instance owner (privileged: true in Revolt) gets every role
//   implicitly — they already have full DB access via the admin panel, so
//   restricting the dev sandbox from them specifically wouldn't add
//   security, just friction. Production deploy is gated separately (see
//   requireProductionDeployer) — being "an admin" here does NOT imply
//   deploy access.
// - Manually promoted users (cct_admin_users) get whatever `roles` array is
//   stored on their entry. Existing entries created before this feature
//   have no `roles` field — they default to ["admin"] so nothing already
//   promoted loses access.
async function getUserRoles(userId) {
  if (!db) return [];
  try {
    const user = await db.collection("users").findOne({ _id: userId }, { projection: { privileged: 1 } });
    if (user?.privileged) return ["admin", "developer"];

    const entry = await db.collection("cct_admin_users").findOne({ userId: userId.toString() });
    if (!entry) return [];
    return entry.roles && entry.roles.length ? entry.roles : ["admin"];
  } catch (e) {
    console.warn("[CCT Admin] getUserRoles check failed:", e.message);
    return [];
  }
}

async function isAdminUser(userId) {
  const roles = await getUserRoles(userId);
  return roles.includes("admin") || roles.includes("developer");
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
function getSoundsManifest() {
  const p = path.join(SOUNDS_DIR, "manifest.json");
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf-8")) : { sounds: [] };
}
function saveSoundsManifest(data) {
  fs.writeFileSync(path.join(SOUNDS_DIR, "manifest.json"), JSON.stringify(data, null, 2));
}
function getMotd() {
  const p = path.join(__dirname, "motd.json");
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf-8")) : { text: "Welcome to CCT!", enabled: true };
}
function saveMotd(data) {
  fs.writeFileSync(path.join(__dirname, "motd.json"), JSON.stringify(data, null, 2));
}
function getSettingsFile() {
  const p = path.join(__dirname, "instance_settings.json");
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf-8")) : { openRegistration: true, inviteOnly: false, stageChannels: true, maintenanceMode: false, instanceName: "CCT" };
}

// ─── Public routes ────────────────────────────────────────────────────────────

/**
 * Login — two modes:
 *
 * Mode A: username + password (env credentials)
 *   { username, password }
 *
 * Mode B: Revolt session token (for privileged/promoted users)
 *   { sessionToken }
 *   Server validates the token against delta, then checks MongoDB for admin status.
 *   Returns the same JWT so the panel works identically either way.
 */
app.post("/api/admin/login", async (req, res) => {
  const { username, password, sessionToken } = req.body;

  // ── Mode B: Revolt session token ──────────────────────────────────────────
  if (sessionToken) {
    const user = await validateRevoltToken(sessionToken);
    if (!user) return res.status(401).json({ error: "Invalid or expired session token" });

    const roles = await getUserRoles(user._id);
    if (roles.length === 0) return res.status(403).json({ error: "This account does not have admin access. Ask a server owner to promote you." });

    const token = jwt.sign(
      { username: user.username, userId: user._id, role: "admin", roles, method: "revolt_session" },
      JWT_SECRET,
      { expiresIn: "24h" }
    );
    return res.json({ token, username: user.username, roles, method: "revolt_session" });
  }

  // ── Mode A: username + password ───────────────────────────────────────────
  // Deliberately has no userId — this is a shared login, not tied to a
  // specific person, so it must never be able to pass
  // requireProductionDeployer or be granted the developer role.
  if (!username || !password) return res.status(400).json({ error: "Provide username+password or sessionToken" });
  if (username !== ADMIN_USER) return res.status(401).json({ error: "Invalid credentials" });
  const ok = await bcrypt.compare(password, ADMIN_PASS_HASH);
  if (!ok) return res.status(401).json({ error: "Invalid credentials" });

  const token = jwt.sign({ username, role: "admin", roles: ["admin"], method: "password" }, JWT_SECRET, { expiresIn: "24h" });
  res.json({ token, username, roles: ["admin"], method: "password" });
});

// Public config endpoints (read by the frontend at runtime)
app.get("/api/config/motd", (req, res) => res.json(getMotd()));
app.get("/api/config/sounds", (req, res) => res.json(getSoundsManifest()));

// ─── Protected: stats ─────────────────────────────────────────────────────────
app.get("/api/admin/stats", requireAdmin, async (req, res) => {
  if (!db) return res.json({ users: 0, servers: 0, messages: 0, reports: 0 });
  try {
    const [users, servers, messages, reports] = await Promise.all([
      db.collection("users").countDocuments(),
      db.collection("servers").countDocuments(),
      db.collection("messages").countDocuments(),
      db.collection("reports").countDocuments({ status: { $ne: "Resolved" } }),
    ]);
    res.json({ users, servers, messages, reports });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ─── Protected: users ─────────────────────────────────────────────────────────
app.get("/api/admin/users", requireAdmin, async (req, res) => {
  if (!db) return res.json([]);
  const users = await db.collection("users").find({}, { projection: { password: 0, tokens: 0 } }).limit(100).toArray();
  // Annotate with CCT admin/developer status
  const adminEntries = await db.collection("cct_admin_users").find({}).toArray();
  const rolesByUserId = new Map(adminEntries.map(a => [a.userId, a.roles && a.roles.length ? a.roles : ["admin"]]));
  res.json(users.map(u => {
    const roles = u.privileged ? ["admin", "developer"] : (rolesByUserId.get(u._id.toString()) || []);
    return { ...u, cctAdmin: roles.includes("admin"), cctDeveloper: roles.includes("developer") };
  }));
});

app.patch("/api/admin/users/:id", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  const { banned } = req.body;
  const update = {};
  if (banned !== undefined) update.banned = banned;
  await db.collection("users").updateOne({ _id: req.params.id }, { $set: update });
  res.json({ ok: true });
});

app.post("/api/admin/users/:id/reset-password", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  const { password } = req.body;
  if (!password || password.length < 6) return res.status(400).json({ error: "Password too short" });
  const hash = await bcrypt.hash(password, 12);
  await db.collection("users").updateOne(
    { _id: req.params.id },
    { $set: { password: hash } }
  );
  res.json({ ok: true });
});

app.delete("/api/admin/users/:id", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  await db.collection("users").deleteOne({ _id: req.params.id });
  res.json({ ok: true });
});

// Promote / demote a user to CCT admin
app.post("/api/admin/users/:id/promote", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  const userId = req.params.id;
  const user = await db.collection("users").findOne(
    { _id: userId },
    { projection: { username: 1 } }
  );
  if (!user) return res.status(404).json({ error: "User not found" });

  const existing = await db.collection("cct_admin_users").findOne({ userId });
  const roles = new Set(existing?.roles && existing.roles.length ? existing.roles : []);
  roles.add("admin");

  await db.collection("cct_admin_users").updateOne(
    { userId },
    { $set: { userId, username: user.username, roles: [...roles], promotedAt: new Date(), promotedBy: req.admin.username } },
    { upsert: true }
  );
  res.json({ ok: true, message: `${user.username} can now log into the admin panel` });
});

app.post("/api/admin/users/:id/demote", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  const userId = req.params.id;

  const existing = await db.collection("cct_admin_users").findOne({ userId });
  const roles = new Set(existing?.roles && existing.roles.length ? existing.roles : []);
  roles.delete("admin");

  if (roles.size === 0) {
    await db.collection("cct_admin_users").deleteOne({ userId });
  } else {
    await db.collection("cct_admin_users").updateOne({ userId }, { $set: { roles: [...roles] } });
  }
  res.json({ ok: true });
});

// Grants/revokes the "developer" role (dev sandbox + GitHub submit access)
// without touching "admin" — a user can be a developer without full admin,
// or both. Does NOT grant production deploy access; that's a separate,
// explicit env-var allowlist (see requireProductionDeployer).
app.post("/api/admin/users/:id/set-developer", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  const userId = req.params.id;
  const enabled = !!req.body.enabled;

  const user = await db.collection("users").findOne({ _id: userId }, { projection: { username: 1 } });
  if (!user) return res.status(404).json({ error: "User not found" });

  const existing = await db.collection("cct_admin_users").findOne({ userId });
  const currentRoles = new Set(existing?.roles && existing.roles.length ? existing.roles : (existing ? ["admin"] : []));

  if (enabled) currentRoles.add("developer");
  else currentRoles.delete("developer");

  if (currentRoles.size === 0) {
    await db.collection("cct_admin_users").deleteOne({ userId });
  } else {
    await db.collection("cct_admin_users").updateOne(
      { userId },
      { $set: { userId, username: user.username, roles: [...currentRoles], updatedAt: new Date(), promotedBy: req.admin.username } },
      { upsert: true }
    );
  }
  res.json({ ok: true, roles: [...currentRoles] });
});

// Tells the frontend what the current session can do — used to show/hide
// the Deploy to Production button. The actual enforcement always happens
// server-side in requireProductionDeployer regardless of what this returns.
app.get("/api/admin/me", requireAdmin, (req, res) => {
  res.json({
    username: req.admin.username,
    userId: req.admin.userId || null,
    roles: req.admin.roles || [],
    canDeployToProduction: !!req.admin.userId && PRODUCTION_DEPLOY_USER_IDS.includes(req.admin.userId),
  });
});

// ─── Protected: servers ───────────────────────────────────────────────────────
app.get("/api/admin/servers", requireAdmin, async (req, res) => {
  if (!db) return res.json([]);
  res.json(await db.collection("servers").find({}).limit(100).toArray());
});
app.delete("/api/admin/servers/:id", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  await db.collection("servers").deleteOne({ _id: req.params.id });
  res.json({ ok: true });
});

// ─── Protected: MOTD ─────────────────────────────────────────────────────────
app.get("/api/admin/motd", requireAdmin, (req, res) => res.json(getMotd()));
app.put("/api/admin/motd", requireAdmin, (req, res) => {
  saveMotd({ text: req.body.text || "", enabled: req.body.enabled !== false });
  res.json({ ok: true });
});

// ─── Protected: sounds ───────────────────────────────────────────────────────
app.get("/api/admin/sounds", requireAdmin, (req, res) => res.json(getSoundsManifest()));
app.post("/api/admin/sounds", requireAdmin, uploadSound.single("file"), (req, res) => {
  if (!req.file) return res.status(400).json({ error: "No file" });
  const manifest = getSoundsManifest();
  const entry = { filename: req.file.originalname, event: req.body.event || "message", url: `/sounds/${req.file.originalname}`, size: req.file.size, active: true, uploadedAt: new Date().toISOString() };
  manifest.sounds = manifest.sounds.filter(s => s.filename !== entry.filename);
  manifest.sounds.push(entry);
  saveSoundsManifest(manifest);
  res.json(entry);
});
app.patch("/api/admin/sounds/:filename", requireAdmin, (req, res) => {
  const manifest = getSoundsManifest();
  const sound = manifest.sounds.find(s => s.filename === req.params.filename);
  if (!sound) return res.status(404).json({ error: "Not found" });
  if (req.body.active !== undefined) sound.active = req.body.active;
  if (req.body.event !== undefined) sound.event = req.body.event;
  saveSoundsManifest(manifest);
  res.json(sound);
});
app.delete("/api/admin/sounds/:filename", requireAdmin, (req, res) => {
  const manifest = getSoundsManifest();
  const fp = path.join(SOUNDS_DIR, req.params.filename);
  if (fs.existsSync(fp)) fs.unlinkSync(fp);
  manifest.sounds = manifest.sounds.filter(s => s.filename !== req.params.filename);
  saveSoundsManifest(manifest);
  res.json({ ok: true });
});

// ─── Protected: MongoDB passthrough ─────────────────────────────────────────
const ALLOWED_COLLECTIONS = ["users","servers","channels","messages","sessions","reports","cct_admin_users"];
app.get("/api/admin/db/:collection", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  if (!ALLOWED_COLLECTIONS.includes(req.params.collection)) return res.status(403).json({ error: "Not allowed" });
  const page = parseInt(req.query.page) || 0;
  const limit = Math.min(parseInt(req.query.limit) || 20, 100);
  const docs = await db.collection(req.params.collection).find({}, { projection: { password: 0, tokens: 0 } }).skip(page * limit).limit(limit).toArray();
  const total = await db.collection(req.params.collection).countDocuments();
  res.json({ docs, total, page, limit });
});

// ─── Protected: reports ───────────────────────────────────────────────────────
app.get("/api/admin/reports", requireAdmin, async (req, res) => {
  if (!db) return res.json([]);
  res.json(await db.collection("reports").find({}).sort({ createdAt: -1 }).limit(50).toArray());
});
app.patch("/api/admin/reports/:id", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  await db.collection("reports").updateOne({ _id: req.params.id }, { $set: { status: req.body.status } });
  res.json({ ok: true });
});

// ─── Protected: settings ─────────────────────────────────────────────────────
app.get("/api/admin/settings", requireAdmin, (req, res) => res.json(getSettingsFile()));
app.put("/api/admin/settings", requireAdmin, (req, res) => {
  const merged = { ...getSettingsFile(), ...req.body };
  fs.writeFileSync(path.join(__dirname, "instance_settings.json"), JSON.stringify(merged, null, 2));
  res.json(merged);
});

// ─── Protected: dev sandbox (developer role) ─────────────────────────────────
// Thin proxy in front of dev-orchestrator. All the real work (worktrees,
// containers, GitHub) happens over there — this layer's only job is to
// enforce who's allowed to call it.

app.post("/api/admin/dev/sessions", requireDeveloper, async (req, res) => {
  try {
    const session = await devOrchestrator("/sessions", {
      method: "POST",
      body: JSON.stringify({ userId: req.admin.userId, username: req.admin.username }),
    });
    res.json(session);
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

// Developers see only their own sessions; full admins see everyone's.
app.get("/api/admin/dev/sessions", requireDeveloper, async (req, res) => {
  try {
    const all = await devOrchestrator("/sessions");
    const mine = req.admin.roles.includes("admin") ? all : all.filter((s) => s.userId === req.admin.userId);
    res.json(mine);
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.delete("/api/admin/dev/sessions/:id", requireDeveloper, async (req, res) => {
  try {
    await devOrchestrator(`/sessions/${req.params.id}`, { method: "DELETE" });
    res.json({ ok: true });
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.post("/api/admin/dev/sessions/:id/heartbeat", requireDeveloper, async (req, res) => {
  try {
    res.json(await devOrchestrator(`/sessions/${req.params.id}/heartbeat`, { method: "POST" }));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.get("/api/admin/dev/sessions/:id/files", requireDeveloper, async (req, res) => {
  try {
    const q = req.query.path ? `?path=${encodeURIComponent(req.query.path)}` : "";
    res.json(await devOrchestrator(`/sessions/${req.params.id}/files${q}`));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.get("/api/admin/dev/sessions/:id/file", requireDeveloper, async (req, res) => {
  try {
    res.json(await devOrchestrator(`/sessions/${req.params.id}/file?path=${encodeURIComponent(req.query.path || "")}`));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.put("/api/admin/dev/sessions/:id/file", requireDeveloper, async (req, res) => {
  try {
    res.json(await devOrchestrator(`/sessions/${req.params.id}/file`, {
      method: "PUT",
      body: JSON.stringify({ path: req.body.path, content: req.body.content }),
    }));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

app.post("/api/admin/dev/sessions/:id/github-submit", requireDeveloper, async (req, res) => {
  try {
    res.json(await devOrchestrator(`/sessions/${req.params.id}/github-submit`, {
      method: "POST",
      body: JSON.stringify({ title: req.body.title, body: req.body.body, message: req.body.message }),
    }));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

// ─── Protected: production deploy (owner-only, see requireProductionDeployer) ─
app.post("/api/admin/dev/deploy", requireProductionDeployer, async (req, res) => {
  if (!req.body.pull_number) return res.status(400).json({ error: "pull_number required" });
  try {
    res.json(await devOrchestrator("/deploy", {
      method: "POST",
      body: JSON.stringify({ pull_number: req.body.pull_number }),
    }));
  } catch (e) {
    res.status(e.status || 500).json({ error: e.message });
  }
});

// ─── Static serving ───────────────────────────────────────────────────────────
app.use("/sounds", express.static(SOUNDS_DIR));
app.use("/admin", express.static(ADMIN_DIR));
app.get("/admin", (req, res) => res.sendFile(path.join(ADMIN_DIR, "index.html")));
app.use(express.static(STATIC_DIR));
app.get("*", (req, res) => res.sendFile(path.join(STATIC_DIR, "index.html")));

app.listen(PORT, "0.0.0.0", () => {
  console.log(`[CCT] Server on port ${PORT}`);
  console.log(`[CCT] Delta API: ${DELTA_URL}`);
  console.log(`[CCT] Admin panel: http://localhost:${PORT}/admin`);
});

CCTEOF_ADMINSERVER

echo "  -> $CLIENT_DIR/docker/admin/index.html"
mkdir -p "$(dirname "$CLIENT_DIR/docker/admin/index.html")"
cat > "$CLIENT_DIR/docker/admin/index.html" << 'CCTEOF_ADMININDEX'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>CCT Admin Panel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.8.0/dist/tabler-icons.min.css"/>
<script src="https://cdn.jsdelivr.net/npm/localforage@1.10.0/dist/localforage.min.js"></script>
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
          <div style="display:flex;height:560px;border-top:1px solid var(--border);">
            <div style="width:200px;flex-shrink:0;overflow-y:auto;border-right:1px solid var(--border);padding:8px;" id="devFileTree"></div>
            <div style="flex:1;display:flex;flex-direction:column;min-width:0;">
              <div style="padding:6px 10px;font-size:11px;color:var(--text3);border-bottom:1px solid var(--border);font-family:'Consolas',monospace;" id="devCurrentFile">Select a file to edit</div>
              <textarea id="devEditor" style="flex:1;width:100%;background:var(--bg);color:var(--text);border:none;outline:none;font-family:'Consolas',monospace;font-size:12.5px;padding:10px;resize:none;" spellcheck="false" placeholder="Select a file from the tree to start editing..."></textarea>
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

  await devLoadFileTree('');

  clearInterval(devHeartbeatTimer);
  devHeartbeatTimer = setInterval(() => {
    if (devActiveSession) api('POST', `/dev/sessions/${devActiveSession.id}/heartbeat`, {});
  }, 5 * 60 * 1000);
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
    document.getElementById('devWorkspace').style.display = 'none';
  }
  loadDevSessions();
  showToast('Session ended.');
}

</script>
</body>
</html>
CCTEOF_ADMININDEX


echo "==> Rebuilding admin/web frontend image..."
(cd "$CLIENT_DIR" && docker build --no-cache -t cct-frontend .)

echo "==> Restarting web..."
STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"
(cd "$STOAT_DIR" && docker compose up -d web)

echo "==> Done."
