#!/usr/bin/env bash
# deploy_all.sh — writes out every file for:
#   1) the stage audio/video fix
#   2) the dev sandbox + GitHub submit + gated production deploy feature
#
# This OVERWRITES the destination files completely (not a patch). If you've
# hand-edited compose.yml, Caddyfile, docker/server.js, or docker/admin/index.html
# since the versions I generated earlier in this chat, those edits will be lost —
# diff first if you're not sure.
#
# Usage:
#   CLIENT_DIR=~/client STOAT_DIR=~/stoat ./deploy_all.sh
# (defaults to ~/client and ~/stoat if not set)

set -e

CLIENT_DIR="${CLIENT_DIR:-$HOME/client}"
STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"

if [ ! -d "$CLIENT_DIR" ]; then echo "CLIENT_DIR not found: $CLIENT_DIR"; exit 1; fi
if [ ! -d "$STOAT_DIR" ]; then echo "STOAT_DIR not found: $STOAT_DIR"; exit 1; fi

echo "==> Writing files (CLIENT_DIR=$CLIENT_DIR, STOAT_DIR=$STOAT_DIR)"

echo "  -> $CLIENT_DIR/packages/client/components/rtc/components/StageAudioManager.tsx"
mkdir -p "$(dirname "$CLIENT_DIR/packages/client/components/rtc/components/StageAudioManager.tsx")"
cat > "$CLIENT_DIR/packages/client/components/rtc/components/StageAudioManager.tsx" << 'CCTEOF_STAGEAUDIO'
import { createEffect, createMemo, createSignal, onCleanup, Show } from "solid-js";
import { AudioTrack, RoomContext, VideoTrack } from "solid-livekit-components";
import { getTrackReferenceId, isLocal, trackReferencesObservable } from "@livekit/components-core";
import type { TrackReferenceOrPlaceholder } from "@livekit/components-core";
import { Key } from "@solid-primitives/keyed";
import { RemoteTrackPublication, Track } from "livekit-client";
import { useState } from "@revolt/state";
import { useVoice } from "../state";

export function StageAudioManager() {
  const voice = useVoice();

  return (
    <Show when={voice.stageRoom()}>
      {(stageRoom) => (
        <RoomContext.Provider value={stageRoom()}>
          <StageAudioTracks />
          <StageVideoOverlay />
        </RoomContext.Provider>
      )}
    </Show>
  );
}

// Both StageAudioTracks and StageVideoOverlay watch every published track on
// the stage room (mic, screenshare audio, camera, screenshare video). LiveKit's
// `autoSubscribe: true` connect option does NOT reliably auto-subscribe here —
// see the identical fix already applied in RoomAudioManager for the main voice
// room — so we explicitly call `setSubscribed(true)` on every matching
// publication ourselves instead of relying on it.
function useStageTrackReferences() {
  const voice = useVoice();
  const [trackReferences, setTrackReferences] = createSignal<TrackReferenceOrPlaceholder[]>([]);

  createEffect(() => {
    const room = voice.stageRoom();
    if (!room) {
      setTrackReferences([]);
      return;
    }

    const subscription = trackReferencesObservable(
      room,
      [
        Track.Source.Microphone,
        Track.Source.ScreenShareAudio,
        Track.Source.Camera,
        Track.Source.ScreenShare,
        Track.Source.Unknown,
      ],
      { onlySubscribed: false }
    ).subscribe(({ trackReferences: refs }) => {
      setTrackReferences(refs);
    });

    onCleanup(() => subscription.unsubscribe());
  });

  return trackReferences;
}

function StageAudioTracks() {
  const state = useState();
  const trackReferences = useStageTrackReferences();

  const filteredTracks = createMemo(() =>
    trackReferences().filter(
      (track) =>
        !isLocal(track.participant) &&
        track.publication.kind === Track.Kind.Audio
    )
  );

  // Force subscription — autoSubscribe alone doesn't reliably deliver stage
  // feed audio to the audience room.
  createEffect(() => {
    for (const track of filteredTracks()) {
      const pub = track.publication;
      if (pub instanceof RemoteTrackPublication && !pub.isSubscribed) {
        console.info("[stage-bridge] Subscribing to stage audio track:", getTrackReferenceId(track));
        pub.setSubscribed(true);
      }
    }
  });

  return (
    <div style={{ display: "none" }}>
      <Key each={filteredTracks()} by={(item) => getTrackReferenceId(item)}>
        {(track) => (
          <AudioTrack
            trackRef={track()}
            volume={() => state.voice.outputVolume}
            muted={false}
            enableBoosting
          />
        )}
      </Key>
    </div>
  );
}

// Renders the stage feed's camera/screenshare video as a small floating
// overlay in the corner of the audience channel. `manageSubscription` on
// VideoTrack keeps it subscribed while visible and unsubscribes when the
// overlay is off-screen/hidden, so this doesn't need the manual
// setSubscribed() call StageAudioTracks needs.
function StageVideoOverlay() {
  const trackReferences = useStageTrackReferences();

  const filteredTracks = createMemo(() =>
    trackReferences().filter(
      (track) =>
        !isLocal(track.participant) &&
        track.publication.kind === Track.Kind.Video
    )
  );

  return (
    <Show when={filteredTracks().length > 0}>
      <div
        style={{
          position: "fixed",
          bottom: "88px",
          right: "16px",
          width: "280px",
          "z-index": 40,
          display: "flex",
          "flex-direction": "column",
          gap: "8px",
          "pointer-events": "none",
        }}
      >
        <Key each={filteredTracks()} by={(item) => getTrackReferenceId(item)}>
          {(track) => (
            <VideoTrack
              trackRef={track()}
              manageSubscription
              style={{
                width: "100%",
                "aspect-ratio": "16/9",
                "object-fit": "contain",
                "border-radius": "var(--borderRadius-lg, 8px)",
                background: "#000",
                "box-shadow": "0 4px 16px rgba(0,0,0,0.4)",
              }}
            />
          )}
        </Key>
      </div>
    </Show>
  );
}

CCTEOF_STAGEAUDIO

echo "  -> $CLIENT_DIR/packages/client/components/modal/modals/StageBridgeLinks.tsx"
mkdir -p "$(dirname "$CLIENT_DIR/packages/client/components/modal/modals/StageBridgeLinks.tsx")"
cat > "$CLIENT_DIR/packages/client/components/modal/modals/StageBridgeLinks.tsx" << 'CCTEOF_STAGEBRIDGELINKS'
// StageBridgeLinks.tsx
// Multi-select picker for linking audience channels to a stage voice channel.
// Drop this file in: packages/client/components/modal/modals/StageBridgeLinks.tsx

import { createSignal, createMemo, For, Show } from "solid-js";
import { styled } from "styled-system/jsx";
import type { Channel, Server } from "revolt.js";

const BRIDGE_URL =
  (import.meta.env.VITE_STAGE_BRIDGE_URL as string | undefined) ??
  "/stage-bridge";

// ── Styled components ─────────────────────────────────────────────────────────

const Section = styled("div", {
  base: {
    display: "flex",
    flexDirection: "column",
    gap: "var(--gap-sm)",
    marginTop: "var(--gap-md)",
  },
});

const Label = styled("span", {
  base: {
    fontSize: "12px",
    fontWeight: "600",
    color: "var(--md-sys-color-on-surface-variant)",
    textTransform: "uppercase",
    letterSpacing: "0.05em",
  },
});

const ChannelList = styled("div", {
  base: {
    display: "flex",
    flexDirection: "column",
    gap: "var(--gap-xs)",
    maxHeight: "160px",
    overflowY: "auto",
    background: "var(--md-sys-color-surface-container)",
    borderRadius: "var(--borderRadius-md)",
    padding: "var(--gap-sm)",
  },
});

const ChannelRow = styled("label", {
  base: {
    display: "flex",
    alignItems: "center",
    gap: "var(--gap-sm)",
    cursor: "pointer",
    padding: "var(--gap-xs) var(--gap-sm)",
    borderRadius: "var(--borderRadius-sm)",
    userSelect: "none",
  },
});

const ChannelName = styled("span", {
  base: {
    fontSize: "14px",
    color: "var(--md-sys-color-on-surface)",
  },
});

const EmptyHint = styled("span", {
  base: {
    fontSize: "13px",
    color: "var(--md-sys-color-on-surface-variant)",
    fontStyle: "italic",
    padding: "var(--gap-xs)",
  },
});

// ── Component ─────────────────────────────────────────────────────────────────

interface Props {
  server: Server;
  excludeChannelId?: string;
  selected: string[];
  onChange: (ids: string[]) => void;
}

export function StageBridgeLinks(props: Props) {
  const voiceChannels = createMemo(() =>
    (props.server.orderedChannels ?? [])
      .flatMap((category: any) => category.channels ?? [])
      .filter(
        (ch: any) =>
          ch !== undefined &&
          ch.type === "VoiceChannel" &&
          ch.id !== props.excludeChannelId
      )
    );

  function toggle(channelId: string) {
    const current = props.selected;
    if (current.includes(channelId)) {
      props.onChange(current.filter((id) => id !== channelId));
    } else {
      props.onChange([...current, channelId]);
    }
  }

  return (
    <Section>
      <Label>
        Audience Channels
      </Label>
      <ChannelList>
        <Show
          when={voiceChannels().length > 0}
          fallback={
            <EmptyHint>
              No other voice channels to link
            </EmptyHint>
          }
        >
          <For each={voiceChannels()}>
            {(channel) => (
              <ChannelRow>
                <input
                  type="checkbox"
                  checked={props.selected.includes(channel.id)}
                  onChange={() => toggle(channel.id)}
                />
                <ChannelName># {channel.name}</ChannelName>
              </ChannelRow>
            )}
          </For>
        </Show>
      </ChannelList>
    </Section>
  );
}

// ── Helper: save links to stage-bridge ───────────────────────────────────────

export async function saveStageBridgeLinks(
  stageChannelId: string,
  audienceChannelIds: string[]
): Promise<void> {
  if (audienceChannelIds.length === 0) {
    // No audience channels selected — clear any existing links rather than
    // silently no-op'ing and leaving stale links active on the server.
    const response = await fetch(`${BRIDGE_URL}/links/${stageChannelId}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      console.error(
        `[stage-bridge] Failed to clear links for ${stageChannelId}:`,
        await response.text()
      );
    }
    return;
  }

  const response = await fetch(`${BRIDGE_URL}/links/${stageChannelId}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ linked_audience: audienceChannelIds }),
  });

  if (!response.ok) {
    console.error(
      `[stage-bridge] Failed to save links for ${stageChannelId}:`,
      await response.text()
    );
  }
}

CCTEOF_STAGEBRIDGELINKS

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
  await db.collection("cct_admin_users").updateOne(
    { userId },
    { $set: { userId, username: user.username, promotedAt: new Date(), promotedBy: req.admin.username } },
    { upsert: true }
  );
  res.json({ ok: true, message: `${user.username} can now log into the admin panel` });
});

app.post("/api/admin/users/:id/demote", requireAdmin, async (req, res) => {
  if (!db) return res.status(503).json({ error: "DB not connected" });
  await db.collection("cct_admin_users").deleteOne({ userId: req.params.id });
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
  document.getElementById('devNavSec').style.display = ME.roles.includes('developer') || ME.roles.includes('admin') ? 'flex' : 'none';
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

echo "  -> $STOAT_DIR/compose.yml"
mkdir -p "$(dirname "$STOAT_DIR/compose.yml")"
cat > "$STOAT_DIR/compose.yml" << 'CCTEOF_COMPOSEYML'
name: stoat

services:
  # MongoDB: Database
  database:
    image: docker.io/mongo
    restart: always
    volumes:
      - ./data/db:/data/db
    healthcheck:
      test: echo 'db.runCommand("ping").ok' | mongosh localhost:27017/test --quiet
      interval: 10s
      timeout: 10s
      retries: 5
      start_period: 10s

  # Redis: Event message broker & KV store
  redis:
    image: docker.io/eqalpha/keydb
    restart: always
    healthcheck:
      test: redis-cli ping
      interval: 5s
      timeout: 5s
      retries: 5

  # RabbitMQ: Internal message broker
  rabbit:
    image: docker.io/rabbitmq:4-management
    restart: always
    environment:
      RABBITMQ_DEFAULT_USER: rabbituser
      RABBITMQ_DEFAULT_PASS: rabbitpass
    volumes:
      - ./data/rabbit:/var/lib/rabbitmq
    healthcheck:
      test: rabbitmq-diagnostics check_port_connectivity
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 60s

  # MinIO: S3-compatible storage server
  minio:
    image: docker.io/minio/minio
    command: server /data
    volumes:
      - ./data/minio:/data
    environment:
      MINIO_ROOT_USER: minioautumn
      MINIO_ROOT_PASSWORD: minioautumn
      MINIO_DOMAIN: minio
    networks:
      default:
        aliases:
          - revolt-uploads.minio
          # legacy support:
          - attachments.minio
          - avatars.minio
          - backgrounds.minio
          - icons.minio
          - banners.minio
          - emojis.minio
    restart: always

  # Caddy: Web server
  caddy:
    image: docker.io/caddy
    restart: always
    env_file: .env.web
    ports:
      - "88:80"
      - "448:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./data/caddy-data:/data
      - ./data/caddy-config:/config
    networks:
      default:
        aliases:
          - cct.wtf

  # API server
  api:
    image: ghcr.io/stoatchat/api:v0.13.5
    extra_hosts:
      - "cct.wtf:172.18.0.1"
    env_file: secrets.env
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
      rabbit:
        condition: service_healthy
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # Events service
  events:
    image: ghcr.io/stoatchat/events:v0.13.5
    env_file: secrets.env
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # File server
  autumn:
    image: ghcr.io/stoatchat/file-server:v0.13.5
    env_file: secrets.env
    depends_on:
      database:
        condition: service_healthy
      createbuckets:
        condition: service_started
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # Metadata and image proxy
  january:
    image: ghcr.io/stoatchat/proxy:v0.13.5
    env_file: secrets.env
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    dns:
      - 1.1.1.1
      - 8.8.8.8
    restart: always

  gifbox:
    image: ghcr.io/stoatchat/gifbox:v0.13.5
    env_file: secrets.env
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # Regular task daemon
  crond:
    image: ghcr.io/stoatchat/crond:v0.13.5
    env_file: secrets.env
    depends_on:
      database:
        condition: service_healthy
      rabbit-init:
        condition: service_completed_successfully
      minio:
        condition: service_started
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # Push notification daemon
  pushd:
    image: ghcr.io/stoatchat/pushd:v0.13.5
    env_file: secrets.env
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy
      rabbit:
        condition: service_healthy
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml
    restart: always

  # Voice ingress daemon
  voice-ingress:
    image: ghcr.io/stoatchat/voice-ingress:latest
    env_file: secrets.env
    restart: on-failure
    depends_on:
      rabbit-init:
        condition: service_completed_successfully
      database:
        condition: service_healthy
      livekit:
        condition: service_started
    volumes:
      - type: bind
        source: ./Revolt.toml
        target: /Revolt.toml

  livekit:
    image: ghcr.io/stoatchat/livekit-server:v1.9.13
    depends_on:
      redis:
        condition: service_healthy
    command: --config /etc/livekit.yml
    ports:
      - "7880:7880/tcp"
      - "7881:7881/tcp"
      - "3478:3478/udp"
      - "50000-50100:50000-50100/udp"
    restart: always
    volumes:
      - type: bind
        source: ./livekit.yml
        target: /etc/livekit.yml

  # Create buckets for minio.
  createbuckets:
    image: docker.io/minio/mc
    depends_on:
      - minio
    entrypoint: >
      /bin/sh -c "
      while ! /usr/bin/mc ready minio; do
        /usr/bin/mc alias set minio http://minio:9000 minioautumn minioautumn;
        echo 'Waiting minio...' && sleep 1;
      done;
      /usr/bin/mc mb minio/revolt-uploads;
      exit 0;
      "

  # Web App
  web:
    image: cct-frontend
    restart: always
    env_file: .env.web

  stage-bridge:
    build:
      context: ./stage-bridge
    restart: always
    environment:
      - LIVEKIT_URL=ws://livekit:7880
      - LIVEKIT_API_KEY=fe2acd880f5f
      - LIVEKIT_API_SECRET=962afc05bf11b1ac44f7613824f125f3f94a9c60edef848d
      - REDIS_URL=redis://redis:6379
      - PORT=8600
    depends_on:
      livekit:
        condition: service_started
      redis:
        condition: service_healthy

  # Dev sandbox orchestrator: spins up per-developer preview containers,
  # manages git worktrees, and handles GitHub submit + production deploy.
  # No published port and no public Caddy route to its management API —
  # only the `web` admin panel talks to it (internal docker network), using
  # DEV_ORCHESTRATOR_SECRET. The live-preview traffic (/sandbox/*) IS routed
  # publicly by Caddy straight to this service; see Caddyfile.
  dev-orchestrator:
    build:
      context: ./dev-orchestrator
    restart: always
    environment:
      - PORT=8700
      - DEV_ORCHESTRATOR_SECRET=${DEV_ORCHESTRATOR_SECRET}
      - DEV_WORKSPACES_DIR=/data/dev-workspaces
      - DEV_BARE_REPO_DIR=/data/dev-bare-repo.git
      - CLIENT_REPO_URL=${CLIENT_REPO_URL}
      - CLIENT_REPO_BRANCH=${CLIENT_REPO_BRANCH:-main}
      - GITHUB_BOT_TOKEN=${GITHUB_BOT_TOKEN}
      - GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER}
      - GITHUB_REPO_NAME=${GITHUB_REPO_NAME}
      - SANDBOX_IMAGE=cct-sandbox
      - SANDBOX_NETWORK=stoat_default
      - DEV_SESSION_IDLE_MINUTES=${DEV_SESSION_IDLE_MINUTES:-45}
      - DEPLOY_CLIENT_DIR=/deploy/client
      - DEPLOY_STOAT_DIR=/deploy/stoat
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data/dev-workspaces:/data/dev-workspaces
      - ./data/dev-bare-repo.git:/data/dev-bare-repo.git
      # Your real, persistent working clones — the ones deploy.js builds
      # and restarts `web` from. Point these at wherever ~/client and
      # ~/stoat actually live on the host.
      - ${CLIENT_WORKING_DIR:-../client}:/deploy/client
      - .:/deploy/stoat

  dicebot:
    build: /root/dicebot/dicebot
    restart: unless-stopped
    environment:
      - REVOLT_BOT_TOKEN=TGgvBOI7I73x7SM1R0W4Zawf45ITglnsu-kAlKZp3RpHrnhZfhzQLcv-MqmL44aR
      - REVOLT_API_URL=https://cct.wtf/api
    depends_on:
      - api


  rabbit-init:
    image: curlimages/curl
    depends_on:
      rabbit:
        condition: service_healthy
    restart: "no"
    entrypoint: >
      sh -c "
        curl -sf -u rabbituser:rabbitpass -X PUT http://rabbit:15672/api/exchanges/%2F/revolt.default -H 'Content-Type: application/json' -d '{\"type\":\"topic\",\"durable\":true}' &&
        curl -sf -u rabbituser:rabbitpass -X PUT http://rabbit:15672/api/queues/%2F/internal.ack-prd -H 'Content-Type: application/json' -d '{\"durable\":true}' &&
        curl -sf -u rabbituser:rabbitpass -X POST http://rabbit:15672/api/bindings/%2F/e/revolt.default/q/internal.ack-prd -H 'Content-Type: application/json' -d '{\"routing_key\":\"internal.ack-prd\"}' &&
        echo 'RabbitMQ init complete'
      "


  ack-processor:
    build:
      context: ./ack-processor
    restart: always
    environment:
      - AMQP_URL=amqp://rabbituser:rabbitpass@rabbit:5672/
      - MONGO_URL=mongodb://database:27017
      - MONGO_DB=revolt
      - QUEUE_NAME=internal.ack-prd
    depends_on:
      database:
        condition: service_healthy
      rabbit:
        condition: service_healthy
      rabbit-init:
        condition: service_completed_successfully

CCTEOF_COMPOSEYML

echo "  -> $STOAT_DIR/Caddyfile"
mkdir -p "$(dirname "$STOAT_DIR/Caddyfile")"
cat > "$STOAT_DIR/Caddyfile" << 'CCTEOF_CADDYFILE'
{
   servers {
       max_header_size 5GB
   }
}
:80 {
	route /api/admin* {
		reverse_proxy http://web:5000
	}

	route /api* {
		uri strip_prefix /api
		reverse_proxy http://api:14702 {
			header_down Location "^/" "/api/"
		}
	}
	route /ws {
		uri strip_prefix /ws
		reverse_proxy http://events:14703 {
			header_down Location "^/" "/ws/"
		}
	}
	route /autumn* {
		uri strip_prefix /autumn
		request_body {
		    max_size 0
		}
		reverse_proxy http://autumn:14704 {
			header_down Location "^/" "/autumn/"
		}
	}
	route /january* {
		uri strip_prefix /january
		reverse_proxy http://january:14705 {
			header_down Location "^/" "/january/"
		}
	}
	route /livekit* {
		uri strip_prefix /livekit
		reverse_proxy http://livekit:7880 {
			header_up Host {host}
			header_up X-Real-IP {remote_host}
			header_up Connection "Upgrade"
			header_up Upgrade $http_upgrade
		}
	}
	route /ingress* {
		uri strip_prefix /ingress
		reverse_proxy http://voice-ingress:8500 {
			header_down Location "^/" "/ingress/"
		}
	}
        
	route /stage-bridge* {
		uri strip_prefix /stage-bridge
		reverse_proxy http://stage-bridge:8600 {
			header_down Location "^/" "/stage-bridge/"
		}
	}

	# Dev sandbox live preview only — session management endpoints
	# (create/delete/github-submit/deploy) are NOT routed here, they only
	# exist on the internal docker network for the `web` admin panel to
	# call. This route is websocket-aware for Vite's HMR client.
	route /sandbox* {
		reverse_proxy http://dev-orchestrator:8700 {
			header_up Connection "Upgrade"
			header_up Upgrade {http.request.header.Upgrade}
		}
	}
	
	reverse_proxy http://web:5000
}

CCTEOF_CADDYFILE

echo "  -> $STOAT_DIR/dev-orchestrator/package.json"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/package.json")"
cat > "$STOAT_DIR/dev-orchestrator/package.json" << 'CCTEOF_DOPKGJSON'
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
    "http-proxy": "^1.18.1"
  }
}

CCTEOF_DOPKGJSON

echo "  -> $STOAT_DIR/dev-orchestrator/Dockerfile"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/Dockerfile")"
cat > "$STOAT_DIR/dev-orchestrator/Dockerfile" << 'CCTEOF_DODOCKERFILE'
FROM node:20-bookworm-slim

# git — for worktree management
# docker CLI + compose plugin — this container talks to the host Docker
# daemon via the bind-mounted /var/run/docker.sock, it needs the client
# binaries to do so (this does NOT install/run a nested Docker daemon)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl gnupg \
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

CCTEOF_DODOCKERFILE

echo "  -> $STOAT_DIR/dev-orchestrator/src/config.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/config.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/config.js" << 'CCTEOF_DOCONFIG'
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

CCTEOF_DOCONFIG

echo "  -> $STOAT_DIR/dev-orchestrator/src/git.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/git.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/git.js" << 'CCTEOF_DOGIT'
// git.js
// Manages the persistent bare mirror + per-session git worktrees.
// Everything shells out to the real `git` CLI on purpose — it's the same
// commands you'd run by hand, so `git -C <path> status` etc. always works
// for debugging on the box directly.

const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");
const config = require("./config");

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { maxBuffer: 1024 * 1024 * 64, ...opts }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        return reject(err);
      }
      resolve({ stdout, stderr });
    });
  });
}

// Ensure the bare mirror exists and is up to date. Called before creating
// any new worktree so sessions always branch off current main.
async function sync_bare_repo() {
  if (!fs.existsSync(config.bare_repo_dir)) {
    console.log("[git] Bare mirror missing, cloning fresh:", config.client_repo_url);
    fs.mkdirSync(path.dirname(config.bare_repo_dir), { recursive: true });
    await run("git", ["clone", "--bare", config.client_repo_url, config.bare_repo_dir]);
  } else {
    console.log("[git] Fetching latest into bare mirror");
    await run("git", ["--git-dir", config.bare_repo_dir, "fetch", "--prune", "origin"]);
  }
}

function slugify(username) {
  return String(username).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "dev";
}

// Creates a new worktree on a fresh branch off origin/<client_repo_branch>,
// then initializes submodules inside it (stoat.js, solid-livekit-components,
// assets, js-lingui-solid — none of these are vendored, they're real
// submodules per .gitmodules).
async function create_worktree(session_id, username) {
  await sync_bare_repo();

  const branch = `dev/${slugify(username)}/${Date.now()}`;
  const worktree_path = path.join(config.workspaces_dir, session_id);

  fs.mkdirSync(config.workspaces_dir, { recursive: true });

  console.log(`[git] Creating worktree ${worktree_path} on branch ${branch}`);
  await run("git", [
    "--git-dir", config.bare_repo_dir,
    "worktree", "add", "-b", branch, worktree_path,
    `origin/${config.client_repo_branch}`,
  ]);

  console.log(`[git] Initializing submodules in ${worktree_path}`);
  await run("git", ["submodule", "update", "--init", "--recursive"], { cwd: worktree_path });

  return { branch, worktree_path };
}

async function remove_worktree(worktree_path) {
  try {
    await run("git", ["--git-dir", config.bare_repo_dir, "worktree", "remove", "--force", worktree_path]);
  } catch (e) {
    console.warn("[git] worktree remove failed, falling back to rm -rf:", e.message);
    fs.rmSync(worktree_path, { recursive: true, force: true });
    try {
      await run("git", ["--git-dir", config.bare_repo_dir, "worktree", "prune"]);
    } catch {}
  }
}

// Commits whatever's currently in the worktree and pushes the branch.
// Returns false if there was nothing to commit.
async function commit_and_push(worktree_path, branch, message) {
  await run("git", ["add", "-A"], { cwd: worktree_path });

  const status = await run("git", ["status", "--porcelain"], { cwd: worktree_path });
  if (!status.stdout.trim()) {
    return false;
  }

  await run("git", ["-c", "user.email=cct-dev-bot@cct.wtf", "-c", "user.name=CCT Dev Bot",
    "commit", "-m", message], { cwd: worktree_path });

  // Push using the bot token over HTTPS without ever writing it into the
  // worktree's git config (avoid the token ending up in a commit or log).
  const push_url = config.client_repo_url.replace(
    "https://",
    `https://x-access-token:${config.github.token}@`
  );
  await run("git", ["push", push_url, `HEAD:refs/heads/${branch}`], { cwd: worktree_path });

  return true;
}

module.exports = { sync_bare_repo, create_worktree, remove_worktree, commit_and_push, slugify };

CCTEOF_DOGIT

echo "  -> $STOAT_DIR/dev-orchestrator/src/docker.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/docker.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/docker.js" << 'CCTEOF_DODOCKERJS'
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

CCTEOF_DODOCKERJS

echo "  -> $STOAT_DIR/dev-orchestrator/src/github.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/github.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/github.js" << 'CCTEOF_DOGITHUB'
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

CCTEOF_DOGITHUB

echo "  -> $STOAT_DIR/dev-orchestrator/src/sessions.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/sessions.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/sessions.js" << 'CCTEOF_DOSESSIONS'
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

CCTEOF_DOSESSIONS

echo "  -> $STOAT_DIR/dev-orchestrator/src/proxy.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/proxy.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/proxy.js" << 'CCTEOF_DOPROXY'
// proxy.js
// Proxies /sandbox/:sessionId/* (HTTP + WebSocket, the latter needed for
// Vite's HMR client) straight through to that session's container over the
// docker network, by container name — no host ports are published for
// sandbox containers at all, this proxy is the only way in.
//
// Auth here is the per-session preview_token (query param `t=`), not the
// admin JWT — the browser tab showing the live preview is just an <iframe>,
// it doesn't carry the admin panel's Authorization header.

const httpProxy = require("http-proxy");
const sessions = require("./sessions");
const docker = require("./docker");
const config = require("./config");

const proxy = httpProxy.createProxyServer({ ws: true, changeOrigin: true });

proxy.on("error", (err, req, res) => {
  console.warn("[proxy] Error:", err.message);
  if (res && res.writeHead) {
    res.writeHead(502, { "Content-Type": "text/plain" });
    res.end("Sandbox preview unavailable (session may have ended).");
  }
});

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

  req.url = parsed.rest;
  proxy.ws(req, socket, head, { target: `http://${session.container_name}:${config.sandbox.port}` });
}

module.exports = { handle_http, handle_upgrade };

CCTEOF_DOPROXY

echo "  -> $STOAT_DIR/dev-orchestrator/src/deploy.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/deploy.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/deploy.js" << 'CCTEOF_DODEPLOY'
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

CCTEOF_DODEPLOY

echo "  -> $STOAT_DIR/dev-orchestrator/src/server.js"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/src/server.js")"
cat > "$STOAT_DIR/dev-orchestrator/src/server.js" << 'CCTEOF_DOSERVER'
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

CCTEOF_DOSERVER

echo "  -> $STOAT_DIR/dev-orchestrator/sandbox-image/Dockerfile"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/sandbox-image/Dockerfile")"
cat > "$STOAT_DIR/dev-orchestrator/sandbox-image/Dockerfile" << 'CCTEOF_SANDBOXDOCKERFILE'
FROM node:22-bookworm-slim

# git — needed at runtime for `git submodule` status checks some tooling does,
# and generally useful if you shell into a running sandbox to poke around.
# python3/make/g++ — some transitive deps (e.g. better-sqlite3-likes) need a
# native build step.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173
ENTRYPOINT ["/entrypoint.sh"]

CCTEOF_SANDBOXDOCKERFILE

echo "  -> $STOAT_DIR/dev-orchestrator/sandbox-image/entrypoint.sh"
mkdir -p "$(dirname "$STOAT_DIR/dev-orchestrator/sandbox-image/entrypoint.sh")"
cat > "$STOAT_DIR/dev-orchestrator/sandbox-image/entrypoint.sh" << 'CCTEOF_SANDBOXENTRYPOINT'
#!/usr/bin/env bash
# Runs the real CCT client dev server against whatever worktree is bind-
# mounted at /workspace. This mirrors .mise/tasks/dev + its dependencies
# exactly (install:assets, the submodule package builds, then vite) rather
# than reinventing the build — if the mise tasks change, update this too.
set -e
cd /workspace

echo "[sandbox] Installing dependencies (pnpm install)..."
pnpm install --no-frozen-lockfile

echo "[sandbox] Setting up client assets..."
pnpm --filter client exec node scripts/copyAssets.mjs || echo "[sandbox] asset copy skipped (non-fatal)"

echo "[sandbox] Building workspace dependencies..."
pnpm --filter stoat.js build || echo "[sandbox] stoat.js build failed (non-fatal, continuing)"
pnpm --filter solid-livekit-components build || echo "[sandbox] solid-livekit-components build failed (non-fatal, continuing)"
pnpm --filter @lingui-solid/babel-plugin-lingui-macro build || true
pnpm --filter @lingui-solid/babel-plugin-extract-messages build || true

echo "[sandbox] Starting dev server on 0.0.0.0:${PORT:-5173}"
exec pnpm --filter client exec vite --host 0.0.0.0 --port "${PORT:-5173}"

CCTEOF_SANDBOXENTRYPOINT


echo "==> Files written."
echo "==> Building sandbox image (cct-sandbox)..."
(cd "$STOAT_DIR/dev-orchestrator/sandbox-image" && docker build -t cct-sandbox .)

echo "==> Rebuilding admin/web frontend image..."
(cd "$CLIENT_DIR" && docker build --no-cache -t cct-frontend .)

echo "==> Restarting web + (re)building dev-orchestrator..."
(cd "$STOAT_DIR" && docker compose up -d web)
(cd "$STOAT_DIR" && docker compose up -d --build dev-orchestrator || true)

cat << 'NEXT'

==> Done writing + building.

If dev-orchestrator failed to start just now, that is expected until you've
added its required secrets to ~/stoat/secrets.env:

  DEV_ORCHESTRATOR_SECRET       (openssl rand -hex 32)
  CLIENT_REPO_URL
  CLIENT_REPO_BRANCH            (default: main)
  GITHUB_BOT_TOKEN
  GITHUB_REPO_OWNER
  GITHUB_REPO_NAME
  PRODUCTION_DEPLOY_USER_IDS    (your Revolt user _id)
  CLIENT_WORKING_DIR            (default: ../client)

Once secrets.env is filled in:
  cd $STOAT_DIR && docker compose up -d dev-orchestrator

Full details: see DEV_SANDBOX_SETUP.md
NEXT
