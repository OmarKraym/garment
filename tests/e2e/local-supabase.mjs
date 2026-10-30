// Local stand-in for Supabase, FOR TESTS ONLY (never deployed). It speaks the same HTTP protocol the
// browser uses (Auth /token, PostgREST /rpc, /functions/v1) but runs the REAL database functions on a
// throw-away PostgreSQL database and the REAL Edge Function handlers. Only password storage is fake.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { createTestDb } from "../db.mjs";
import { handleAccount, handleStaffAdmin } from "../../supabase/functions/_shared/handlers.js";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const WEB = path.join(ROOT, "web");
const ANON_KEY = "local-test-anon-key";
const DOMAIN = "staff.factory.invalid";
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml", ".png": "image/png", ".webmanifest": "application/manifest+json" };

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

/** Header rules from web/_headers (the same file the real static host uses): { "/*": {...}, "/sw.js": {...} }. */
function hostHeaders() {
  const rules = {};
  let rule = null;
  for (const line of fs.readFileSync(path.join(WEB, "_headers"), "utf8").split("\n")) {
    if (/^\//.test(line)) { rule = line.trim(); rules[rule] = {}; continue; }
    const m = /^\s+([A-Za-z-]+):\s*(.+)$/.exec(line);
    if (m && rule && m[1] !== "Strict-Transport-Security") rules[rule][m[1]] = m[2]; // no HSTS on http://localhost
  }
  return (p) => ({ ...rules["/*"], ...(rules[p] ?? {}) });
}

export async function startServer({ port = 0 } = {}) {
  const t = await createTestDb();
  const secret = crypto.randomBytes(32);
  const refresh = new Map();
  const q = (sql, args) => t.pool.query(sql, args);
  const headers = hostHeaders();
  let origin = "";

  const sign = (p) => { const x = `${b64({ alg: "HS256", typ: "JWT" })}.${b64(p)}`; return `${x}.${crypto.createHmac("sha256", secret).update(x).digest("base64url")}`; };
  function verify(token) {
    const [a, b, s] = String(token).split(".");
    if (!s || !crypto.timingSafeEqual(Buffer.from(s), Buffer.from(crypto.createHmac("sha256", secret).update(`${a}.${b}`).digest("base64url")))) return null;
    const p = JSON.parse(Buffer.from(b, "base64url").toString());
    return p.exp > Date.now() / 1000 ? p : null;
  }
  async function activeUser(id) {
    const { rows } = await q("SELECT id, email FROM auth.users WHERE id = $1 AND (banned_until IS NULL OR banned_until < now())", [id]);
    return rows[0] ?? null;
  }
  function session(u) {
    const now = Math.floor(Date.now() / 1000);
    const rt = crypto.randomBytes(24).toString("hex");
    refresh.set(rt, u.id);
    return { access_token: sign({ sub: u.id, email: u.email, role: "authenticated", aud: "authenticated", iat: now, exp: now + 3600 }),
      token_type: "bearer", expires_in: 3600, expires_at: now + 3600, refresh_token: rt,
      user: { id: u.id, aud: "authenticated", role: "authenticated", email: u.email, app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() } };
  }

  const deps = {
    get allowedOrigins() { return [origin]; },
    emailDomain: DOMAIN,
    async getCaller(jwt) { const p = verify(jwt); return p ? activeUser(p.sub) : null; },
    rpc: (fn, args) => t.callAs("service_role", null, fn, args),
    auth: {
      async createUser({ email, password }) { return (await q("INSERT INTO auth.users (email, encrypted_password) VALUES ($1,$2) RETURNING id", [email, password])).rows[0].id; },
      async deleteUser(id) { await q("DELETE FROM auth.users WHERE id = $1", [id]); },
      async updatePassword(id, pw) { await q("UPDATE auth.users SET encrypted_password = $2 WHERE id = $1", [id, pw]); },
      async setBanned(id, b) { await q("UPDATE auth.users SET banned_until = $2 WHERE id = $1", [id, b ? "infinity" : null]); },
      async verifyPassword(email, pw) { return (await q("SELECT 1 FROM auth.users WHERE email = $1 AND encrypted_password = $2", [email, pw])).rowCount === 1; },
    },
    log: (...a) => console.error(...a),
  };

  const send = (res, status, body, extra = {}) => {
    res.writeHead(status, { "Content-Type": "application/json", ...extra });
    res.end(body === undefined ? "" : JSON.stringify(body));
  };
  const readJson = async (req) => { let s = ""; for await (const c of req) s += c; return s ? JSON.parse(s) : {}; };

  async function handle(req, res) {
    const url = new URL(req.url, origin);
    const p = url.pathname;
    if (p.startsWith("/auth/v1/")) {
      if (p === "/auth/v1/token" && req.method === "POST") {
        const body = await readJson(req);
        let user = null;
        if (url.searchParams.get("grant_type") === "password") {
          const { rows } = await q("SELECT id, email FROM auth.users WHERE email = lower($1) AND encrypted_password = $2 AND (banned_until IS NULL OR banned_until < now())", [body.email, body.password]);
          user = rows[0] ?? null;
        } else if (url.searchParams.get("grant_type") === "refresh_token" && refresh.has(body.refresh_token)) {
          user = await activeUser(refresh.get(body.refresh_token));
          refresh.delete(body.refresh_token);
        }
        return user ? send(res, 200, session(user)) : send(res, 400, { code: 400, error_code: "invalid_credentials", msg: "Invalid login credentials" });
      }
      if (p === "/auth/v1/logout") return send(res, 204);
      if (p === "/auth/v1/user") {
        const pl = verify((req.headers.authorization ?? "").slice(7));
        const u = pl && (await activeUser(pl.sub));
        return u ? send(res, 200, session(u).user) : send(res, 401, { code: 401, msg: "invalid JWT" });
      }
      return send(res, 404, { msg: "not found" });
    }
    if (p.startsWith("/rest/v1/rpc/") && req.method === "POST") {
      if (req.headers.apikey !== ANON_KEY) return send(res, 401, { message: "Invalid API key" });
      const token = (req.headers.authorization ?? "").replace(/^Bearer /, "");
      let role = "anon", sub = null;
      if (token !== ANON_KEY) {
        const pl = verify(token);
        if (!pl) return send(res, 401, { code: "PGRST301", message: "JWT expired", details: null, hint: null });
        role = "authenticated"; sub = pl.sub;
      }
      const fn = p.slice("/rest/v1/rpc/".length);
      if (!/^[a-z_][a-z0-9_]*$/.test(fn)) return send(res, 404, { code: "PGRST202", message: "not found" });
      try {
        const data = await t.callAs(role, sub, fn, await readJson(req));
        return send(res, 200, data);
      } catch (e) {
        const status = e.sqlstate === "42501" ? (role === "anon" ? 401 : 403) : e.sqlstate === "42883" ? 404 : 400;
        return send(res, status, { code: e.sqlstate, message: e.message, details: null, hint: e.code !== e.sqlstate ? e.code : null });
      }
    }
    if (p.startsWith("/functions/v1/")) {
      const name = p.slice("/functions/v1/".length);
      const handler = { "staff-admin": handleStaffAdmin, account: handleAccount }[name];
      if (!handler) return send(res, 404, { msg: "not found" });
      let body = "";
      for await (const c of req) body += c;
      const r = await handler(new Request(url, { method: req.method, headers: req.headers, body: req.method === "POST" ? body : undefined }), deps);
      res.writeHead(r.status, Object.fromEntries(r.headers.entries()));
      return res.end(await r.text());
    }
    // static site
    if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, {});
    const rel = p === "/" ? "index.html" : decodeURIComponent(p).replace(/^\/+/, "");
    const file = path.resolve(WEB, rel);
    if (!file.startsWith(WEB + path.sep) || path.basename(file) === "_headers" || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, headers(p)); return res.end("not found");
    }
    let content = fs.readFileSync(file);
    if (rel === "js/config.js") {
      content = content.toString().replace(/supabaseUrl: "[^"]*"/, `supabaseUrl: ${JSON.stringify(origin)}`)
        .replace(/supabaseAnonKey: "[^"]*"/, `supabaseAnonKey: ${JSON.stringify(ANON_KEY)}`);
    }
    res.writeHead(200, { ...headers(p), "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream" });
    res.end(content);
  }

  const server = http.createServer((req, res) => handle(req, res).catch((e) => { console.error(e); if (!res.headersSent) send(res, 500, { message: "server error" }); }));
  await new Promise((r) => server.listen(port, "127.0.0.1", r));
  origin = `http://127.0.0.1:${server.address().port}`;

  /** Creates the first administrator exactly like production bootstrap (auth user + svc_provision_employee with null caller). */
  async function bootstrapAdmin(username, password) {
    const id = (await q("INSERT INTO auth.users (email, encrypted_password) VALUES ($1,$2) RETURNING id", [`${username}@${DOMAIN}`, password])).rows[0].id;
    return t.callAs("service_role", null, "svc_provision_employee", { p_caller: null, p_auth_user: id, p_username: username, p_display: "مدير النظام", p_roles: [{ role: "ADMIN" }] });
  }

  return { origin, db: t, bootstrapAdmin, async close() { await new Promise((r) => server.close(r)); await t.close(); } };
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  const s = await startServer({ port: Number(process.env.PORT ?? 4173) });
  await s.bootstrapAdmin("admin", "Admin#Pass2026");
  console.log(`Local test system: ${s.origin}  (user: admin / password: Admin#Pass2026) — fake data, Ctrl+C to stop`);
  const stop = async () => { await s.close(); process.exit(0); };
  process.on("SIGINT", stop); process.on("SIGTERM", stop);
}
