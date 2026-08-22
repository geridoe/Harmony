import { createClient } from "npm:@supabase/supabase-js@2";

type Delivery = {
  delivery_id: string;
  claim_token: string;
  device_token: string;
  apns_environment: "sandbox" | "production";
  app_bundle_id: string;
  notification_kind: string;
  actor_id: string;
  actor_display_name: string;
  review_id: string | null;
  music_list_id: string | null;
  listening_broadcast_id: string | null;
  attempt_count: number;
};

const encoder = new TextEncoder();
const jsonHeaders = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: jsonHeaders });

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing function secret ${name}`);
  return value;
}

function constantTimeEqual(left: string, right: string): boolean {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    difference |= (a[index % Math.max(1, a.length)] ?? 0) ^
      (b[index % Math.max(1, b.length)] ?? 0);
  }
  return difference === 0;
}

function base64url(value: Uint8Array | string): string {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function pemBytes(pem: string): ArrayBuffer {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0)).buffer;
}

async function providerToken(teamId: string, keyId: string, privateKey: string): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const unsigned = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(unsigned),
  ));
  return `${unsigned}.${base64url(signature)}`;
}

function presentation(delivery: Delivery) {
  const actor = delivery.actor_display_name.slice(0, 80);
  switch (delivery.notification_kind) {
    case "follow_request": return { title: "New follow request", body: `${actor} wants to follow you.` };
    case "follow_accepted": return { title: "Follow accepted", body: `${actor} accepted your request.` };
    case "review_comment": return { title: "New review comment", body: `${actor} commented on your review.` };
    case "review_reaction": return { title: "New review reaction", body: `${actor} reacted to your review.` };
    case "music_list_comment": return { title: "New list comment", body: `${actor} commented on your list.` };
    case "music_list_like": return { title: "New list reaction", body: `${actor} liked your list.` };
    case "listening_broadcast_comment": return { title: "New listening comment", body: `${actor} commented on your listening activity.` };
    case "listening_broadcast_reaction": return { title: "New listening reaction", body: `${actor} reacted to your listening activity.` };
    default: return { title: "Harmony", body: "You have a new notification." };
  }
}

function retryAfter(response: Response): number | null {
  const raw = response.headers.get("retry-after");
  if (!raw) return null;
  const seconds = Number(raw);
  if (Number.isFinite(seconds)) return Math.max(1, Math.min(86400, Math.ceil(seconds)));
  const date = Date.parse(raw);
  return Number.isNaN(date) ? null : Math.max(1, Math.min(86400, Math.ceil((date - Date.now()) / 1000)));
}

function shouldInvalidate(status: number, reason: string): boolean {
  return status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic" ||
    reason === "Unregistered";
}

function isRetryable(status: number): boolean {
  return status !== 400 && status !== 405 && status !== 413;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const authorization = request.headers.get("authorization") ?? "";
    const suppliedSecret = request.headers.get("x-harmony-worker-secret") ?? "";
    if (!authorization.startsWith("Bearer ") ||
      !constantTimeEqual(suppliedSecret, required("APNS_WORKER_SECRET"))) {
      return json({ error: "unauthorized" }, 401);
    }

    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const jwt = await providerToken(
      required("APNS_TEAM_ID"), required("APNS_KEY_ID"), required("APNS_PRIVATE_KEY"),
    );
    const requested = Number(new URL(request.url).searchParams.get("batch") ?? "50");
    const batchSize = Number.isInteger(requested) ? Math.max(1, Math.min(100, requested)) : 50;
    const { data, error } = await admin.rpc("claim_notification_deliveries", {
      p_batch_size: batchSize, p_lease_seconds: 120,
    });
    if (error) throw new Error(`claim_failed:${error.code ?? "database"}`);

    let sent = 0;
    let failed = 0;
    for (const delivery of (data ?? []) as Delivery[]) {
      const host = delivery.apns_environment === "production"
        ? "https://api.push.apple.com"
        : "https://api.sandbox.push.apple.com";
      const content = presentation(delivery);
      const payload = {
        aps: { alert: content, sound: "default", badge: 1, "thread-id": "social" },
        // Keep routing keys at the top level: iOS receives them alongside
        // `aps` in UNNotificationContent.userInfo.
        kind: delivery.notification_kind,
        profile_id: delivery.actor_id,
        review_id: delivery.review_id,
        music_list_id: delivery.music_list_id,
        broadcast_id: delivery.listening_broadcast_id,
      };
      try {
        const response = await fetch(`${host}/3/device/${delivery.device_token}`, {
          method: "POST",
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": delivery.app_bundle_id,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": "0",
            "content-type": "application/json",
          },
          body: JSON.stringify(payload),
        });
        if (response.ok) {
          const { data: completed, error: completionError } = await admin.rpc(
            "complete_notification_delivery",
            { p_delivery_id: delivery.delivery_id, p_claim_token: delivery.claim_token, p_http_status: response.status },
          );
          if (completionError || !completed) throw new Error("stale_completion_claim");
          sent++;
          continue;
        }
        const responseBody = await response.json().catch(() => ({})) as { reason?: unknown };
        const reason = typeof responseBody.reason === "string" && /^[A-Za-z0-9_.-]{1,100}$/.test(responseBody.reason)
          ? responseBody.reason : `APNsHTTP${response.status}`;
        await admin.rpc("fail_notification_delivery", {
          p_delivery_id: delivery.delivery_id,
          p_claim_token: delivery.claim_token,
          p_http_status: response.status,
          p_error_code: reason,
          p_retry_after_seconds: retryAfter(response),
          p_invalidate_device: shouldInvalidate(response.status, reason),
          p_retryable: isRetryable(response.status),
        });
        failed++;
      } catch (_error) {
        // Never log the delivery object: it contains the APNs token.
        await admin.rpc("fail_notification_delivery", {
          p_delivery_id: delivery.delivery_id,
          p_claim_token: delivery.claim_token,
          p_http_status: null,
          p_error_code: "TransportError",
          p_retry_after_seconds: null,
          p_invalidate_device: false,
          p_retryable: true,
        });
        failed++;
      }
    }
    console.log(JSON.stringify({ event: "apns_batch_complete", claimed: data?.length ?? 0, sent, failed }));
    return json({ claimed: data?.length ?? 0, sent, failed });
  } catch (error) {
    console.error("apns worker failed", error instanceof Error ? error.message : "unknown_error");
    return json({ error: "apns_worker_failed" }, 500);
  }
});
