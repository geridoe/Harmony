import { createClient } from "npm:@supabase/supabase-js@2";
import { resolveSpotifyCanonicalTrack } from "../_shared/canonical-track.ts";
import {
  getSpotifyAccessToken,
  spotifyTokenErrorResponse,
} from "../_shared/spotify-token.ts";

type SpotifyTrack = {
  type?: string;
  name: string;
  uri: string;
  duration_ms: number;
  explicit: boolean;
  artists: Array<{ name: string }>;
  album: { name: string; images?: Array<{ url: string }> };
  external_ids?: { isrc?: string };
  external_urls?: { spotify?: string };
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing function secret ${name}`);
  return value;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return json({ error: "unauthorized" }, 401);
    }
    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default);
    const { data: user, error: userError } = await admin.auth.getUser(
      authorization.slice(7),
    );
    if (userError || !user.user) return json({ error: "unauthorized" }, 401);

    const { data: connection, error: connectionError } = await admin
      .from("provider_connections")
      .select("encrypted_refresh_token,scopes")
      .eq("profile_id", user.user.id)
      .eq("provider", "spotify")
      .maybeSingle();
    if (connectionError) throw connectionError;
    if (!connection?.encrypted_refresh_token) {
      return json({ error: "spotify_not_connected" }, 404);
    }
    if (!(connection.scopes ?? []).includes("user-read-playback-state")) {
      return json({ error: "spotify_playback_scope_missing" }, 409);
    }

    const { data: settings, error: settingsError } = await admin
      .from("profile_social_settings")
      .select("live_visibility")
      .eq("profile_id", user.user.id)
      .single();
    if (settingsError) throw settingsError;

    const token = await getSpotifyAccessToken(admin, user.user.id);

    const playbackResponse = await fetch(
      "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track",
      {
        headers: { Authorization: `Bearer ${token.accessToken}` },
      },
    );
    if (playbackResponse.status === 204) {
      return json({ published: false, reason: "nothing_playing" });
    }
    if (!playbackResponse.ok) {
      console.error(
        "spotify current playback rejected",
        playbackResponse.status,
      );
      return json({
        error: "spotify_playback_failed",
        upstreamStatus: playbackResponse.status,
      }, playbackResponse.status === 429 ? 429 : 502);
    }
    const playback = await playbackResponse.json();
    if (playback.currently_playing_type !== "track" || !playback.item) {
      return json({ published: false, reason: "unsupported_content" });
    }
    const track = playback.item as SpotifyTrack;

    const canonicalID = await resolveSpotifyCanonicalTrack(admin, track);

    const startedAt = new Date();
    const expiresAt = new Date(startedAt.getTime() + 5 * 60 * 1000);
    const { error: presenceError } = await admin.from("listening_presence")
      .upsert({
        profile_id: user.user.id,
        canonical_track_id: canonicalID,
        provider: "spotify",
        provider_track_id: track.uri,
        provider_deep_link: track.external_urls?.spotify ?? null,
        status: playback.is_playing ? "listening" : "paused",
        visibility: settings.live_visibility,
        started_at: startedAt.toISOString(),
        expires_at: expiresAt.toISOString(),
      }, { onConflict: "profile_id" });
    if (presenceError) throw presenceError;

    return json({
      published: true,
      title: track.name,
      artist: track.artists.map((artist) => artist.name).join(", "),
      isPlaying: Boolean(playback.is_playing),
    });
  } catch (error) {
    const tokenError = spotifyTokenErrorResponse(error);
    if (tokenError) return tokenError;
    console.error(
      "spotify now-listening publish failed",
      error instanceof Error ? error.message : "unknown error",
    );
    return json({ error: "spotify_now_listening_failed" }, 500);
  }
});
