import { rpc } from "../api.js";
import { alertBox, badge, empty, field, fmtDate, h, input, pageHead, select, table } from "../dom.js";
import { downloadCsv } from "../csv.js";
import { DEFECT_REASONS, EVENT, ORDER_STATUS } from "../labels.js";

const col = (header, value, num = false) => ({ header, value, num });
const REPORTS = {
  stages: { title: "المخزون حسب المرحلة", cols: [col("المكان", (r) => r.label), col("سليم", (r) => r.good, true), col("معيب", (r) => r.defective, true)] },
  employees: { title: "عهدة العمال", cols: [col("الموظف", (r) => r.display_name), col("القسم", (r) => r.department), col("سليم", (r) => r.good, true), col("معيب", (r) => r.defective, true)] },
  orders: { title: "الطلبات", cols: [col("الطلب", (r) => r.order_code), col("الزبون", (r) => r.customer_name), col("المنتج", (r) => r.product_name),
    col("التسليم", (r) => r.due_date), col("الحالة", (r) => ORDER_STATUS[r.status] ?? r.status), col("المخطط", (r) => r.planned_qty, true),
    col("المقصوص", (r) => r.cut_qty, true), col("في الإنتاج", (r) => r.in_production_qty, true), col("في المخزن", (r) => r.in_warehouse_qty, true),
    col("المسلّم", (r) => r.delivered_qty, true), col("المتلف", (r) => r.scrapped_qty, true), col("المتبقي", (r) => r.remaining_qty, true),
    col("أيام التأخير", (r) => (r.overdue ? r.days_late : 0), true)] },
  reconciliation: { title: "مطابقة الكميات", cols: [col("الطلب", (r) => r.order_code), col("الدفعة", (r) => r.lot_code), col("اللون", (r) => r.color), col("المقاس", (r) => r.size),
    col("مقصوص", (r) => r.cut_qty, true), col("تصحيح +", (r) => r.adjust_in, true), col("تصحيح −", (r) => r.adjust_out, true), col("مسلّم", (r) => r.delivered, true),
    col("متلف", (r) => r.scrapped, true), col("المتوقع", (r) => r.expected, true), col("الموجود", (r) => r.on_hand, true), col("قيد النقل/الخلاف", (r) => r.in_transit, true),
    col("مطابق", (r) => (r.balanced ? "نعم" : "لا"))] },
  defects: { title: "العيوب", cols: [col("السبب", (r) => DEFECT_REASONS[r.reason_code] ?? r.reason_code), col("قسم الاكتشاف", (r) => r.department),
    col("الكمية", (r) => r.quantity, true), col("مُصلح", (r) => r.repaired, true), col("متلف", (r) => r.scrapped, true), col("مفتوح", (r) => r.open, true)] },
  contributions: { title: "مساهمات العمال", cols: [col("الموظف", (r) => r.display_name), col("القسم", (r) => r.department), col("المهام", (r) => r.assignments, true),
    col("العمل المنجز", (r) => r.completed_work, true), col("مهام مشتركة", (r) => r.shared_assignments, true), col("حركات مخزون", (r) => r.ledger_actions, true)] },
  movements: { title: "حركات المخزون", paged: true, cols: [col("الوقت", (r) => fmtDate(r.created_at)), col("الحركة", (r) => EVENT[r.kind] ?? r.kind),
    col("الكمية", (r) => r.qty, true), col("الطلب", (r) => r.order_code), col("اللون/المقاس", (r) => `${r.color} / ${r.size}`), col("الدفعة", (r) => r.lot_code),
    col("القسم", (r) => r.department ?? ""), col("بواسطة", (r) => r.actor_name), col("المرجع", (r) => r.reference ?? ""), col("السبب", (r) => DEFECT_REASONS[r.reason] ?? r.reason ?? "")] },
  audit: { title: "سجل التدقيق", paged: true, cols: [col("الوقت", (r) => fmtDate(r.occurred_at)), col("بواسطة", (r) => r.actor_name ?? "النظام"),
    col("العملية", (r) => r.action), col("الهدف", (r) => `${r.target_type} ${r.target_id ?? ""}`), col("التفاصيل", (r) => (r.metadata ? JSON.stringify(r.metadata) : ""))] },
};

function paramsFrom(query) {
  const p = { page: Math.max(1, Number.parseInt(query.page ?? "1", 10) || 1) };
  for (const k of ["filter", "from", "to", "kind", "orderId"]) if (query[k]) p[k] = query[k];
  return p;
}

const toHash = (type, p) => `#/reports?${new URLSearchParams({ type, ...p }).toString()}`;

function filters(type, p, navigate) {
  if (type === "orders") {
    return h("div", { class: "row" }, ["active", "overdue", "all"].map((f) => h("a", {
      class: `btn btn-sm ${(p.filter ?? "active") === f ? "" : "btn-ghost"}`, attrs: { href: toHash(type, { filter: f }) },
      text: { active: "المفتوحة", overdue: "المتأخرة", all: "الكل" }[f] })));
  }
  if (type !== "movements") return null;
  const form = h("form", { class: "inline-fields" },
    field("من", input({ name: "from", type: "date", value: p.from ?? "" })),
    field("إلى", input({ name: "to", type: "date", value: p.to ?? "" })),
    field("نوع الحركة", select("kind", [{ value: "", label: "الكل" }, ...Object.entries(EVENT).map(([value, label]) => ({ value, label }))], p.kind ?? "")),
    h("button", { attrs: { type: "submit" }, text: "تصفية" }));
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const d = Object.fromEntries([...new FormData(form).entries()].filter(([, v]) => v));
    navigate(toHash(type, { ...d, ...(p.orderId ? { orderId: p.orderId } : {}) }));
  });
  return form;
}

function exportButton(type, def, p) {
  const msg = h("span", {});
  const b = h("button", { class: "btn-ghost", attrs: { type: "button" }, text: "تصدير CSV" });
  b.addEventListener("click", async () => {
    b.disabled = true;
    try {
      const data = await rpc("app_report", { p_type: type, p_params: { ...p, export: true } }); // export is audited server-side
      downloadCsv(`report-${type}`, def.cols, type === "reconciliation" ? data.lots : data);
    } catch (e) { msg.replaceChildren(alertBox("error", e.message)); } finally { b.disabled = false; }
  });
  return h("span", { class: "row" }, b, msg);
}

function view(def, rows) {
  if (!rows.length) return empty("لا توجد بيانات");
  return table(def.cols.map((c) => ({ label: c.header, num: c.num, cell: c.value })), rows);
}

export async function render({ query, navigate }) {
  const type = REPORTS[query.type] ? query.type : "stages";
  const def = REPORTS[type];
  const p = paramsFrom(query);
  const data = await rpc("app_report", { p_type: type, p_params: p });
  const tabs = h("nav", { class: "tabs", attrs: { "aria-label": "التقارير" } }, Object.entries(REPORTS).map(([k, r]) =>
    h("a", { class: k === type ? "active" : "", attrs: { href: `#/reports?type=${k}`, "aria-current": k === type ? "page" : null }, text: r.title })));
  let body;
  if (type === "reconciliation") {
    const t = data.totals;
    body = h("div", {},
      data.all_balanced ? alertBox("success", "كل الكميات متطابقة: المقصوص + التصحيحات = الموجود + المسلّم + المتلف، والسجل يطابق الأرصدة.")
        : alertBox("error", `يوجد عدم تطابق: ${data.projection_mismatches} رصيد لا يطابق السجل، ${data.transfer_mismatches} تحويل لا يطابق عهدته، ${data.negative_balances} رصيد سالب.`),
      h("div", { class: "qtys mt" }, [["مقصوص", t.cut], ["تصحيح +", t.adjust_in], ["تصحيح −", t.adjust_out], ["مسلّم", t.delivered],
        ["متلف", t.scrapped], ["موجود", t.on_hand], ["قيد النقل/الخلاف", t.in_transit]].map(([l, v]) =>
        h("span", { class: "qty-chip" }, `${l} `, h("b", { class: "num", text: v })))),
      h("div", { class: "mt" }, data.lots.length ? table(def.cols.map((c) => ({ label: c.header, num: c.num,
        cell: c.header === "مطابق" ? (r) => badge(r.balanced ? "مطابق" : "غير مطابق", r.balanced ? "ok" : "danger") : c.value })),
        data.lots, (r) => (r.balanced ? "" : "edge-danger")) : empty("لا توجد دفعات")));
  } else {
    body = view(def, data);
  }
  const { type: _t, ...rest } = query;
  const pager = def.paged ? h("div", { class: "row mt" },
    p.page > 1 ? h("a", { class: "btn btn-ghost btn-sm", attrs: { href: toHash(type, { ...rest, page: p.page - 1 }) }, text: "السابق" }) : null,
    h("span", { class: "muted small", text: `صفحة ${p.page}` }),
    data.length === 100 ? h("a", { class: "btn btn-ghost btn-sm", attrs: { href: toHash(type, { ...rest, page: p.page + 1 }) }, text: "التالي" }) : null) : null;
  return h("div", {},
    pageHead("التقارير", "تُحسب من سجل المخزون مباشرة. التصدير يُسجَّل في سجل التدقيق.", exportButton(type, def, p)),
    tabs,
    h("section", { class: "card" }, h("h2", { text: def.title }), filters(type, p, navigate), h("div", { class: "mt" }, body), pager));
}
