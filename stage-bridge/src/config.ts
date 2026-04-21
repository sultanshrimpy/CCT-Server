// config.ts
// Single source of truth for all environment variables.
// stage-bridge reads everything it needs from here.

function require_env(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required environment variable: ${key}`);
  return val;
}

export const config = {
  // LiveKit server connection
  livekit: {
    url:       require_env("LIVEKIT_URL"),        // e.g. ws://livekit:7880
    api_key:   require_env("LIVEKIT_API_KEY"),
    api_secret: require_env("LIVEKIT_API_SECRET"),
  },

  // Redis - same instance the rest of the stack uses
  redis: {
    url: process.env.REDIS_URL ?? "redis://redis:6379",
  },

  // HTTP server port for the link management API + webhook receiver
  port: parseInt(process.env.PORT ?? "8600"),

  // Identity the bridge bot uses when joining rooms
  // Stoat will show this as a participant name - keep it clear
  bot_identity: process.env.BOT_IDENTITY ?? "stage-feed",
  bot_name:     process.env.BOT_NAME     ?? "Stage Feed",
};
