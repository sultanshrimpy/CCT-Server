// bridge.ts
// Uses LiveKit RoomService to write stage feed metadata into audience rooms.
// The frontend reads this metadata and connects to the stage room as a
// subscriber-only participant to receive audio.

import { RoomServiceClient, AccessToken } from "livekit-server-sdk";
import { config } from "./config";

const room_service = new RoomServiceClient(
  config.livekit.url.replace(/^ws(s)?:\/\//, "http$1://"),
  config.livekit.api_key,
  config.livekit.api_secret
);

interface ActiveBridge {
  stage_channel_id: string;
  audience_channel_ids: string[];
}

const active_sessions: Map<string, ActiveBridge> = new Map();

export async function start_bridge(
  stage_channel_id: string,
  audience_channel_ids: string[]
): Promise<void> {
  if (active_sessions.has(stage_channel_id)) {
    console.log(`[bridge] Session already active for ${stage_channel_id}, skipping`);
    return;
  }

  active_sessions.set(stage_channel_id, { stage_channel_id, audience_channel_ids });

  console.log(
    `[bridge] Starting bridge: stage=${stage_channel_id} ` +
    `→ audiences=[${audience_channel_ids.join(", ")}]`
  );

  for (const audience_id of audience_channel_ids) {
    try {
      await room_service.updateRoomMetadata(
        audience_id,
        JSON.stringify({ stage_feed: stage_channel_id, stage_active: true })
      );
      console.log(
        `[bridge] Set stage feed metadata on audience room ${audience_id} ` +
        `→ stage=${stage_channel_id}`
      );
    } catch (e) {
      console.warn(
        `[bridge] Could not update metadata for audience room ${audience_id} ` +
        `(room may not exist yet):`, e
      );
    }
  }
}

export async function stop_bridge(stage_channel_id: string): Promise<void> {
  const session = active_sessions.get(stage_channel_id);
  if (!session) {
    console.log(`[bridge] No active session for ${stage_channel_id}, nothing to stop`);
    return;
  }

  console.log(`[bridge] Stopping bridge for stage=${stage_channel_id}`);

  for (const audience_id of session.audience_channel_ids) {
    try {
      await room_service.updateRoomMetadata(
        audience_id,
        JSON.stringify({ stage_feed: null, stage_active: false })
      );
      console.log(`[bridge] Cleared stage feed metadata on audience room ${audience_id}`);
    } catch (e) {
      console.warn(`[bridge] Could not clear metadata for ${audience_id}:`, e);
    }
  }

  active_sessions.delete(stage_channel_id);
}

export function get_active_sessions(): string[] {
  return Array.from(active_sessions.keys());
}

export function get_session(stage_channel_id: string): ActiveBridge | undefined {
  return active_sessions.get(stage_channel_id);
}

export async function apply_pending_metadata(audience_channel_id: string): Promise<void> {
  for (const [stage_id, session] of active_sessions) {
    if (session.audience_channel_ids.includes(audience_channel_id)) {
      console.log(
        `[bridge] Applying pending metadata to late-joining audience room ${audience_channel_id}`
      );
      try {
        await room_service.updateRoomMetadata(
          audience_channel_id,
          JSON.stringify({ stage_feed: stage_id, stage_active: true })
        );
      } catch (e) {
        console.warn(
          `[bridge] Still could not update metadata for ${audience_channel_id}:`, e
        );
      }
      return;
    }
  }
}

export async function make_audience_token(
  stage_channel_id: string,
  user_identity: string
): Promise<string> {
  const token = new AccessToken(
    config.livekit.api_key,
    config.livekit.api_secret,
    { identity: user_identity }
  );
  token.addGrant({
    roomJoin: true,
    room: stage_channel_id,
    canPublish: false,
    canSubscribe: true,
    canPublishData: false,
  });
  return await token.toJwt();
}
