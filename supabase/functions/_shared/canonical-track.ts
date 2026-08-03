type CanonicalTrackClient = {
  rpc: (name: string, parameters: Record<string, unknown>) => PromiseLike<{
    data: unknown;
    error: { message?: string } | null;
  }>;
};

export type SpotifyCanonicalTrack = {
  name: string;
  uri: string;
  duration_ms: number;
  explicit: boolean;
  artists: Array<{ name: string }>;
  album: { name: string; images?: Array<{ url: string }> };
  external_ids?: { isrc?: string };
  external_urls?: { spotify?: string };
};

export async function resolveSpotifyCanonicalTrack(
  client: CanonicalTrackClient,
  track: SpotifyCanonicalTrack,
): Promise<string> {
  const { data, error } = await client.rpc("resolve_harmony_track_v2", {
    p_provider: "spotify",
    p_provider_id: track.uri,
    p_title: track.name,
    p_artist: track.artists.map((artist) => artist.name).join(", "),
    p_album: track.album.name,
    p_duration_ms: track.duration_ms,
    p_artwork_url: track.album.images?.[0]?.url ?? null,
    p_is_explicit: track.explicit,
    p_deep_link: track.external_urls?.spotify ?? null,
    p_isrc: track.external_ids?.isrc ?? null,
    p_storefront: "global",
  });
  if (error) throw new Error(error.message ?? "canonical track resolution failed");
  if (typeof data !== "string") throw new Error("canonical track resolution returned an invalid ID");
  return data;
}
