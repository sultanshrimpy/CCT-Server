// store.ts
// Manages the link relationships between Stage channels and Audience channels.
// All data lives in Redis so it survives restarts and is shared if you ever
// run multiple stage-bridge instances.
//
// Data structure:
//   stage_links:<stageChannelId>  →  Redis Set of audience channel IDs
//
// Example:
//   stage_links:stage-a  →  { "audience-1", "audience-2" }
//   stage_links:stage-b  →  { "audience-1", "audience-3" }

import Redis from "ioredis";
import { config } from "./config";

const redis = new Redis(config.redis.url);

redis.on("error", (err) => {
  console.error("[store] Redis error:", err);
});

redis.on("connect", () => {
  console.log("[store] Connected to Redis");
});

function key(stageChannelId: string): string {
  return `stage_links:${stageChannelId}`;
}

// Returns all audience channel IDs linked to a given stage channel
export async function get_links(stageChannelId: string): Promise<string[]> {
  return redis.smembers(key(stageChannelId));
}

// Links one or more audience channels to a stage channel.
// Calling this multiple times is safe — it's a set, no duplicates.
export async function add_links(
  stageChannelId: string,
  audienceChannelIds: string[]
): Promise<void> {
  if (audienceChannelIds.length === 0) return;
  await redis.sadd(key(stageChannelId), ...audienceChannelIds);
}

// Removes a single audience channel from a stage's link list
export async function remove_link(
  stageChannelId: string,
  audienceChannelId: string
): Promise<void> {
  await redis.srem(key(stageChannelId), audienceChannelId);
}

// Replaces all links for a stage channel in one atomic operation.
// Used when the user saves the full list from the UI.
export async function set_links(
  stageChannelId: string,
  audienceChannelIds: string[]
): Promise<void> {
  const k = key(stageChannelId);
  // Use a pipeline so both operations are atomic
  const pipeline = redis.pipeline();
  pipeline.del(k);
  if (audienceChannelIds.length > 0) {
    pipeline.sadd(k, ...audienceChannelIds);
  }
  await pipeline.exec();
}

// Removes all links for a stage channel entirely
export async function clear_links(stageChannelId: string): Promise<void> {
  await redis.del(key(stageChannelId));
}

// Returns every stage channel that has at least one link configured.
// Used on startup to check if any bridges need to be restored.
export async function get_all_stage_ids(): Promise<string[]> {
  const keys = await redis.keys("stage_links:*");
  return keys.map((k) => k.replace("stage_links:", ""));
}
