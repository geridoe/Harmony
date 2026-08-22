const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

const supabaseURL = required("HARMONY_SUPABASE_URL");
const publishableKey = required("HARMONY_PUBLISHABLE_KEY");
const observerToken = required("HARMONY_OBSERVER_TOKEN");
const actorToken = required("HARMONY_ACTOR_TOKEN");
const observerID = required("HARMONY_OBSERVER_ID");
const actorID = required("HARMONY_ACTOR_ID");
const realtimeURL = new URL(supabaseURL.replace(/^http/, "ws"));
realtimeURL.pathname = "/realtime/v1/websocket";
realtimeURL.searchParams.set("apikey", publishableKey);
realtimeURL.searchParams.set("vsn", "1.0.0");

const rpc = async (name, token, body) => {
  const response = await fetch(`${supabaseURL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: publishableKey,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${name} failed with ${response.status}: ${await response.text()}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
};

const socket = new WebSocket(realtimeURL);
let followCreated = false;
let historyCreated = false;
let followDelivered = false;
let historyDelivered = false;
let historyEntryID = null;
let settled = false;

const cleanup = async () => {
  if (followCreated) {
    await rpc("remove_social_follow", actorToken, { p_profile_id: observerID }).catch(() => {});
  }
  if (historyEntryID) {
    await rpc("delete_listening_history_entry", actorToken, { p_entry_id: historyEntryID }).catch(() => {});
  }
  socket.close();
};

const finish = async (error) => {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  await cleanup();
  if (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  } else {
    console.log("Harmony Realtime smoke passed: follower graph and redacted Diary changes delivered");
  }
};

const timeout = setTimeout(() => finish(new Error("Timed out waiting for social graph and redacted Diary Realtime events")), 15_000);

socket.addEventListener("open", () => {
  socket.send(JSON.stringify({
    topic: "realtime:public:social_follows",
    event: "phx_join",
    payload: {
      config: {
        broadcast: { ack: false, self: false },
        presence: { key: "" },
        postgres_changes: [
          { event: "*", schema: "public", table: "social_follows" },
          { event: "INSERT", schema: "public", table: "listening_history_entries" },
        ],
      },
      access_token: observerToken,
    },
    ref: "1",
    join_ref: "1",
  }));
});

socket.addEventListener("message", async (event) => {
  try {
    const message = JSON.parse(String(event.data));
    if (process.env.HARMONY_REALTIME_DEBUG === "1") console.error(JSON.stringify(message));
    if (message.event === "phx_reply" && message.ref === "1") {
      if (message.payload?.status !== "ok") throw new Error(`Realtime join rejected: ${JSON.stringify(message.payload)}`);
      await rpc("request_social_follow", actorToken, { p_profile_id: observerID });
      followCreated = true;
      const history = await rpc("record_listening_history", actorToken, {
        p_canonical_track_id: null,
        p_provider: null,
        p_provider_track_id: null,
        p_source: "manual",
        p_visibility: "public",
        p_is_relisten: false,
        p_tags: [],
        p_rating: null,
      });
      historyEntryID = Array.isArray(history) ? history[0]?.id : history?.id;
      historyCreated = true;
      if (followDelivered && historyDelivered) await finish();
      return;
    }
    if (message.event !== "postgres_changes") return;
    const record = message.payload?.data?.record ?? message.payload?.record;
    if (record?.follower_id === actorID && record?.followed_id === observerID) {
      followDelivered = true;
    }
    if (record?.profile_id === actorID && record?.source === "manual") {
      if (Object.prototype.hasOwnProperty.call(record, "review_id")) {
        throw new Error("Realtime Diary payload exposed review_id");
      }
      historyDelivered = true;
    }
    if (followDelivered && historyDelivered && followCreated && historyCreated) await finish();
  } catch (error) {
    await finish(error);
  }
});

socket.addEventListener("error", () => finish(new Error("Realtime WebSocket connection failed")));
