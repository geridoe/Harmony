import { createClient } from "npm:@supabase/supabase-js@2";

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
    const expiresIn = Number(tokens.expires_in ?? 3600);
    return json({
      accessToken: tokens.access_token,
      expiresAt: new Date(Date.now() + expiresIn * 1000).toISOString(),
      scopes: String(tokens.scope ?? connection.scopes?.join(" ") ?? "").split(" ").filter(Boolean),
    });
  } catch (error) {
    console.error("spotify access token refresh failed", error instanceof Error ? error.message : "unknown error");
    return json({ error: "server_configuration_error" }, 500);
  }
});
