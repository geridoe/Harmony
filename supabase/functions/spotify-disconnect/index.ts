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

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

    const secretKeys = JSON.parse(required("SUPABASE_SECRET_KEYS"));
    const admin = createClient(required("SUPABASE_URL"), secretKeys.default);
    const { data: user, error: userError } = await admin.auth.getUser(authorization.slice(7));
    if (userError || !user.user) return json({ error: "unauthorized" }, 401);

    const { error: deleteError } = await admin
      .from("provider_connections")
      .delete()
      .eq("profile_id", user.user.id)
      .eq("provider", "spotify");
    if (deleteError) throw deleteError;

    return json({ disconnected: true });
  } catch (error) {
    console.error("spotify disconnect failed", error instanceof Error ? error.message : "unknown error");
    return json({ error: "spotify_disconnect_failed" }, 500);
  }
});
