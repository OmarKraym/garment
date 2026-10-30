// Edge Function logic against the real database functions; only Supabase Auth is faked (in auth.users).
import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { createTestDb } from "../db.mjs";
import { checkPassword, generateTempPassword, handleAccount, handleStaffAdmin } from "../../supabase/functions/_shared/handlers.js";

const ORIGIN = "https://factory.example.test";
let t, admin, tailor, deps;

before(async () => {
  t = await createTestDb();
  admin = await t.makeUser("admin1", [{ role: "ADMIN" }]);
  tailor = await t.makeUser("tailor1", [{ role: "WORKER", departmentId: t.depts.SEWING }], { caller: admin.authId });
  await t.pool.query("UPDATE auth.users SET encrypted_password = 'Admin#Pass2026' WHERE id = $1", [admin.authId]);
  const q = (sql, args) => t.pool.query(sql, args);
  deps = {
    allowedOrigins: [ORIGIN],
    emailDomain: "staff.factory.invalid",
    async getCaller(jwt) { // tests use the auth uuid as the "token"
      const { rows } = await q("SELECT id, email FROM auth.users WHERE id::text = $1 AND (banned_until IS NULL OR banned_until < now())", [jwt]);
      return rows[0] ?? null;
    },
    rpc: (fn, args) => t.callAs("service_role", null, fn, args),
    auth: {
      async createUser({ email, password }) { return (await q("INSERT INTO auth.users (email, encrypted_password) VALUES ($1,$2) RETURNING id", [email, password])).rows[0].id; },
      async deleteUser(id) { await q("DELETE FROM auth.users WHERE id = $1", [id]); },
      async updatePassword(id, pw) { await q("UPDATE auth.users SET encrypted_password = $2 WHERE id = $1", [id, pw]); },
      async setBanned(id, b) { await q("UPDATE auth.users SET banned_until = $2 WHERE id = $1", [id, b ? "infinity" : null]); },
      async verifyPassword(email, pw) { return (await q("SELECT 1 FROM auth.users WHERE email = $1 AND encrypted_password = $2", [email, pw])).rowCount === 1; },
    },
  };
});
after(async () => t?.close());

const req = (body, { token, origin = ORIGIN, method = "POST" } = {}) =>
  new Request("https://x.supabase.co/functions/v1/f", {
    method,
    headers: { ...(origin ? { origin } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
const admin_ = (body, opts) => handleStaffAdmin(req(body, { token: admin.authId, ...opts }), deps);
const authCount = async () => (await t.pool.query("SELECT count(*)::int n FROM auth.users")).rows[0].n;
const roles = () => [{ role: "WORKER", departmentId: t.depts.WAREHOUSE }];

describe("CORS and authentication", () => {
  it("only configured origins are allowed; preflight works", async () => {
    const pre = await handleStaffAdmin(req(null, { method: "OPTIONS" }), deps);
    assert.equal(pre.status, 204);
    assert.equal(pre.headers.get("access-control-allow-origin"), ORIGIN);
    assert.equal((await handleStaffAdmin(req(null, { method: "OPTIONS", origin: "https://evil.test" }), deps)).status, 403);
    assert.equal((await admin_({ action: "create" }, { origin: "https://evil.test" })).status, 403);
  });
  it("requires a valid session", async () => {
    assert.equal((await handleStaffAdmin(req({ action: "create" }), deps)).status, 401);
    assert.equal((await handleStaffAdmin(req({ action: "create" }, { token: "not-a-token" }), deps)).status, 401);
  });
});

describe("one-time passwords", () => {
  it("are generated on the server with a strong, readable format", () => {
    const seen = new Set();
    const used = new Set();
    for (let i = 0; i < 2000; i++) {
      const pw = generateTempPassword("abc");
      assert.match(pw, /^[A-HJ-NP-Za-km-np-z2-9]{4}-[A-HJ-NP-Za-km-np-z2-9]{4}-[A-HJ-NP-Za-km-np-z2-9]{4}$/);
      assert.doesNotThrow(() => checkPassword(pw, "abc"));
      assert.ok(!pw.toLowerCase().includes("abc"));
      seen.add(pw);
      for (const ch of pw.replace(/-/g, "")) used.add(ch);
    }
    assert.equal(seen.size, 2000);
    assert.equal(used.size, 55); // every character of the alphabet is reachable
  });
});

describe("staff-admin", () => {
  it("a non-admin cannot create accounts and no auth user is created", async () => {
    const before = await authCount();
    const res = await handleStaffAdmin(req({ action: "create", username: "intruder", displayName: "x", roles: [{ role: "ADMIN" }] }, { token: tailor.authId }), deps);
    assert.equal(res.status, 403);
    assert.equal(await authCount(), before);
  });
  it("creates the employee with a system one-time password (72h, forced change); a client password is ignored", async () => {
    const res = await admin_({ action: "create", username: "Store2", displayName: "أمين مخزن", password: "Chosen#ByAdmin1", roles: roles() });
    assert.equal(res.status, 200, await res.clone().text());
    const body = await res.json();
    assert.equal(body.username, "store2");
    assert.equal(body.expiresInHours, 72);
    assert.notEqual(body.temporaryPassword, "Chosen#ByAdmin1");
    assert.equal(await deps.auth.verifyPassword("store2@staff.factory.invalid", body.temporaryPassword), true);
    assert.equal(res.headers.get("cache-control"), "no-store");
    const e = (await t.pool.query(`SELECT username, must_change_password,
        temp_password_expires_at BETWEEN now() + interval '71 hours' AND now() + interval '73 hours' AS expires_72h
        FROM factory.employees WHERE id = $1`, [body.id])).rows[0];
    assert.deepEqual(e, { username: "store2", must_change_password: true, expires_72h: true });
    assert.equal((await admin_({ action: "create", username: "store2", displayName: "x", roles: roles() })).status, 409);
  });
  it("rolls back the auth user if the employee cannot be created", async () => {
    const before = await authCount();
    const res = await admin_({ action: "create", username: "ghost", displayName: "x",
      roles: [{ role: "WORKER", departmentId: "00000000-0000-0000-0000-000000000000" }] });
    assert.equal(res.status, 422);
    assert.equal(await authCount(), before);
  });
  it("reset issues a new one-time password; the admin cannot reset their own; deactivation bans", async () => {
    const r1 = await admin_({ action: "reset_password", employeeId: tailor.employeeId });
    assert.equal(r1.status, 200);
    tailor.temp = (await r1.json()).temporaryPassword;
    assert.equal(await deps.auth.verifyPassword("tailor1@staff.factory.invalid", tailor.temp), true);
    assert.equal((await tailor.call("app_whoami")).must_change_password, true);
    await assert.rejects(tailor.call("app_dashboard").then(() => tailor.call("app_create_order", { p: {} })), (e) => e.code === "PASSWORD_CHANGE_REQUIRED");
    assert.equal((await admin_({ action: "reset_password", employeeId: admin.employeeId })).status, 422);
    const r2 = await admin_({ action: "set_active", employeeId: tailor.employeeId, active: false });
    assert.equal(r2.status, 200);
    await assert.rejects(tailor.call("app_whoami"), (e) => e.code === "UNAUTHENTICATED");
    assert.equal(await deps.getCaller(tailor.authId), null); // banned
    assert.equal((await admin_({ action: "set_active", employeeId: tailor.employeeId, active: true })).status, 200);
    assert.equal((await admin_({ action: "set_active", employeeId: admin.employeeId, active: false })).status, 422);
  });
  it("an expired one-time password gives no access at all", async () => {
    const res = await admin_({ action: "create", username: "late1", displayName: "متأخر", roles: roles() });
    const { id, temporaryPassword } = await res.json();
    const auth = (await t.pool.query("SELECT auth_user_id FROM factory.employees WHERE id = $1", [id])).rows[0].auth_user_id;
    await t.pool.query("UPDATE factory.employees SET temp_password_expires_at = now() - interval '1 minute' WHERE id = $1", [id]);
    await assert.rejects(t.callAs("authenticated", auth, "app_whoami"), (e) => e.code === "UNAUTHENTICATED" && /انتهت صلاحية/.test(e.message));
    const change = await handleAccount(req({ action: "change_password", currentPassword: temporaryPassword, newPassword: "Late#Mine2026x" }, { token: auth }), deps);
    assert.equal(change.status, 401);
    const view = await admin.call("app_admin_view");
    assert.equal(view.employees.find((x) => x.id === id).temp_expired, true);
  });
});

describe("account: change own password", () => {
  it("verifies the current password, applies policy, then clears the forced-change flag", async () => {
    const call = (body) => handleAccount(req({ action: "change_password", ...body }, { token: tailor.authId }), deps);
    assert.equal((await call({ currentPassword: "WRONG", newPassword: "Mine#Pass2026x" })).status, 400);
    assert.equal((await call({ currentPassword: tailor.temp, newPassword: tailor.temp })).status, 400);
    assert.equal((await call({ currentPassword: tailor.temp, newPassword: "weak" })).status, 400);
    assert.equal((await tailor.call("app_whoami")).must_change_password, true);
    const ok = await call({ currentPassword: tailor.temp, newPassword: "Mine#Pass2026x" });
    assert.equal(ok.status, 200, await ok.clone().text());
    assert.equal((await tailor.call("app_whoami")).must_change_password, false);
    const row = (await t.pool.query("SELECT temp_password_expires_at FROM factory.employees WHERE id = $1", [tailor.employeeId])).rows[0];
    assert.equal(row.temp_password_expires_at, null);
    assert.equal(await deps.auth.verifyPassword("tailor1@staff.factory.invalid", tailor.temp), false); // one-time: no longer valid
  });
});
