// api.ts
// Small REST API for managing Stage→Audience link relationships.
// The Stoat frontend calls these endpoints from the channel settings UI.
//
// Endpoints:
//   GET    /links/:stageChannelId          → get all linked audience channels
//   PUT    /links/:stageChannelId          → replace all links (full save from UI)
//   POST   /links/:stageChannelId/:target  → add a single audience channel
//   DELETE /links/:stageChannelId/:target  → remove a single audience channel
//   GET    /status                         → health check + active sessions

import { Router, Request, Response } from "express";
import { get_links, set_links, add_links, remove_link, clear_links } from "./store";
import { get_active_sessions } from "./bridge";

export const api_router = Router();

// GET /links/:stageChannelId
// Returns the list of audience channels linked to a stage channel
api_router.get("/links/:stageChannelId", async (req: Request, res: Response) => {
  const { stageChannelId } = req.params;

  try {
    const links = await get_links(stageChannelId);
    res.json({ stage_channel_id: stageChannelId, linked_audience: links });
  } catch (e) {
    console.error("[api] Error fetching links:", e);
    res.status(500).json({ error: "Failed to fetch links" });
  }
});

// PUT /links/:stageChannelId
// Body: { "linked_audience": ["channel-id-1", "channel-id-2"] }
// Replaces the full link list — this is what the UI calls on save
api_router.put("/links/:stageChannelId", async (req: Request, res: Response) => {
  const { stageChannelId } = req.params;
  const body = req.body as { linked_audience?: string[] };

  if (!Array.isArray(body.linked_audience)) {
    res.status(400).json({ error: "linked_audience must be an array" });
    return;
  }

  // Validate that all entries are non-empty strings
  const invalid = body.linked_audience.filter(
    (id) => typeof id !== "string" || id.trim() === ""
  );
  if (invalid.length > 0) {
    res.status(400).json({ error: "All channel IDs must be non-empty strings" });
    return;
  }

  try {
    await set_links(stageChannelId, body.linked_audience);
    const links = await get_links(stageChannelId);
    res.json({ stage_channel_id: stageChannelId, linked_audience: links });
  } catch (e) {
    console.error("[api] Error setting links:", e);
    res.status(500).json({ error: "Failed to set links" });
  }
});

// POST /links/:stageChannelId/:audienceChannelId
// Adds a single audience channel to a stage's link list
api_router.post(
  "/links/:stageChannelId/:audienceChannelId",
  async (req: Request, res: Response) => {
    const { stageChannelId, audienceChannelId } = req.params;

    try {
      await add_links(stageChannelId, [audienceChannelId]);
      const links = await get_links(stageChannelId);
      res.json({ stage_channel_id: stageChannelId, linked_audience: links });
    } catch (e) {
      console.error("[api] Error adding link:", e);
      res.status(500).json({ error: "Failed to add link" });
    }
  }
);

// DELETE /links/:stageChannelId/:audienceChannelId
// Removes a single audience channel from a stage's link list
api_router.delete(
  "/links/:stageChannelId/:audienceChannelId",
  async (req: Request, res: Response) => {
    const { stageChannelId, audienceChannelId } = req.params;

    try {
      await remove_link(stageChannelId, audienceChannelId);
      const links = await get_links(stageChannelId);
      res.json({ stage_channel_id: stageChannelId, linked_audience: links });
    } catch (e) {
      console.error("[api] Error removing link:", e);
      res.status(500).json({ error: "Failed to remove link" });
    }
  }
);

// DELETE /links/:stageChannelId
// Removes all links for a stage channel
api_router.delete("/links/:stageChannelId", async (req: Request, res: Response) => {
  const { stageChannelId } = req.params;

  try {
    await clear_links(stageChannelId);
    res.json({ stage_channel_id: stageChannelId, linked_audience: [] });
  } catch (e) {
    console.error("[api] Error clearing links:", e);
    res.status(500).json({ error: "Failed to clear links" });
  }
});

// GET /status
// Health check — returns active bridge sessions
api_router.get("/status", (_req: Request, res: Response) => {
  res.json({
    status: "ok",
    active_bridges: get_active_sessions(),
  });
});
