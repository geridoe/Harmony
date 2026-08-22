import { createClient } from "npm:@supabase/supabase-js@2";
import {
  encryptSpotifyToken,
  parseSpotifyScopes,
} from "../_shared/spotify-token.ts";

type ExchangeRequest = {
  code: string;
  codeVerifier: string;
  redirectURI: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
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

    const input = await request.json() as ExchangeRequest;
    if (!input.code || !input.codeVerifier || !input.redirectURI) {
      return json({ error: "invalid_request" }, 400);
    }
    const clientID = required("SPOTIFY_CLIENT_ID");
    const body = new URLSearchParams({
      grant_type: "authorization_code",
      code: input.code,
      redirect_uri: input.redirectURI,
      client_id: clientID,
      code_verifier: input.codeVerifier,
    });
    const headers: Record<string, string> = {
      "Content-Type": "application/x-www-form-urlencoded",
    };
    const clientSecret = Deno.env.get("SPOTIFY_CLIENT_SECRET");
    if (clientSecret) {
      headers.Authorization = `Basic ${btoa(`${clientID}:${clientSecret}`)}`;
    }
    const tokenResponse = await fetch(
      "https://accounts.spotify.com/api/token",
      { method: "POST", headers, body },
    );
    if (!tokenResponse.ok) {
      return json({ error: "spotify_exchange_failed" }, 502);
    }
    const tokens = await tokenResponse.json();
    if (!tokens.refresh_token) {
      return json({ error: "spotify_refresh_token_missing" }, 502);
    }
    if (!tokens.access_token) {
      return json({ error: "spotify_access_token_missing" }, 502);
    }

    const expiresAt = new Date(
      Date.now() + Number(tokens.expires_in ?? 3600) * 1000,
    ).toISOString();
    const { error: saveError } = await admin.from("provider_connections")
      .upsert({
        profile_id: user.user.id,
        provider: "spotify",
        scopes: parseSpotifyScopes(tokens.scope),
        encrypted_refresh_token: await encryptSpotifyToken(
          tokens.refresh_token,
        ),
        encrypted_access_token: await encryptSpotifyToken(tokens.access_token),
        access_token_expires_at: expiresAt,
        token_refresh_started_at: null,
        expires_at: expiresAt,
      }, { onConflict: "profile_id,provider" });
    if (saveError) throw saveError;
    return json({ connected: true, expiresAt });
  } catch (error) {
    console.error(
      "spotify token exchange failed",
      error instanceof Error ? error.message : "unknown error",
    );
    return json({ error: "server_configuration_error" }, 500);
  }
});
