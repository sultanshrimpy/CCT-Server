// bridge.ts
import {
  Room,
  RoomEvent,
  RemoteTrack,
  RemoteTrackPublication,
  RemoteParticipant,
} from "@livekit/rtc-node";
import { AccessToken } from "livekit-server-sdk";
import { config } from "./config";

interface AudiencePipe {
  channelId: string;
  room: Room;
  published_tracks: Map<string, RemoteTrack>;
}

export class BridgeSession {
  private stage_room: Room;
  private audience_pipes: Map<string, AudiencePipe> = new Map();
  private is_torn_down = false;

  constructor(
    private stage_channel_id: string,
    private audience_channel_ids: string[]
  ) {
    this.stage_room = new Room();
  }

  async start(): Promise<void> {
    console.log(
      `[bridge] Starting session for stage=${this.stage_channel_id} ` +
      `→ audiences=[${this.audience_channel_ids.join(", ")}]`
    );

    for (const audience_id of this.audience_channel_ids) {
      await this.connect_audience(audience_id);
    }

    this.stage_room.on(
      RoomEvent.TrackSubscribed,
      (track: RemoteTrack, pub: RemoteTrackPublication, participant: RemoteParticipant) => {
        void this.on_track_subscribed(track, pub, participant);
      }
    );

    this.stage_room.on(
      RoomEvent.TrackUnsubscribed,
      (track: RemoteTrack, pub: RemoteTrackPublication, participant: RemoteParticipant) => {
        void this.on_track_unsubscribed(track, pub, participant);
      }
    );

    this.stage_room.on(RoomEvent.Disconnected, () => {
      console.log(`[bridge] Stage room ${this.stage_channel_id} disconnected`);
      void this.teardown();
    });

    const stage_token = this.make_token(this.stage_channel_id, {
      canPublish: false,
      canSubscribe: true,
    });

    await this.stage_room.connect(config.livekit.url, stage_token);
    console.log(`[bridge] Bot connected to stage room ${this.stage_channel_id}`);
  }

  private async on_track_subscribed(
    track: RemoteTrack,
    pub: RemoteTrackPublication,
    participant: RemoteParticipant
  ): Promise<void> {
    console.log(
      `[bridge] Track subscribed: kind=${track.kind} ` +
      `participant=${participant.identity} sid=${pub.sid}`
    );
    for (const pipe of this.audience_pipes.values()) {
      await this.publish_track_to_audience(pipe, track, pub.sid);
    }
  }

  private async on_track_unsubscribed(
    track: RemoteTrack,
    pub: RemoteTrackPublication,
    _participant: RemoteParticipant
  ): Promise<void> {
    console.log(`[bridge] Track unsubscribed: sid=${pub.sid}`);
    for (const pipe of this.audience_pipes.values()) {
      const stored = pipe.published_tracks.get(pub.sid);
      if (stored) {
        try {
          await pipe.room.localParticipant.unpublishTrack(stored);
        } catch (e) {
          console.warn(`[bridge] Error unpublishing track:`, e);
        }
        pipe.published_tracks.delete(pub.sid);
      }
    }
  }

  private async connect_audience(audience_channel_id: string): Promise<void> {
    const room = new Room();
    const pipe: AudiencePipe = {
      channelId: audience_channel_id,
      room,
      published_tracks: new Map(),
    };

    const token = this.make_token(audience_channel_id, {
      canPublish: true,
      canSubscribe: false,
    });

    let connected =false;
    for (let attempt = 0; attempt < 10; attempt++) {
      try {
        await room.connect(config.livekit.url, token;
        connected = true;
        break;
      } catch (e: any) {
        if (e?.message?.includes("not exist") || e?.code === 404) {
          console.log('[bridge] Audience room ${audience_channel_id} not ready yet, retrying in 3s... (attempt ${attempt + 1}/10)');
          await now Promise(red => setTimeout(res, 3000));
	} else {
	  throw e;

	}
      }
    }
    if (!connected) {
      console.warn('[bridge] Gave up connecting to audience room ${audience_channel_id} after 10 attempts');
      return;
    }

    this.audience_pipes.set(audience_channel_id, pipe);
    console.log(`[bridge] Bot connected to audience room ${audience_channel_id}`);
  }

  private async publish_track_to_audience(
    pipe: AudiencePipe,
    remote_track: RemoteTrack,
    track_sid: string
  ): Promise<void> {
    try {
      await pipe.room.localParticipant.publishTrack(remote_track);
      pipe.published_tracks.set(track_sid, remote_track);
      console.log(
        `[bridge] Published track ${track_sid} (${remote_track.kind}) ` +
        `to audience ${pipe.channelId}`
      );
    } catch (e) {
      console.error(
        `[bridge] Failed to publish track ${track_sid} to ${pipe.channelId}:`, e
      );
    }
  }

  private make_token(
    room_name: string,
    grants: { canPublish: boolean; canSubscribe: boolean }
  ): string {
    const token = new AccessToken(
      config.livekit.api_key,
      config.livekit.api_secret,
      {
        identity: `${config.bot_identity}-${room_name}`,
        name: config.bot_name,
        metadata: JSON.stringify({ is_stage_bridge: true }),
      }
    );
    token.addGrant({
      roomJoin: true,
      room: room_name,
      canPublish: grants.canPublish,
      canSubscribe: grants.canSubscribe,
      canPublishData: false,
      hidden: true,
    });
    return token.toJwt();
  }

  async teardown(): Promise<void> {
    if (this.is_torn_down) return;
    this.is_torn_down = true;
    console.log(`[bridge] Tearing down session for stage=${this.stage_channel_id}`);
    for (const pipe of this.audience_pipes.values()) {
      try { await pipe.room.disconnect(); } catch (e) {
        console.warn(`[bridge] Error disconnecting audience ${pipe.channelId}:`, e);
      }
    }
    this.audience_pipes.clear();
    try { await this.stage_room.disconnect(); } catch (e) {
      console.warn(`[bridge] Error disconnecting stage:`, e);
    }
  }
}

// ── Session Registry ──────────────────────────────────────────────────────────

const active_sessions: Map<string, BridgeSession> = new Map();

export async function start_bridge(
  stage_channel_id: string,
  audience_channel_ids: string[]
): Promise<void> {
  if (active_sessions.has(stage_channel_id)) {
    console.log(`[bridge] Session already active for ${stage_channel_id}, skipping`);
    return;
  }
  const session = new BridgeSession(stage_channel_id, audience_channel_ids);
  active_sessions.set(stage_channel_id, session);
  try {
    await session.start();
  } catch (e) {
    console.error(`[bridge] Failed to start session for ${stage_channel_id}:`, e);
    active_sessions.delete(stage_channel_id);
    await session.teardown();
  }
}

export async function stop_bridge(stage_channel_id: string): Promise<void> {
  const session = active_sessions.get(stage_channel_id);
  if (!session) return;
  active_sessions.delete(stage_channel_id);
  await session.teardown();
}

export function get_active_sessions(): string[] {
  return Array.from(active_sessions.keys());
}
