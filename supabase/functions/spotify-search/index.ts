import { createClient } from "npm:@supabase/supabase-js@2";
import { resolveSpotifyCanonicalTrack } from "../_shared/canonical-track.ts";
import {
  getSpotifyAccessToken,
  spotifyTokenErrorResponse,
} from "../_shared/spotify-token.ts";

type SearchRequest = { query: string };
type SpotifyTrack = {
  name: string;
  uri: string;
  duration_ms: number;
  explicit: boolean;
  artists: Array<{ name: string }>;
  album: {
    name: string;
    uri: string;
    artists: Array<{ name: string }>;
    images?: Array<{ url: string }>;
    external_urls?: { spotify?: string };
  };
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
    const input = await request.json() as SearchRequest;
    const query = input.query?.trim();
    if (!query || query.length > 100) {
      return json({ error: "invalid_query" }, 400);
    }

    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default);
    const { data: user, error: userError } = await admin.auth.getUser(
      authorization.slice(7),
    );
    if (userError || !user.user) return json({ error: "unauthorized" }, 401);

    const token = await getSpotifyAccessToken(admin, user.user.id);

    const spotifyResponse = await fetch(
      `https://api.spotify.com/v1/search?${new URLSearchParams({
        q: query,
        type: "track",
        limit: "10",
      })}`,
      { headers: { Authorization: `Bearer ${token.accessToken}` } },
    );
    if (!spotifyResponse.ok) {
      console.error("spotify catalog search rejected", spotifyResponse.status);
      const status =
        spotifyResponse.status === 403 || spotifyResponse.status === 429
          ? spotifyResponse.status
          : 502;
      return json({
        error: "spotify_search_failed",
        upstreamStatus: spotifyResponse.status,
      }, status);
    }
    const spotify = await spotifyResponse.json();
    const tracks = (spotify.tracks?.items ?? []) as SpotifyTrack[];

    const canonicalIDs = new Map<string, string>();
    for (const track of tracks) {
      canonicalIDs.set(
        track.uri,
        await resolveSpotifyCanonicalTrack(admin, track),
      );
    }

    return json({
      tracks: tracks.map((track) => ({
        title: track.name,
        artist: track.artists.map((artist) => artist.name).join(", "),
        album: track.album.name,
        durationSeconds: Math.round(track.duration_ms / 1000),
        durationMilliseconds: track.duration_ms,
        artworkURL: track.album.images?.[0]?.url ?? null,
        providerID: track.uri,
        deepLinkURL: track.external_urls?.spotify ?? null,
        isExplicit: track.explicit,
        isrc: track.external_ids?.isrc?.toUpperCase() ?? null,
        canonicalTrackID: canonicalIDs.get(track.uri) ?? null,
        albumProviderID: track.album.uri,
        albumArtist: track.album.artists.map((artist) => artist.name).join(
          ", ",
        ),
        albumDeepLinkURL: track.album.external_urls?.spotify ?? null,
      })),
    });
  } catch (error) {
    const tokenError = spotifyTokenErrorResponse(error);
    if (tokenError) return tokenError;
    console.error(
      "spotify search failed",
      error instanceof Error ? error.message : "unknown error",
    );
    return json({ error: "spotify_search_failed" }, 500);
  }
});
