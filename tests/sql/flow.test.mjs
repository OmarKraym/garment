// Production workflow and quantity integrity, called exactly like the browser does (RPC as authenticated).
import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { createTestDb, key } from "../db.mjs";

let t, admin, sup, rev, cutter, tailorA, tailorB, fin1, iron, fin2, store;
const rejects = (p, code) => assert.rejects(p, (e) => { assert.equal(e.code, code, e.message); return true; });
const today = () => new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tripoli" });
const shift = (n) => { const d = new Date(`${today()}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

const pool = (dept) => t.pool.query("SELECT id FROM factory.custodies WHERE kind='DEPARTMENT' AND department_id=$1", [t.depts[dept]]).then((r) => r.rows[0].id);
const own = (dept, u) => t.pool.query("SELECT id FROM factory.custodies WHERE kind='EMPLOYEE' AND department_id=$1 AND employee_id=$2", [t.depts[dept], u.employeeId]).then((r) => r.rows[0].id);
const bal = (lot, custody, cond = "GOOD") => t.pool.query("SELECT coalesce(sum(qty),0)::int q FROM factory.stock_balances WHERE lot_id=$1 AND custody_id=$2 AND condition=$3", [lot, custody, cond]).then((r) => r.rows[0].q);
const total = (lot) => t.pool.query("SELECT coalesce(sum(qty),0)::int q FROM factory.stock_balances WHERE lot_id=$1", [lot]).then((r) => r.rows[0].q);
async function balanced() {
  const r = await rev.call("app_report", { p_type: "reconciliation", p_params: {} });
  assert.deepEqual(r.lots.filter((l) => !l.balanced), []);
  assert.equal(r.all_balanced, true);
  assert.equal(r.negative_balances, 0);
}
// The order number is automatic; `label` only names the customer so tests can tell orders apart.
async function releasedOrder(label, qty, due = shift(10)) {
  const { id, orderCode, sent } = await sup.call("app_create_order", { p: { customerName: `زبون ${label}`, productName: "قميص", dueDate: due, send: true, lines: [{ color: "أزرق", size: "M", plannedQty: qty }] } });
  assert.equal(sent, true);
  const o = await sup.call("app_get_order", { p_id: id });
  assert.equal(o.status, "RELEASED");
  return { orderId: id, lineId: o.lines[0].id, orderCode };
}
const cut = (lineId, quantity, extra = {}) => cutter.call("app_create_cut_lot", { p: { requestKey: key(), orderLineId: lineId, quantity, cuttingDepartmentId: t.depts.CUTTING, ...extra } });
const send = (u, p) => u.call("app_dispatch", { p: { requestKey: key(), condition: "GOOD", ...p } });
const accept = (u, id, n) => u.call("app_receive", { p_id: id, p: { requestKey: key(), acceptQty: n, disputeQty: 0, rejectQty: 0 } });

before(async () => {
  t = await createTestDb();
  admin = await t.makeUser("admin", [{ role: "ADMIN" }]);
  const mk = (u, roles) => t.makeUser(u, roles, { caller: admin.authId });
  sup = await mk("sup", [{ role: "SUPERVISOR" }]);
  rev = await mk("rev", [{ role: "REVIEWER" }]);
  cutter = await mk("cutter", [{ role: "WORKER", departmentId: t.depts.CUTTING }]);
  tailorA = await mk("tailora", [{ role: "WORKER", departmentId: t.depts.SEWING }]);
  tailorB = await mk("tailorb", [{ role: "WORKER", departmentId: t.depts.SEWING }]);
  fin1 = await mk("fin1", [{ role: "WORKER", departmentId: t.depts.FINISHING_1 }]);
  iron = await mk("iron", [{ role: "WORKER", departmentId: t.depts.IRONING }]);
  fin2 = await mk("fin2", [{ role: "WORKER", departmentId: t.depts.FINISHING_2 }]);
  store = await mk("store", [{ role: "WORKER", departmentId: t.depts.WAREHOUSE }]);
});
after(async () => t?.close());

describe("orders", () => {
  it("automatic sequential numbers, supervisor only, no cutting before sending", async () => {
    const y = new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tripoli" }).slice(0, 4);
    const a = await releasedOrder("A", 10), b = await releasedOrder("B", 10);
    assert.match(a.orderCode, new RegExp(`^PO-${y}-\\d{4}$`));
    assert.equal(Number(b.orderCode.slice(-4)), Number(a.orderCode.slice(-4)) + 1);
    // a client-supplied number is ignored
    const own = await sup.call("app_create_order", { p: { orderCode: "HACK-1", customerName: "c", productName: "p", dueDate: shift(1), lines: [{ color: "a", size: "b", plannedQty: 1 }] } });
    assert.notEqual(own.orderCode, "HACK-1");
    await rejects(cutter.call("app_create_order", { p: { customerName: "c", productName: "p", dueDate: shift(1), lines: [{ color: "a", size: "b", plannedQty: 1 }] } }), "FORBIDDEN");
    const { id } = await sup.call("app_create_order", { p: { customerName: "c", productName: "p", dueDate: shift(1), lines: [{ color: "a", size: "b", plannedQty: 5 }] } });
    const line = (await sup.call("app_get_order", { p_id: id })).lines[0].id;
    await rejects(cut(line, 1), "BUSINESS_RULE");                // a draft is not sent to cutting yet
    await sup.call("app_release_order", { p_id: id });
    const v = await cutter.call("app_cutting_view");
    assert.ok(v.orders.some((o) => o.id === id));
  });

  it("lines keep the order the supervisor typed (S, M, L, XL), not alphabetical", async () => {
    const lines = ["S", "M", "L", "XL"].map((size) => ({ color: "أبيض", size, plannedQty: 1 }));
    const { id } = await sup.call("app_create_order", { p: { customerName: "c", productName: "p", dueDate: shift(5), send: true, lines } });
    assert.deepEqual((await sup.call("app_get_order", { p_id: id })).lines.map((l) => l.size), ["S", "M", "L", "XL"]);
    assert.deepEqual((await cutter.call("app_cutting_view")).orders.find((o) => o.id === id).lines.map((l) => l.size), ["S", "M", "L", "XL"]);
  });

  it("the cutter changes quantities only: never colours/sizes, never below what is cut", async () => {
    const { orderId, lineId } = await releasedOrder("QTY", 10);
    await cut(lineId, 6);
    await cutter.call("app_set_line_quantities", { p_order: orderId, p: { lines: [{ lineId, plannedQty: 8 }] } });
    assert.equal((await sup.call("app_get_order", { p_id: orderId })).lines[0].planned_qty, 8);
    await rejects(cutter.call("app_set_line_quantities", { p_order: orderId, p: { lines: [{ lineId, plannedQty: 5 }] } }), "BUSINESS_RULE");
    await rejects(tailorA.call("app_set_line_quantities", { p_order: orderId, p: { lines: [{ lineId, plannedQty: 9 }] } }), "FORBIDDEN");
    await assert.rejects(t.pool.query("UPDATE factory.order_lines SET color = 'أحمر' WHERE id = $1", [lineId]), /frozen/);
    await assert.rejects(t.pool.query("DELETE FROM factory.order_lines WHERE id = $1", [lineId]), /frozen|append-only/);
    const audit = await t.pool.query("SELECT metadata FROM factory.audit_events WHERE action = 'order.quantities' AND target_id = $1", [orderId]);
    assert.equal(audit.rows[0].metadata.changes[0].before, 10);
  });

  it("the cutter distributes a whole order to several tailors in one step (all or nothing)", async () => {
    const { lineId } = await releasedOrder("SPLIT", 12);
    const { lotId } = await cut(lineId, 12);
    const cp = await pool("CUTTING");
    const item = (emp, quantity) => ({ lotId, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: emp.employeeId, quantity });
    await rejects(cutter.call("app_dispatch_batch", { p: { requestKey: key(), items: [item(tailorA, 8), item(tailorB, 8)] } }), "INSUFFICIENT_STOCK");
    assert.equal((await tailorA.call("app_list_transfers", { p_tab: "incoming" })).rows.filter((x) => x.order_code).length, 0); // nothing half-sent
    await rejects(cutter.call("app_dispatch_batch", { p: { requestKey: key(), items: [item(tailorA, 1), item(tailorA, 1)] } }), "INVALID");
    const k = key();
    const r = await cutter.call("app_dispatch_batch", { p: { requestKey: k, items: [item(tailorA, 7), item(tailorB, 5)] } });
    assert.deepEqual([r.transfers, r.workers, r.quantity, r.replayed], [2, 2, 12, false]);
    assert.equal((await cutter.call("app_dispatch_batch", { p: { requestKey: k, items: [item(tailorA, 7), item(tailorB, 5)] } })).replayed, true);
    const inc = await tailorB.call("app_list_transfers", { p_tab: "incoming" });
    assert.ok(inc.rows.some((x) => x.pending_qty === 5));
    await balanced();
  });
});

describe("blueprint §7 example + full seven-stage workflow", () => {
  let orderId, lineId, lot, first, orderCode;
  it("cut 100 → send 40 → accept 35 / dispute 5: still exactly 100", async () => {
    ({ orderId, lineId, orderCode } = await releasedOrder("PO-100", 100));
    await rejects(cut(lineId, 101), "BUSINESS_RULE");
    lot = (await cut(lineId, 100)).lotId;
    const cp = await pool("CUTTING");
    const tr = await send(cutter, { lotId: lot, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, quantity: 40 });
    first = tr.transferId;
    assert.equal(await bal(lot, cp), 60);
    await rejects(accept(tailorB, first, 40), "FORBIDDEN");
    await rejects(accept(tailorA, first, 41), "BUSINESS_RULE");
    const r = await tailorA.call("app_receive", { p_id: first, p: { requestKey: key(), acceptQty: 35, disputeQty: 5, rejectQty: 0, reason: "نقص" } });
    assert.equal(r.state, "DISPUTED");
    assert.equal(await bal(lot, await own("SEWING", tailorA)), 35);
    assert.equal(await total(lot), 100);
    await balanced();
  });

  it("defect → return → repair → forward to warehouse → partial delivery; never creates units", async () => {
    const ta = await own("SEWING", tailorA), f1 = await pool("FINISHING_1"), ir = await pool("IRONING"), f2 = await pool("FINISHING_2"), wh = await pool("WAREHOUSE");
    await rejects(send(tailorA, { lotId: lot, fromCustodyId: ta, toDepartmentId: t.depts.IRONING, quantity: 1 }), "BUSINESS_RULE"); // skip stage
    await accept(fin1, (await send(tailorA, { lotId: lot, fromCustodyId: ta, toDepartmentId: t.depts.FINISHING_1, quantity: 30 })).transferId, 30);
    const df = await fin1.call("app_mark_defect", { p: { requestKey: key(), lotId: lot, custodyId: f1, quantity: 4, reasonCode: "SEWING_ERROR", responsibleDepartmentId: t.depts.SEWING } });
    assert.equal(await total(lot), 100);
    await rejects(send(fin1, { lotId: lot, fromCustodyId: f1, toDepartmentId: t.depts.IRONING, condition: "DEFECTIVE", quantity: 4 }), "BUSINESS_RULE");
    await rejects(send(fin1, { lotId: lot, fromCustodyId: f1, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, condition: "DEFECTIVE", quantity: 4 }), "BUSINESS_RULE");
    const back = await send(fin1, { lotId: lot, fromCustodyId: f1, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, condition: "DEFECTIVE", quantity: 4, reason: "خياطة مائلة" });
    await accept(tailorA, back.transferId, 4);
    await tailorA.call("app_repair_defect", { p_id: df.defectId, p: { requestKey: key(), custodyId: ta, quantity: 4 } });
    assert.equal(await bal(lot, ta, "DEFECTIVE"), 0);
    await accept(fin1, (await send(tailorA, { lotId: lot, fromCustodyId: ta, toDepartmentId: t.depts.FINISHING_1, quantity: 4 })).transferId, 4);
    await accept(iron, (await send(fin1, { lotId: lot, fromCustodyId: f1, toDepartmentId: t.depts.IRONING, quantity: 30 })).transferId, 30);
    await accept(fin2, (await send(iron, { lotId: lot, fromCustodyId: ir, toDepartmentId: t.depts.FINISHING_2, quantity: 30 })).transferId, 30);
    await accept(store, (await send(fin2, { lotId: lot, fromCustodyId: f2, toDepartmentId: t.depts.WAREHOUSE, quantity: 30 })).transferId, 30);
    const ship = (u, qty, date = today()) => u.call("app_create_shipment", { p: { requestKey: key(), orderId, deliveredOn: date, lines: [{ lotId: lot, custodyId: wh, quantity: qty }] } });
    await rejects(ship(fin2, 1), "FORBIDDEN");
    await rejects(ship(store, 1, shift(1)), "BUSINESS_RULE");
    await ship(store, 20);
    const o = await sup.call("app_get_order", { p_id: orderId });
    assert.equal(o.delivered_qty, 20);
    assert.equal(o.in_warehouse_qty, 10);
    assert.equal(o.remaining_qty, 80);
    assert.equal(await total(lot), 80);
    await balanced();
  });

  it("supervisor REPLACE scraps units and authorizes exactly one replacement cut", async () => {
    const ta = await own("SEWING", tailorA);
    const df = await tailorA.call("app_mark_defect", { p: { requestKey: key(), lotId: lot, custodyId: ta, quantity: 2, reasonCode: "FABRIC_FLAW" } });
    await rejects(tailorA.call("app_decide_defect", { p_id: df.defectId, p: { requestKey: key(), decision: "SCRAP", quantity: 2, custodyId: ta, reason: "x" } }), "FORBIDDEN");
    const dec = await sup.call("app_decide_defect", { p_id: df.defectId, p: { requestKey: key(), decision: "REPLACE", quantity: 2, custodyId: ta, reason: "عيب قماش" } });
    assert.equal(await total(lot), 78);
    const view = await cutter.call("app_cutting_view");
    assert.equal(view.replacements.length, 1);
    const c = await cut(lineId, 2, { replacementDispositionId: dec.dispositionId });
    assert.equal(c.lotCode, `${orderCode}-L002`);
    await rejects(cut(lineId, 2, { replacementDispositionId: dec.dispositionId }), "BUSINESS_RULE");
    const o = await sup.call("app_get_order", { p_id: orderId });
    assert.equal(o.scrapped_qty, 2);
    assert.equal(o.cut_qty, 102);
    await balanced();
  });

  it("dispute: found units accepted; missing ones only the admin writes off", async () => {
    await tailorA.call("app_resolve_dispute", { p_id: first, p: { requestKey: key(), acceptQty: 3, returnQty: 0, reason: "وُجدت" } });
    const dc = (await t.pool.query("SELECT id FROM factory.custodies WHERE transfer_id=$1 AND kind='DISPUTE'", [first])).rows[0].id;
    const adj = { lotId: lot, custodyId: dc, condition: "GOOD", signedQty: -2, reason: "مفقودة بعد التحقيق" };
    await rejects(sup.call("app_create_adjustment", { p: { requestKey: key(), ...adj } }), "FORBIDDEN");
    await admin.call("app_create_adjustment", { p: { requestKey: key(), ...adj, reference: "INV-1" } });
    const tr = (await t.pool.query("SELECT accepted_qty, written_off_qty, disputed_qty, state FROM factory.transfers WHERE id=$1", [first])).rows[0];
    assert.deepEqual(tr, { accepted_qty: 38, written_off_qty: 2, disputed_qty: 0, state: "CLOSED" });
    await rejects(sup.call("app_close_order", { p_id: orderId }), "BUSINESS_RULE");
    await balanced();
  });
});

describe("concurrency and idempotency", () => {
  it("10 parallel sends of 10 from 60: exactly 6 succeed, none negative", async () => {
    const { lineId } = await releasedOrder("PO-CONC", 60);
    const lot = (await cut(lineId, 60)).lotId;
    const cp = await pool("CUTTING");
    const res = await Promise.allSettled(Array.from({ length: 10 }, () =>
      send(cutter, { lotId: lot, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorB.employeeId, quantity: 10 })));
    assert.equal(res.filter((r) => r.status === "fulfilled").length, 6);
    for (const r of res.filter((x) => x.status === "rejected")) assert.equal(r.reason.code, "INSUFFICIENT_STOCK");
    assert.equal(await bal(lot, cp), 0);
    assert.equal(await total(lot), 60);
    await balanced();
  });

  it("retry with the same key → one transfer; same key with different data → CONFLICT", async () => {
    const { lineId } = await releasedOrder("PO-IDEM", 10);
    const lot = (await cut(lineId, 10)).lotId;
    const cp = await pool("CUTTING");
    const body = { requestKey: key(), lotId: lot, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorB.employeeId, condition: "GOOD", quantity: 4 };
    const [a, b] = await Promise.all([cutter.call("app_dispatch", { p: body }), cutter.call("app_dispatch", { p: body })]);
    assert.equal(a.transferId, b.transferId);
    assert.deepEqual([a.replayed, b.replayed].sort(), [false, true]);
    assert.equal(await bal(lot, cp), 6);
    await rejects(cutter.call("app_dispatch", { p: { ...body, quantity: 5 } }), "CONFLICT");
  });

  it("parallel receipts of one transfer never accept more than dispatched", async () => {
    const { lineId } = await releasedOrder("PO-RCV", 10);
    const lot = (await cut(lineId, 10)).lotId;
    const tr = await send(cutter, { lotId: lot, fromCustodyId: await pool("CUTTING"), toDepartmentId: t.depts.SEWING, toEmployeeId: tailorB.employeeId, quantity: 10 });
    const res = await Promise.allSettled(Array.from({ length: 5 }, () => accept(tailorB, tr.transferId, 6)));
    assert.equal(res.filter((r) => r.status === "fulfilled").length, 1);
    const row = (await t.pool.query("SELECT accepted_qty, pending_qty FROM factory.transfers WHERE id=$1", [tr.transferId])).rows[0];
    assert.deepEqual(row, { accepted_qty: 6, pending_qty: 4 });
    await balanced();
  });
});

describe("deleting an employee account", () => {
  const del = (u, confirm = u.username) => t.callAs("service_role", null, "svc_delete_employee", { p_caller: admin.authId, p_employee: u.employeeId, p_confirm: confirm });
  it("is refused while pieces, transfers or assignments are still in the person's hands", async () => {
    const tmp = await t.makeUser("tmp_tailor", [{ role: "WORKER", departmentId: t.depts.SEWING }], { caller: admin.authId });
    const { lineId } = await releasedOrder("DEL", 2);
    const { lotId } = await cut(lineId, 2);
    const cp = await pool("CUTTING");
    await cutter.call("app_dispatch_batch", { p: { requestKey: key(), items: [{ lotId, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tmp.employeeId, quantity: 2 }] } });
    await rejects(del(tmp), "BUSINESS_RULE");                                       // sent to him, not yet received
    const [tr] = (await tmp.call("app_list_transfers", { p_tab: "incoming" })).rows;
    await accept(tmp, tr.id, 2);
    await rejects(del(tmp), "BUSINESS_RULE");                                       // 2 pieces in his custody
    await rejects(del(tmp, "wrong"), "INVALID");                                    // typed confirmation must match
    await rejects(t.callAs("service_role", null, "svc_delete_employee", { p_caller: tailorA.authId, p_employee: tmp.employeeId, p_confirm: "tmp_tailor" }), "FORBIDDEN");
    await rejects(t.callAs("service_role", null, "svc_delete_employee", { p_caller: admin.authId, p_employee: admin.employeeId, p_confirm: admin.username }), "BUSINESS_RULE");
    // pieces move on → the account can go; history keeps his name
    const own_ = await own("SEWING", tmp);
    await send(tmp, { lotId, fromCustodyId: own_, toDepartmentId: t.depts.FINISHING_1, quantity: 2 });
    const r = await del(tmp);
    assert.equal(r.auth_user_id, tmp.authId);
    await t.pool.query("DELETE FROM auth.users WHERE id = $1", [tmp.authId]);      // what the Edge Function does next (no FK left)
    await rejects(tmp.call("app_whoami"), "UNAUTHENTICATED");                      // existing sessions stop at once
    assert.equal((await admin.call("app_admin_view")).employees.some((e) => e.id === tmp.employeeId), false);
    const hist = await rev.call("app_get_order", { p_id: (await t.pool.query("SELECT ol.order_id FROM factory.order_lines ol WHERE ol.id = $1", [lineId])).rows[0].order_id });
    assert.equal(hist.lots.length, 1);
    const sent = (await fin1.call("app_list_transfers", { p_tab: "incoming" })).rows.find((x) => x.lot_code === tr.lot_code && x.from_label.includes("tmp_tailor"));
    assert.ok(sent, "the transfer still shows who sent it");
    // frozen: cannot be reactivated, given roles, or deleted twice; the username is free again
    await rejects(t.callAs("service_role", null, "svc_set_employee_active", { p_caller: admin.authId, p_employee: tmp.employeeId, p_active: true }), "NOT_FOUND");
    await rejects(admin.call("app_set_employee_roles", { p_employee: tmp.employeeId, p_roles: [{ role: "WORKER", departmentId: t.depts.SEWING }] }), "NOT_FOUND");
    await rejects(del(tmp), "NOT_FOUND");
    const again = await t.makeUser("tmp_tailor", [{ role: "WORKER", departmentId: t.depts.SEWING }], { caller: admin.authId });
    assert.notEqual(again.employeeId, tmp.employeeId);
    await balanced();
  });
});

describe("receiving a whole order at once", () => {
  it("receives all pending transfers in one step, only the addressee, all or nothing, idempotent", async () => {
    const { orderId } = await releasedOrder("BATCH", 1);
    const lines = (await sup.call("app_get_order", { p_id: orderId })).lines;
    const { lotId } = await cut(lines[0].id, 1);
    const cp = await pool("CUTTING");
    const { lineId: l2 } = await releasedOrder("BATCH2", 3);
    const { lotId: lot2 } = await cut(l2, 3);
    const r = await cutter.call("app_dispatch_batch", { p: { requestKey: key(), items: [
      { lotId, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, quantity: 1 },
      { lotId: lot2, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, quantity: 3 }] } });
    assert.equal(r.quantity, 4);
    const ids = (await tailorA.call("app_list_transfers", { p_tab: "incoming" })).rows.map((x) => x.id);
    await rejects(tailorB.call("app_receive_batch", { p: { requestKey: key(), transferIds: ids } }), "FORBIDDEN");   // not addressed to him
    assert.equal((await tailorA.call("app_list_transfers", { p_tab: "incoming" })).rows.length, ids.length);       // nothing half-received
    const k = key();
    const ok = await tailorA.call("app_receive_batch", { p: { requestKey: k, transferIds: ids } });
    assert.equal(ok.quantity >= 4, true);
    assert.equal((await tailorA.call("app_receive_batch", { p: { requestKey: k, transferIds: ids } })).replayed, true);
    assert.equal((await tailorA.call("app_list_transfers", { p_tab: "incoming" })).rows.length, 0);
    const where = (await sup.call("app_get_order", { p_id: orderId })).where;
    assert.deepEqual(where.map((w) => w.rank), [2]);                                                             // sewing
    await balanced();
  });
});

describe("route: next stage, or back one stage with a reason", () => {
  it("tailor returns to the cutter; no skipping, no same-stage moves; the admin can switch returns off", async () => {
    const { lineId } = await releasedOrder("ROUTE", 6);
    const { lotId } = await cut(lineId, 6);
    const cp = await pool("CUTTING");
    await accept(tailorA, (await send(cutter, { lotId, fromCustodyId: cp, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorA.employeeId, quantity: 6 })).transferId, 6);
    const ta = (await t.pool.query("SELECT id FROM factory.custodies WHERE kind='EMPLOYEE' AND employee_id=$1", [tailorA.employeeId])).rows[0].id;
    await rejects(send(tailorA, { lotId, fromCustodyId: ta, toDepartmentId: t.depts.SEWING, toEmployeeId: tailorB.employeeId, quantity: 1 }), "BUSINESS_RULE"); // same stage
    await rejects(send(tailorA, { lotId, fromCustodyId: ta, toDepartmentId: t.depts.CUTTING, quantity: 1 }), "BUSINESS_RULE");                               // no reason
    const back = await send(tailorA, { lotId, fromCustodyId: ta, toDepartmentId: t.depts.CUTTING, quantity: 1, reason: "قص غير مطابق" });
    assert.equal(back.direction, "RETURN");
    await admin.call("app_update_department", { p_id: t.depts.SEWING, p: { allowReturn: false } });
    await rejects(send(tailorA, { lotId, fromCustodyId: ta, toDepartmentId: t.depts.CUTTING, quantity: 1, reason: "x" }), "BUSINESS_RULE");
    assert.equal((await admin.call("app_admin_view")).departments.find((d) => d.id === t.depts.SEWING).allow_return, false);
    await rejects(sup.call("app_update_department", { p_id: t.depts.SEWING, p: { allowReturn: true } }), "FORBIDDEN");
    await admin.call("app_update_department", { p_id: t.depts.SEWING, p: { allowReturn: true } });
    const fwd = await send(tailorA, { lotId, fromCustodyId: ta, toDepartmentId: t.depts.FINISHING_1, quantity: 5 });
    assert.equal(fwd.direction, "FORWARD");
    await accept(fin1, fwd.transferId, 5);
    const f1 = await pool("FINISHING_1");
    await rejects(send(fin1, { lotId, fromCustodyId: f1, toDepartmentId: t.depts.CUTTING, quantity: 1, reason: "x" }), "BUSINESS_RULE"); // two stages back
    await balanced();
  });
});

describe("reports", () => {
  it("overdue only when the deadline passed and the order is incomplete", async () => {
    const late = await releasedOrder("LATE", 5, shift(-2));
    const ontime = await releasedOrder("ONTIME", 5, shift(3));
    const { orderId, lineId, orderCode: doneLate } = await releasedOrder("DONE-LATE", 2, shift(-1));
    const lot = (await cut(lineId, 2)).lotId;
    const wh = await pool("WAREHOUSE");
    await admin.call("app_create_adjustment", { p: { requestKey: key(), lotId: lot, custodyId: await pool("CUTTING"), condition: "GOOD", signedQty: -2, reason: "نقل اختباري" } });
    await admin.call("app_create_adjustment", { p: { requestKey: key(), lotId: lot, custodyId: wh, condition: "GOOD", signedQty: 2, reason: "نقل اختباري" } });
    await store.call("app_create_shipment", { p: { requestKey: key(), orderId, deliveredOn: today(), lines: [{ lotId: lot, custodyId: wh, quantity: 2 }] } });
    const rows = await sup.call("app_list_orders", { p_filter: "active", p_search: null });
    const by = Object.fromEntries(rows.map((o) => [o.order_code, o]));
    assert.equal(by[late.orderCode].overdue, true);
    assert.equal(by[late.orderCode].days_late, 2);
    assert.equal(by[ontime.orderCode].overdue, false);
    assert.equal(by[doneLate].overdue, false);
    await sup.call("app_close_order", { p_id: orderId });
    await balanced();
  });

  it("shared work is effort, not units; exports are audited", async () => {
    const { lineId } = await releasedOrder("PO-SHARED", 10);
    const { ids } = await sup.call("app_create_assignments", { p: { orderLineId: lineId, departmentId: t.depts.SEWING, employeeIds: [tailorA.employeeId, tailorB.employeeId], quantity: 10 } });
    await tailorA.call("app_update_assignment", { p_id: ids[0], p: { completedQty: 10, status: "DONE" } });
    await rejects(tailorA.call("app_update_assignment", { p_id: ids[1], p: { completedQty: 1, status: "IN_PROGRESS" } }), "FORBIDDEN");
    const c = await rev.call("app_report", { p_type: "contributions", p_params: { export: true } });
    assert.ok(c.find((r) => r.display_name === "tailora").shared_assignments >= 1);
    const audit = await t.pool.query("SELECT 1 FROM factory.audit_events WHERE action = 'report.export'");
    assert.equal(audit.rowCount, 1);
  });

  it("the administrator assigns and cancels tasks; a reviewer cannot assign", async () => {
    const { lineId } = await releasedOrder("PO-ADMIN-TASK", 5);
    const { ids } = await admin.call("app_create_assignments", { p: { orderLineId: lineId, departmentId: t.depts.SEWING, employeeIds: [tailorB.employeeId], quantity: 5 } });
    const view = await admin.call("app_work_view");
    assert.equal(view.assigner, true);
    assert.equal(view.can_cancel, true);
    assert.ok(view.open.some((w) => w.id === ids[0] && w.employee_id === tailorB.employeeId));
    assert.equal((await admin.call("app_admin_view")).employees.find((e) => e.id === tailorB.employeeId).open_tasks >= 1, true);
    await rejects(tailorB.call("app_update_assignment", { p_id: ids[0], p: { completedQty: 0, status: "CANCELLED" } }), "BUSINESS_RULE");
    await admin.call("app_update_assignment", { p_id: ids[0], p: { completedQty: 0, status: "CANCELLED" } });
    await rejects(rev.call("app_create_assignments", { p: { orderLineId: lineId, departmentId: t.depts.SEWING, employeeIds: [tailorB.employeeId], quantity: 1 } }), "FORBIDDEN");
  });

  it("every screen function answers for its role", async () => {
    await cutter.call("app_dashboard"); await tailorA.call("app_my_stock"); await tailorA.call("app_work_view");
    await tailorA.call("app_list_transfers", { p_tab: "incoming" }); await store.call("app_warehouse_view");
    await sup.call("app_list_defects", { p_all: true }); await admin.call("app_admin_view"); await admin.call("app_adjustments_view");
    for (const type of ["stages", "employees", "orders", "defects", "movements", "audit"]) await rev.call("app_report", { p_type: type, p_params: {} });
    await rejects(tailorA.call("app_warehouse_view"), "FORBIDDEN");
    await rejects(tailorA.call("app_list_transfers", { p_tab: "all" }), "FORBIDDEN");
  });
});
