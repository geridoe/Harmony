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
};

const socket = new WebSocket(realtimeURL);
let followCreated = false;
let settled = false;

const cleanup = async () => {
  if (followCreated) {
    await rpc("remove_social_follow", actorToken, { p_profile_id: observerID }).catch(() => {});
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
    console.log("Harmony Realtime smoke passed: follower graph change delivered");
  }
};

const timeout = setTimeout(() => finish(new Error("Timed out waiting for a social_follows Realtime event")), 15_000);

socket.addEventListener("open", () => {
  socket.send(JSON.stringify({
    topic: "realtime:public:social_follows",
    event: "phx_join",
    payload: {
      config: {
        broadcast: { ack: false, self: false },
        presence: { key: "" },
        postgres_changes: [{ event: "*", schema: "public", table: "social_follows" }],
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
      return;
    }
    if (message.event !== "postgres_changes") return;
    const record = message.payload?.data?.record ?? message.payload?.record;
    if (record?.follower_id === actorID && record?.followed_id === observerID) await finish();
  } catch (error) {
    await finish(error);
  }
});

socket.addEventListener("error", () => finish(new Error("Realtime WebSocket connection failed")));
