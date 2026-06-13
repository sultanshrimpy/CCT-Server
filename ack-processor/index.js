"use strict";

const amqp = require("amqplib");
const { MongoClient } = require("mongodb");

// ── Config from environment ───────────────────────────────────────────────────
const AMQP_URL =
  process.env.AMQP_URL || "amqp://rabbituser:rabbitpass@rabbit:5672/";
const MONGO_URL = process.env.MONGO_URL || "mongodb://database:27017";
const MONGO_DB = process.env.MONGO_DB || "revolt";
const QUEUE_NAME = process.env.QUEUE_NAME || "internal.ack-prd";

// Reconnect delays (ms) — exponential backoff capped at 30s
const INITIAL_RETRY_DELAY = 2000;
const MAX_RETRY_DELAY = 30000;

// ── Logging helpers ───────────────────────────────────────────────────────────
function log(level, msg, extra) {
  const ts = new Date().toISOString();
  const line = extra
    ? `[${ts}] ${level} ${msg} ${JSON.stringify(extra)}`
    : `[${ts}] ${level} ${msg}`;
  console.log(line);
}
const info = (msg, extra) => log("INFO ", msg, extra);
const warn = (msg, extra) => log("WARN ", msg, extra);
const error = (msg, extra) => log("ERROR", msg, extra);

// ── MongoDB ───────────────────────────────────────────────────────────────────
let mongoClient = null;
let db = null;

async function connectMongo() {
  info("Connecting to MongoDB...", { url: MONGO_URL, db: MONGO_DB });
  mongoClient = new MongoClient(MONGO_URL, {
    serverSelectionTimeoutMS: 10000,
    connectTimeoutMS: 10000,
  });
  await mongoClient.connect();
  db = mongoClient.db(MONGO_DB);
  info("MongoDB connected.");

  // Ensure index exists for fast lookups
  await db
    .collection("channel_unreads")
    .createIndex({ "_id.user": 1, "_id.channel": 1 })
    .catch(() => {}); // index may already exist, ignore
}

// ── Ack processing ────────────────────────────────────────────────────────────

/**
 * Given a channel_id, look up the channel's last_message_id from MongoDB.
 * Returns null if the channel doesn't exist or has no messages.
 */
async function getChannelLastMessageId(channelId) {
  const channel = await db
    .collection("channels")
    .findOne({ _id: channelId }, { projection: { last_message_id: 1 } });
  return channel?.last_message_id ?? null;
}

/**
 * Write the ack to channel_unreads.
 * Uses upsert so it works whether the row already exists or not.
 */
async function writeAck(userId, channelId, lastMessageId) {
  const result = await db.collection("channel_unreads").updateOne(
    { "_id.channel": channelId, "_id.user": userId },
    { $set: { last_id: lastMessageId } },
    { upsert: false },
  );
  if (result.matchedCount === 0) {
    // No existing doc — insert with correct _id structure matching stoatchat (channel first)
    await db.collection("channel_unreads").insertOne({
      _id: { channel: channelId, user: userId },
      last_id: lastMessageId,
    });
  }
}

/**
 * Process a single ack message from RabbitMQ.
 */
async function processAckMessage(raw) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    error("Failed to parse ack message — discarding.", { raw, err: e.message });
    return; // nack without requeue would also work, but bad JSON is unrecoverable
  }

  const { user_id, channel_id, server_id } = payload;

  if (!user_id || !channel_id) {
    warn("Ack message missing user_id or channel_id — discarding.", payload);
    return;
  }

  // Look up the channel's current last message
  const lastMessageId = await getChannelLastMessageId(channel_id);
  if (!lastMessageId) {
    // Channel has no messages yet or doesn't exist — nothing to ack
    info("No last_message_id for channel, skipping.", { channel_id });
    return;
  }

  await writeAck(user_id, channel_id, lastMessageId);

  info("Ack written.", {
    user_id,
    channel_id,
    server_id: server_id ?? null,
    last_message_id: lastMessageId,
  });
}

// ── RabbitMQ consumer ─────────────────────────────────────────────────────────

async function startConsumer() {
  info("Connecting to RabbitMQ...", { url: AMQP_URL, queue: QUEUE_NAME });

  const conn = await amqp.connect(AMQP_URL);

  conn.on("error", (err) => {
    error("RabbitMQ connection error.", { err: err.message });
  });
  conn.on("close", () => {
    warn("RabbitMQ connection closed — will reconnect.");
    scheduleReconnect();
  });

  const ch = await conn.createChannel();

  // prefetch 1 so we process acks one at a time and don't lose messages on crash
  ch.prefetch(1);

  // Assert the exchange and queue (idempotent — safe if they already exist)
  await ch.assertExchange("revolt.default", "topic", { durable: true });
  await ch.assertQueue(QUEUE_NAME, { durable: true });

  // Bind with the routing key delta actually publishes ("internal.ack")
  // The queue was previously only bound to "internal.ack-prd" which didn't match
  await ch.bindQueue(QUEUE_NAME, "revolt.default", "internal.ack");
  info("Queue bound.", { queue: QUEUE_NAME, exchange: "revolt.default", routingKey: "internal.ack" });

  const { consumerTag } = await ch.consume(QUEUE_NAME, async (msg) => {
    if (!msg) {
      // Consumer cancelled by broker
      warn("Consumer cancelled by broker.");
      return;
    }

    const raw = msg.content.toString();

    try {
      await processAckMessage(raw);
      ch.ack(msg);
    } catch (err) {
      error("Error processing ack — requeueing once.", {
        err: err.message,
        raw,
      });
      // nack with requeue=true so it retries once; if it fails again the
      // message will be dead-lettered (or dropped if no DLX is configured)
      ch.nack(msg, false, !msg.fields.redelivered);
    }
  });

  info("Listening for ack messages.", { queue: QUEUE_NAME, consumerTag });

  return conn;
}

// ── Reconnect loop ────────────────────────────────────────────────────────────

let retryDelay = INITIAL_RETRY_DELAY;
let reconnectTimer = null;

function scheduleReconnect() {
  if (reconnectTimer) return;
  warn(`Reconnecting in ${retryDelay}ms...`);
  reconnectTimer = setTimeout(async () => {
    reconnectTimer = null;
    try {
      await startConsumer();
      retryDelay = INITIAL_RETRY_DELAY; // reset on success
    } catch (err) {
      error("Reconnect failed.", { err: err.message });
      retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY);
      scheduleReconnect();
    }
  }, retryDelay);
}

// ── Startup ───────────────────────────────────────────────────────────────────

async function main() {
  info("CCT ack-processor starting.");

  // Connect to MongoDB first — no point consuming if we can't write
  let mongoRetry = INITIAL_RETRY_DELAY;
  while (true) {
    try {
      await connectMongo();
      break;
    } catch (err) {
      error("MongoDB connection failed — retrying.", { err: err.message });
      await new Promise((r) => setTimeout(r, mongoRetry));
      mongoRetry = Math.min(mongoRetry * 2, MAX_RETRY_DELAY);
    }
  }

  // Start RabbitMQ consumer with reconnect loop
  try {
    await startConsumer();
  } catch (err) {
    error("Initial RabbitMQ connect failed.", { err: err.message });
    scheduleReconnect();
  }
}

// Graceful shutdown
process.on("SIGTERM", async () => {
  info("SIGTERM received — shutting down.");
  if (mongoClient) await mongoClient.close();
  process.exit(0);
});

process.on("SIGINT", async () => {
  info("SIGINT received — shutting down.");
  if (mongoClient) await mongoClient.close();
  process.exit(0);
});

main().catch((err) => {
  error("Fatal startup error.", { err: err.message });
  process.exit(1);
});
