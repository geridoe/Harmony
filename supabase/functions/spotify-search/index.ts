import { createClient } from "npm:@supabase/supabase-js@2";

type SearchRequest = { query: string };
type SpotifyTrack = {
  name: string;
  uri: string;
  duration_ms: number;
  artists: Array<{ name: string }>;
  album: { name: string; images?: Array<{ url: string }> };
  external_ids?: { isrc?: string };
  external_urls?: { spotify?: string };
};

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
    const input = await request.json() as SearchRequest;
    const query = input.query?.trim();
    if (!query || query.length > 100) return json({ error: "invalid_query" }, 400);

    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default);
    const { data: user, error: userError } = await admin.auth.getUser(authorization.slice(7));
    if (userError || !user.user) return json({ error: "unauthorized" }, 401);

    const { data: connection, error: connectionError } = await admin
      .from("provider_connections")
      .select("encrypted_refresh_token")
      .eq("profile_id", user.user.id)
      .eq("provider", "spotify")
      .maybeSingle();
    if (connectionError) throw connectionError;
    if (!connection?.encrypted_refresh_token) return json({ error: "spotify_not_connected" }, 404);

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
    if (!tokenResponse.ok) return json({ error: "spotify_refresh_failed" }, 502);
    const tokens = await tokenResponse.json();
    if (!tokens.access_token) return json({ error: "spotify_access_token_missing" }, 502);

    const spotifyResponse = await fetch(
      `https://api.spotify.com/v1/search?${new URLSearchParams({ q: query, type: "track", limit: "20" })}`,
      { headers: { Authorization: `Bearer ${tokens.access_token}` } },
    );
    if (!spotifyResponse.ok) return json({ error: "spotify_search_failed" }, 502);
    const spotify = await spotifyResponse.json();
    const tracks = (spotify.tracks?.items ?? []) as SpotifyTrack[];

    for (const track of tracks) {
      const { data: existing } = await admin
        .from("provider_tracks")
        .select("canonical_track_id")
        .eq("provider", "spotify")
        .eq("provider_id", track.uri)
        .eq("storefront", "global")
        .maybeSingle();
      if (existing) continue;

      const { data: canonical, error: canonicalError } = await admin.from("canonical_tracks").insert({
        title: track.name,
        artist: track.artists.map((artist) => artist.name).join(", "),
        album: track.album.name,
        duration_ms: track.duration_ms,
        isrc: track.external_ids?.isrc?.toUpperCase() ?? null,
        artwork_url: track.album.images?.[0]?.url ?? null,
      }).select("id").single();
      if (canonicalError) throw canonicalError;
      const { error: mappingError } = await admin.from("provider_tracks").insert({
        canonical_track_id: canonical.id,
        provider: "spotify",
        provider_id: track.uri,
        storefront: "global",
        deep_link: track.external_urls?.spotify ?? null,
        availability: "playable",
        match_confidence: 1,
      });
      if (mappingError) throw mappingError;
    }

    return json({
      tracks: tracks.map((track) => ({
        title: track.name,
        artist: track.artists.map((artist) => artist.name).join(", "),
        album: track.album.name,
        durationSeconds: Math.round(track.duration_ms / 1000),
        artworkURL: track.album.images?.[0]?.url ?? null,
        providerID: track.uri,
      })),
    });
  } catch (error) {
    console.error("spotify search failed", error instanceof Error ? error.message : "unknown error");
    return json({ error: "spotify_search_failed" }, 500);
  }
});
