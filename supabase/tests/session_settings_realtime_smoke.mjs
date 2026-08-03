const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

const supabaseURL = required("HARMONY_SUPABASE_URL");
const publishableKey = required("HARMONY_PUBLISHABLE_KEY");
const conductorToken = required("HARMONY_CONDUCTOR_TOKEN");
const sessionID = required("HARMONY_SESSION_ID");
const realtimeURL = new URL(supabaseURL.replace(/^http/, "ws"));
realtimeURL.pathname = "/realtime/v1/websocket";
realtimeURL.searchParams.set("apikey", publishableKey);
realtimeURL.searchParams.set("vsn", "1.0.0");

const setReordering = async (allowed) => {
  const response = await fetch(
    `${supabaseURL}/rest/v1/rpc/set_harmony_collaborator_reordering`,
    {
      method: "POST",
      headers: {
        apikey: publishableKey,
        Authorization: `Bearer ${conductorToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_session_id: sessionID,
        p_allow_collaborator_reordering: allowed,
      }),
    },
  );
  if (!response.ok) {
    throw new Error(`settings RPC failed with ${response.status}: ${await response.text()}`);
  }
};

const socket = new WebSocket(realtimeURL);
let sawDisabled = false;
let settingDisabled = false;
let settled = false;

const finish = async (error) => {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  if (settingDisabled) await setReordering(true).catch(() => {});
  socket.close();
  if (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  } else {
    console.log("Harmony session-settings Realtime smoke passed: collaborator reordering updates delivered");
  }
};

const timeout = setTimeout(
  () => finish(new Error("Timed out waiting for collaborator-reordering Realtime updates")),
  15_000,
);

socket.addEventListener("open", () => {
  socket.send(JSON.stringify({
    topic: "realtime:public:sessions",
    event: "phx_join",
    payload: {
      config: {
        broadcast: { ack: false, self: false },
        presence: { key: "" },
        postgres_changes: [{
          event: "UPDATE",
          schema: "public",
          table: "sessions",
          filter: `id=eq.${sessionID}`,
        }],
      },
      access_token: conductorToken,
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
      if (message.payload?.status !== "ok") {
        throw new Error(`Realtime join rejected: ${JSON.stringify(message.payload)}`);
      }
      await setReordering(false);
      settingDisabled = true;
      return;
    }
    if (message.event !== "postgres_changes") return;
    const record = message.payload?.data?.record ?? message.payload?.record;
    if (record?.id !== sessionID) return;
    if (!Object.prototype.hasOwnProperty.call(record, "allow_collaborator_reordering")) {
      throw new Error("Realtime session projection omitted allow_collaborator_reordering");
    }
    if (record.allow_collaborator_reordering === false && !sawDisabled) {
      sawDisabled = true;
      await setReordering(true);
      settingDisabled = false;
      return;
    }
    if (record.allow_collaborator_reordering === true && sawDisabled) await finish();
  } catch (error) {
    await finish(error);
  }
});

socket.addEventListener("error", () => finish(new Error("Realtime WebSocket connection failed")));
