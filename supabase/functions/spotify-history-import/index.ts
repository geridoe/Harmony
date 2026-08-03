import { createClient } from "npm:@supabase/supabase-js@2";
import { resolveSpotifyCanonicalTrack } from "../_shared/canonical-track.ts";

type SpotifyTrack = {
  name: string;
  uri: string;
  duration_ms: number;
  explicit: boolean;
  artists: Array<{ name: string }>;
  album: { name: string; images?: Array<{ url: string }> };
  external_ids?: { isrc?: string };
  external_urls?: { spotify?: string };
};
type RecentItem = { played_at: string; track: SpotifyTrack };

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing function secret ${name}`);
  return value;
}

function decodeBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

async function decrypt(encrypted: string): Promise<string> {
  const [version, encodedIV, encodedCiphertext] = encrypted.split(":");
  if (version !== "v1" || !encodedIV || !encodedCiphertext) throw new Error("Unsupported encrypted token format");
  const rawKey = decodeBase64(required("SPOTIFY_TOKEN_ENCRYPTION_KEY"));
  if (rawKey.byteLength !== 32) throw new Error("SPOTIFY_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key");
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  const cleartext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: decodeBase64(encodedIV) },
    key,
    decodeBase64(encodedCiphertext),
  );
  return new TextDecoder().decode(cleartext);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default);
    const { data: user, error: userError } = await admin.auth.getUser(authorization.slice(7));
    if (userError || !user.user) return json({ error: "unauthorized" }, 401);

    const { data: connection, error: connectionError } = await admin
      .from("provider_connections")
      .select("encrypted_refresh_token,scopes")
      .eq("profile_id", user.user.id)
      .eq("provider", "spotify")
      .maybeSingle();
    if (connectionError) throw connectionError;
    if (!connection?.encrypted_refresh_token) return json({ error: "spotify_not_connected" }, 404);
    if (!(connection.scopes ?? []).includes("user-read-recently-played")) {
      return json({ error: "spotify_history_scope_missing" }, 409);
    }

    const { data: settings, error: settingsError } = await admin
      .from("profile_social_settings")
      .select("history_visibility")
      .eq("profile_id", user.user.id)
      .single();
    if (settingsError) throw settingsError;

    const clientID = required("SPOTIFY_CLIENT_ID");
    const clientSecret = required("SPOTIFY_CLIENT_SECRET");
    const tokenResponse = await fetch("https://accounts.spotify.com/api/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Authorization: `Basic ${btoa(`${clientID}:${clientSecret}`)}`,
      },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: await decrypt(connection.encrypted_refresh_token),
      }),
    });
    if (!tokenResponse.ok) return json({ error: "spotify_refresh_failed", upstreamStatus: tokenResponse.status }, 502);
    const tokens = await tokenResponse.json();
    if (!tokens.access_token) return json({ error: "spotify_access_token_missing" }, 502);

    const recentResponse = await fetch("https://api.spotify.com/v1/me/player/recently-played?limit=20", {
      headers: { Authorization: `Bearer ${tokens.access_token}` },
    });
    if (!recentResponse.ok) {
      console.error("spotify recent history rejected", recentResponse.status, await recentResponse.text());
      return json({ error: "spotify_history_failed", upstreamStatus: recentResponse.status }, recentResponse.status === 429 ? 429 : 502);
    }
    const recent = await recentResponse.json();
    const items = (recent.items ?? []) as RecentItem[];
    let imported = 0;
    let skipped = 0;

    for (const item of items) {
      const track = item.track;
      const { data: duplicate, error: duplicateError } = await admin
        .from("listening_history_entries")
        .select("id")
        .eq("profile_id", user.user.id)
        .eq("provider", "spotify")
        .eq("provider_track_id", track.uri)
        .eq("played_at", item.played_at)
        .limit(1)
        .maybeSingle();
      if (duplicateError) throw duplicateError;
      if (duplicate) { skipped += 1; continue; }

      const canonicalID = await resolveSpotifyCanonicalTrack(admin, track);

      const { error: insertError } = await admin.from("listening_history_entries").insert({
        profile_id: user.user.id,
        canonical_track_id: canonicalID,
        provider: "spotify",
        provider_track_id: track.uri,
        played_at: item.played_at,
        source: "provider_import",
        visibility: settings.history_visibility,
      });
      if (insertError?.code === "23505") { skipped += 1; continue; }
      if (insertError) throw insertError;
      imported += 1;
    }

    return json({ imported, skipped });
  } catch (error) {
    console.error("spotify history import failed", error instanceof Error ? error.message : "unknown error");
    return json({ error: "spotify_history_import_failed" }, 500);
  }
});
