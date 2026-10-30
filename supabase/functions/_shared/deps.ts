// Wires the portable handlers to real Supabase clients inside the Edge runtime (Deno).
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

// Defaults used until the matching Edge Function secrets are set. Add the production site
// (https://…) to ALLOWED_ORIGINS when the app is hosted.
const DEFAULT_EMAIL_DOMAIN = "staff.factory.invalid";
const DEFAULT_ORIGINS = "http://localhost:8080,http://127.0.0.1:8080";

const env = (k: string): string => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`Missing env ${k}`);
  return v;
};

export function realDeps() {
  const url = env("SUPABASE_URL");
  const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
  const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), opts);
  const anon = () => createClient(url, env("SUPABASE_ANON_KEY"), opts);
  return {
    // Not secrets, just settings. A value set in Dashboard → Edge Functions → Secrets overrides the default.
    // ALLOWED_ORIGINS: comma-separated exact origins, e.g. "https://factory.example.ly,http://localhost:8080"
    allowedOrigins: (Deno.env.get("ALLOWED_ORIGINS") || DEFAULT_ORIGINS).split(",").map((s) => s.trim()).filter(Boolean),
    emailDomain: Deno.env.get("STAFF_EMAIL_DOMAIN") || DEFAULT_EMAIL_DOMAIN, // must equal web/js/config.js
    log: (msg: string, e: unknown) => console.error(msg, e instanceof Error ? e.message : e),
    async getCaller(jwt: string) {
      const { data, error } = await admin.auth.getUser(jwt);
      return error || !data.user ? null : { id: data.user.id, email: data.user.email };
    },
    async rpc(fn: string, args: Record<string, unknown>) {
      const { data, error } = await admin.rpc(fn, args);
      if (error) throw Object.assign(new Error(error.message), { code: error.hint || error.code });
      return data;
    },
    auth: {
      async createUser(input: { email: string; password: string; app_metadata: Record<string, unknown> }) {
        const { data, error } = await admin.auth.admin.createUser({ ...input, email_confirm: true });
        if (error || !data.user) throw new Error(error?.message ?? "createUser failed");
        return data.user.id;
      },
      async deleteUser(id: string) {
        await admin.auth.admin.deleteUser(id);
      },
      async updatePassword(id: string, password: string) {
        const { error } = await admin.auth.admin.updateUserById(id, { password });
        if (error) throw new Error(error.message);
      },
      async setBanned(id: string, banned: boolean) {
        const { error } = await admin.auth.admin.updateUserById(id, { ban_duration: banned ? "876000h" : "none" });
        if (error) throw new Error(error.message);
      },
      async verifyPassword(email: string, password: string) {
        const { data, error } = await anon().auth.signInWithPassword({ email, password });
        if (error || !data.session) return false;
        await admin.auth.admin.signOut(data.session.access_token).catch(() => undefined); // drop the probe session
        return true;
      },
    },
  };
}
