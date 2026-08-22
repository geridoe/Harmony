import {
  isSpotifyAccessTokenFresh,
  parseSpotifyScopes,
  SpotifyTokenError,
  spotifyTokenErrorResponse,
} from "./spotify-token.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("Spotify scopes use the refreshed value and ignore empty segments", () => {
  const scopes = parseSpotifyScopes(
    "user-read-playback-state  user-read-recently-played ",
    ["old"],
  );
  assert(scopes.length === 2, "expected two scopes");
  assert(scopes[0] === "user-read-playback-state", "expected playback scope");
  assert(scopes[1] === "user-read-recently-played", "expected history scope");
});

Deno.test("Spotify scopes preserve connection scopes when refresh omits scope", () => {
  const scopes = parseSpotifyScopes(undefined, ["existing"]);
  assert(
    scopes.length === 1 && scopes[0] === "existing",
    "expected fallback scopes",
  );
});

Deno.test("Spotify access-token cache requires the two-minute safety window", () => {
  const now = Date.parse("2026-08-22T12:00:00.000Z");
  assert(
    isSpotifyAccessTokenFresh({
      encrypted_access_token: "encrypted",
      access_token_expires_at: "2026-08-22T12:02:01.000Z",
    }, now),
    "token beyond skew should be reusable",
  );
  assert(
    !isSpotifyAccessTokenFresh({
      encrypted_access_token: "encrypted",
      access_token_expires_at: "2026-08-22T12:02:00.000Z",
    }, now),
    "token at skew should refresh",
  );
  assert(
    !isSpotifyAccessTokenFresh({
      encrypted_access_token: null,
      access_token_expires_at: "2026-08-22T13:00:00.000Z",
    }, now),
    "missing ciphertext should refresh",
  );
});

Deno.test("Spotify token errors expose status but never token material", async () => {
  const response = spotifyTokenErrorResponse(
    new SpotifyTokenError("spotify_refresh_failed", 502, 401),
  );
  assert(response?.status === 502, "expected gateway error response");
  const body = await response!.json();
  assert(
    body.error === "spotify_refresh_failed",
    "expected stable client error",
  );
  assert(body.upstreamStatus === 401, "expected upstream status");
  assert(
    Object.keys(body).length === 2,
    "response must not expose secret fields",
  );
});
