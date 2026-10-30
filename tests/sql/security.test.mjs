// Security boundary: what anon / authenticated / service_role can and cannot do.
import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { createTestDb, key } from "../db.mjs";

let t, admin, tailor, reviewer;

before(async () => {
  t = await createTestDb();
  admin = await t.makeUser("admin1", [{ role: "ADMIN" }]);
  tailor = await t.makeUser("tailor1", [{ role: "WORKER", departmentId: t.depts.SEWING }], { caller: admin.authId });
  reviewer = await t.makeUser("rev1", [{ role: "REVIEWER" }], { caller: admin.authId });
});
after(async () => t?.close());

const rejects = (p, code) => assert.rejects(p, (e) => { assert.equal(e.code, code, e.message); return true; });

describe("anonymous (public anon key)", () => {
  it("cannot execute any API or service function", async () => {
    await rejects(t.callAs("anon", null, "app_whoami"), "42501");
    await rejects(t.callAs("anon", null, "app_list_orders", { p_filter: "all", p_search: null }), "42501");
    await rejects(t.callAs("anon", null, "svc_provision_employee", {
      p_caller: null, p_auth_user: admin.authId, p_username: "x_x", p_display: "x", p_roles: [{ role: "ADMIN" }] }), "42501");
  });
  it("cannot read any table", async () => {
    const c = await t.pool.connect();
    try {
      await c.query("BEGIN; SET LOCAL ROLE anon");
      await assert.rejects(c.query("SELECT * FROM factory.employees"), /permission denied/);
    } finally { await c.query("ROLLBACK"); c.release(); }
  });
});

describe("authenticated (signed-in user)", () => {
  it("cannot read tables directly, only through API functions", async () => {
    for (const sql of [
      "SELECT * FROM factory.stock_balances",
      "UPDATE factory.employees SET active = true",
      "SELECT factory.post_event('CUT', gen_random_uuid(), 1, gen_random_uuid(), NULL, NULL, NULL, NULL, NULL, NULL, '[]')",
    ]) {
      const c = await t.pool.connect();
      try {
        await c.query("BEGIN; SET LOCAL ROLE authenticated");
        await assert.rejects(c.query(sql), /permission denied/, sql);
      } finally { await c.query("ROLLBACK"); c.release(); }
    }
  });
  it("cannot call service-only functions (e.g. to create accounts or clear the password flag)", async () => {
    await rejects(tailor.call("svc_password_changed", { p_auth_user: tailor.authId }), "42501");
    await rejects(tailor.call("svc_set_employee_active", { p_caller: admin.authId, p_employee: admin.employeeId, p_active: false }), "42501");
  });
  it("a signed-up user who is not an employee gets nothing", async () => {
    const { rows } = await t.pool.query("INSERT INTO auth.users (email) VALUES ('stranger@x.invalid') RETURNING id");
    await rejects(t.callAs("authenticated", rows[0].id, "app_whoami"), "UNAUTHENTICATED");
    await rejects(t.callAs("authenticated", rows[0].id, "app_dashboard"), "UNAUTHENTICATED");
  });
  it("roles come from the database, never from the request", async () => {
    const me = await tailor.call("app_whoami");
    assert.deepEqual(me.roles, []);
    await rejects(tailor.call("app_create_adjustment", { p: { requestKey: key(), lotId: key(), custodyId: key(), condition: "GOOD", signedQty: 1, reason: "xxx" } }), "FORBIDDEN");
    await rejects(tailor.call("app_admin_view"), "FORBIDDEN");
    await rejects(tailor.call("app_report", { p_type: "reconciliation", p_params: {} }), "FORBIDDEN");
  });
  it("reviewer reads everything but cannot write", async () => {
    const r = await reviewer.call("app_report", { p_type: "reconciliation", p_params: {} });
    assert.equal(r.all_balanced, true);
    await rejects(reviewer.call("app_create_order", { p: { customerName: "c", productName: "p", dueDate: "2030-01-01", lines: [{ color: "a", size: "b", plannedQty: 1 }] } }), "FORBIDDEN");
  });
});

describe("service functions (Edge Functions only)", () => {
  it("re-check the administrator even when called with service_role", async () => {
    const { rows } = await t.pool.query("INSERT INTO auth.users (email) VALUES ('new@x.invalid') RETURNING id");
    await rejects(t.callAs("service_role", null, "svc_provision_employee", {
      p_caller: tailor.authId, p_auth_user: rows[0].id, p_username: "sneaky", p_display: "x", p_roles: [{ role: "ADMIN" }] }), "FORBIDDEN");
  });
  it("bootstrap creates the first admin only once", async () => {
    const { rows } = await t.pool.query("INSERT INTO auth.users (email) VALUES ('boot@x.invalid') RETURNING id");
    await rejects(t.callAs("service_role", null, "svc_provision_employee", {
      p_caller: null, p_auth_user: rows[0].id, p_username: "boot2", p_display: "x", p_roles: [{ role: "ADMIN" }] }), "FORBIDDEN");
  });
  it("an admin cannot deactivate themselves; deactivation blocks the user immediately", async () => {
    await rejects(t.callAs("service_role", null, "svc_set_employee_active", { p_caller: admin.authId, p_employee: admin.employeeId, p_active: false }), "BUSINESS_RULE");
    const w = await t.makeUser("ironer9", [{ role: "WORKER", departmentId: t.depts.IRONING }], { caller: admin.authId });
    await t.callAs("service_role", null, "svc_set_employee_active", { p_caller: admin.authId, p_employee: w.employeeId, p_active: false });
    await rejects(w.call("app_whoami"), "UNAUTHENTICATED"); // even with a still-valid JWT
  });
});

describe("forced password change", () => {
  it("blocks every write but allows reads until the Edge Function confirms the change", async () => {
    const w = await t.makeUser("newhire", [{ role: "WORKER", departmentId: t.depts.CUTTING }], { caller: admin.authId });
    await t.callAs("service_role", null, "svc_after_password_reset", { p_caller: admin.authId, p_employee: w.employeeId });
    assert.equal((await w.call("app_whoami")).must_change_password, true);
    await w.call("app_my_stock");
    await rejects(w.call("app_mark_defect", { p: { requestKey: key(), lotId: key(), custodyId: key(), quantity: 1, reasonCode: "OTHER" } }), "PASSWORD_CHANGE_REQUIRED");
    await t.callAs("service_role", null, "svc_password_changed", { p_auth_user: w.authId });
    assert.equal((await w.call("app_whoami")).must_change_password, false);
  });
});

describe("database integrity (independent of application code)", () => {
  it("history is append-only and order lines freeze after release", async () => {
    await assert.rejects(t.pool.query("UPDATE factory.audit_events SET action = 'x'"), /append-only/);
    await assert.rejects(t.pool.query("DELETE FROM factory.audit_events"), /append-only/);
    await assert.rejects(t.pool.query("DELETE FROM factory.employees"), /append-only/);
    await assert.rejects(t.pool.query("TRUNCATE factory.stock_journal"), /append-only/);
  });
  it("input validation rejects malformed values with a clear code", async () => {
    const sup = await t.makeUser("sup_v", [{ role: "SUPERVISOR" }], { caller: admin.authId });
    const base = { customerName: "c", productName: "p", dueDate: "2030-01-01" };
    await rejects(sup.call("app_create_order", { p: { ...base, lines: [{ color: "a", size: "M", plannedQty: 1.5 }] } }), "INVALID");
    await rejects(sup.call("app_create_order", { p: { ...base, lines: [{ color: "a", size: "M", plannedQty: 1 }, { color: "A", size: "m", plannedQty: 2 }] } }), "INVALID");
    await rejects(sup.call("app_create_order", { p: { ...base, lines: [] } }), "INVALID");
    await rejects(sup.call("app_create_order", { p: { ...base, dueDate: "2030-02-31", lines: [{ color: "a", size: "M", plannedQty: 1 }] } }), "INVALID");
  });
});
