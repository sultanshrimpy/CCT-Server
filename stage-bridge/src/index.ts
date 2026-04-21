// index.ts
// Entry point for stage-bridge.
// Starts the HTTP server and registers all routes.

import express from "express";
import { config } from "./config";
import { api_router } from "./api";
import { webhook_router } from "./webhook";

const app = express();

// LiveKit sends webhooks as application/webhook+json
// We need the raw text body for signature verification, so we parse it as text
app.use(
  express.text({ type: "application/webhook+json" })
);

// Regular JSON parsing for our own API endpoints
app.use(express.json());

// Mount routes
app.use("/", webhook_router); // POST /webhook
app.use("/", api_router);     // GET|PUT|POST|DELETE /links/:id, GET /status

// Start
app.listen(config.port, () => {
  console.log(`[stage-bridge] Listening on port ${config.port}`);
  console.log(`[stage-bridge] LiveKit URL: ${config.livekit.url}`);
  console.log(`[stage-bridge] Redis URL: ${config.redis.url}`);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("[stage-bridge] Shutting down gracefully...");
  process.exit(0);
});
