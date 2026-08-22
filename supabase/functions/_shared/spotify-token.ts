type SupabaseResult<T> = PromiseLike<
  { data: T | null; error: { message?: string } | null }
>;

export type SpotifyConnection = {
  encrypted_refresh_token: string | null;
  encrypted_access_token: string | null;
  access_token_expires_at: string | null;
  scopes: string[] | null;
};

export type SpotifyAccessToken = {
  accessToken: string;
  expiresAt: string;
  scopes: string[];
};

export type SpotifyTokenAdmin = {
  from(table: string): {
    select(columns: string): {
      eq(column: string, value: string): {
        eq(column: string, value: string): {
          maybeSingle(): SupabaseResult<SpotifyConnection>;
        };
      };
    };
    update(values: Record<string, unknown>): {
      eq(column: string, value: string): {
        eq(column: string, value: string): SupabaseResult<unknown>;
      };
    };
  };
  rpc(
    name: string,
    parameters: Record<string, unknown>,
  ): SupabaseResult<boolean>;
};

export class SpotifyTokenError extends Error {
  constructor(
    public readonly code:
      | "spotify_not_connected"
      | "spotify_refresh_failed"
      | "spotify_access_token_missing",
    public readonly status: number,
    public readonly upstreamStatus?: number,
  ) {
    super(code);
    this.name = "SpotifyTokenError";
  }
}

const CACHE_SKEW_MS = 2 * 60 * 1000;
const REFRESH_POLL_ATTEMPTS = 10;
const REFRESH_POLL_DELAY_MS = 150;

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing function secret ${name}`);
  return value;
}

function decodeBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function encodeBase64(value: Uint8Array): string {
  return btoa(String.fromCharCode(...value));
}

async function encryptionKey(usages: KeyUsage[]): Promise<CryptoKey> {
  const rawKey = decodeBase64(required("SPOTIFY_TOKEN_ENCRYPTION_KEY"));
  if (rawKey.byteLength !== 32) {
    throw new Error(
      "SPOTIFY_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key",
    );
  }
  return await crypto.subtle.importKey(
    "raw",
    rawKey.buffer as ArrayBuffer,
    "AES-GCM",
    false,
    usages,
  );
}

export async function encryptSpotifyToken(plainText: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey(["encrypt"]);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plainText),
  );
  return `v1:${encodeBase64(iv)}:${encodeBase64(new Uint8Array(ciphertext))}`;
}

export async function decryptSpotifyToken(encrypted: string): Promise<string> {
  const [version, encodedIV, encodedCiphertext] = encrypted.split(":");
  if (version !== "v1" || !encodedIV || !encodedCiphertext) {
    throw new Error("Unsupported encrypted token format");
  }
  const key = await encryptionKey(["decrypt"]);
  const cleartext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: decodeBase64(encodedIV).buffer as ArrayBuffer },
    key,
    decodeBase64(encodedCiphertext).buffer as ArrayBuffer,
  );
  return new TextDecoder().decode(cleartext);
}

export function parseSpotifyScopes(
  value: unknown,
  fallback: string[] = [],
): string[] {
  if (typeof value !== "string") return fallback;
  return value.split(" ").map((scope) => scope.trim()).filter(Boolean);
}

export function isSpotifyAccessTokenFresh(
  connection: Pick<
    SpotifyConnection,
    "encrypted_access_token" | "access_token_expires_at"
  >,
  now = Date.now(),
): boolean {
  if (
    !connection.encrypted_access_token || !connection.access_token_expires_at
  ) return false;
  const expiresAt = Date.parse(connection.access_token_expires_at);
  return Number.isFinite(expiresAt) && expiresAt > now + CACHE_SKEW_MS;
}

async function loadConnection(
  admin: SpotifyTokenAdmin,
  profileID: string,
): Promise<SpotifyConnection> {
  const { data, error } = await admin
    .from("provider_connections")
    .select(
      "encrypted_refresh_token,encrypted_access_token,access_token_expires_at,scopes",
    )
    .eq("profile_id", profileID)
    .eq("provider", "spotify")
    .maybeSingle();
  if (error) throw error;
  if (!data?.encrypted_refresh_token) {
    throw new SpotifyTokenError("spotify_not_connected", 404);
  }
  return data;
}

async function cachedToken(
  connection: SpotifyConnection,
  now: number,
): Promise<SpotifyAccessToken | null> {
  if (!isSpotifyAccessTokenFresh(connection, now)) return null;
  return {
    accessToken: await decryptSpotifyToken(connection.encrypted_access_token!),
    expiresAt: connection.access_token_expires_at!,
    scopes: connection.scopes ?? [],
  };
}

const delay = (milliseconds: number) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

export async function getSpotifyAccessToken(
  adminClient: unknown,
  profileID: string,
  now = Date.now(),
): Promise<SpotifyAccessToken> {
  // Avoid asking TypeScript to structurally expand Supabase's deeply generic
  // client at every call site. Runtime access remains limited to this interface.
  const admin = adminClient as SpotifyTokenAdmin;
  let connection = await loadConnection(admin, profileID);
  const cached = await cachedToken(connection, now);
  if (cached) return cached;

  const safeUntil = new Date(now + CACHE_SKEW_MS).toISOString();
  const { data: claimed, error: claimError } = await admin.rpc(
    "claim_spotify_token_refresh",
    {
      p_profile_id: profileID,
      p_safe_until: safeUntil,
    },
  );
  if (claimError) throw claimError;

  if (!claimed) {
    for (let attempt = 0; attempt < REFRESH_POLL_ATTEMPTS; attempt += 1) {
      await delay(REFRESH_POLL_DELAY_MS);
      connection = await loadConnection(admin, profileID);
      const refreshed = await cachedToken(connection, Date.now());
      if (refreshed) return refreshed;
    }
    // A slow or failed lease holder should not make the user wait for the lease
    // timeout. This fallback can cause a rare duplicate refresh but preserves
    // availability; rotating refresh tokens are saved atomically below.
  }

  try {
    const tokenResponse = await fetch(
      "https://accounts.spotify.com/api/token",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Authorization: `Basic ${
            btoa(
              `${required("SPOTIFY_CLIENT_ID")}:${
                required("SPOTIFY_CLIENT_SECRET")
              }`,
            )
          }`,
        },
        body: new URLSearchParams({
          grant_type: "refresh_token",
          refresh_token: await decryptSpotifyToken(
            connection.encrypted_refresh_token!,
          ),
        }),
      },
    );
    if (!tokenResponse.ok) {
      throw new SpotifyTokenError(
        "spotify_refresh_failed",
        502,
        tokenResponse.status,
      );
    }

    const tokens = await tokenResponse.json();
    if (typeof tokens.access_token !== "string" || !tokens.access_token) {
      throw new SpotifyTokenError("spotify_access_token_missing", 502);
    }

    const expiresIn = Math.max(1, Number(tokens.expires_in ?? 3600));
    const expiresAt = new Date(Date.now() + expiresIn * 1000).toISOString();
    const scopes = parseSpotifyScopes(tokens.scope, connection.scopes ?? []);
    const updates: Record<string, unknown> = {
      encrypted_access_token: await encryptSpotifyToken(tokens.access_token),
      access_token_expires_at: expiresAt,
      expires_at: expiresAt,
      scopes,
      token_refresh_started_at: null,
    };
    if (typeof tokens.refresh_token === "string" && tokens.refresh_token) {
      updates.encrypted_refresh_token = await encryptSpotifyToken(
        tokens.refresh_token,
      );
    }

    const { error: saveError } = await admin.from("provider_connections")
      .update(updates)
      .eq("profile_id", profileID)
      .eq("provider", "spotify");
    if (saveError) throw saveError;

    return { accessToken: tokens.access_token, expiresAt, scopes };
  } catch (error) {
    await admin.from("provider_connections")
      .update({ token_refresh_started_at: null })
      .eq("profile_id", profileID)
      .eq("provider", "spotify");
    throw error;
  }
}

export function spotifyTokenErrorResponse(
  error: unknown,
  includeUpstreamStatus = true,
): Response | null {
  if (!(error instanceof SpotifyTokenError)) return null;
  const body: Record<string, unknown> = { error: error.code };
  if (includeUpstreamStatus && error.upstreamStatus !== undefined) {
    body.upstreamStatus = error.upstreamStatus;
  }
  return new Response(JSON.stringify(body), {
    status: error.status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
