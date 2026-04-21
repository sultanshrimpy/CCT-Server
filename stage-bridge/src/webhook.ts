// webhook.ts
// Receives webhook events from LiveKit and decides whether to start or stop
// a bridge session based on whether the room has linked audience channels.
//
// LiveKit fires room_started when the first participant joins a room,
// and room_finished when the last participant leaves.
//
// The webhook endpoint is POST /webhook
// LiveKit signs the payload with a JWT — we verify it before acting.

import { Router, Request, Response } from "express";
import { WebhookReceiver } from "livekit-server-sdk";
import { config } from "./config";
import { get_links } from "./store";
import { start_bridge, stop_bridge, apply_pending_metadata } from "./bridge";

const receiver = new WebhookReceiver(
  config.livekit.api_key,
  config.livekit.api_secret
);

export const webhook_router = Router();

webhook_router.post("/webhook", async (req: Request, res: Response) => {
  // LiveKit sends application/webhook+json — body is already parsed as text
  // We need the raw body string for signature verification
  const body = req.body as string;
  const auth_header = req.headers["authorization"] as string | undefined;

  let event;
  try {
    event = await receiver.receive(body, auth_header);
  } catch (e) {
    console.warn("[webhook] Failed to verify webhook signature:", e);
    res.status(401).send("Unauthorized");
    return;
  }

  const room_name = event.room?.name;

  switch (event.event) {
    case "room_started": {
      if (!room_name) break;

      console.log(`[webhook] room_started: ${room_name}`);

      // Check if this room has any linked audience channels
      const links = await get_links(room_name);
      if (links.length === 0) {
        console.log(`[webhook] No links configured for ${room_name}, checking if audience channel...`);
        await apply_pending_metadata(room_name);
        break;
      }

      console.log(
        `[webhook] Found ${links.length} audience link(s) for ${room_name}: [${links.join(", ")}]`
      );
      await start_bridge(room_name, links);
      break;
    }

    case "room_finished": {
      if (!room_name) break;

      console.log(`[webhook] room_finished: ${room_name}`);
      await stop_bridge(room_name);
      break;
    }

    default:
      // We only care about room lifecycle events, ignore everything else
      break;
  }

  // Always return 200 quickly — LiveKit will retry if we don't
  res.status(200).send("ok");
});
