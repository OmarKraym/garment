import { rpc } from "../api.js";
import { badge, details, empty, field, fmtDate, h, input, pageHead, routeRail, table, todayLocal } from "../dom.js";
import { actionButton, actionForm, int, optional } from "../forms.js";
import { ORDER_STATUS, STAGES } from "../labels.js";

const FILTERS = [["active", "النشطة"], ["overdue", "المتأخرة"], ["closed", "المغلقة"], ["all", "الكل"]];
const statusBadge = (s) => badge(ORDER_STATUS[s], s === "RELEASED" ? "primary" : s === "CLOSED" ? "ok" : "");
/** Delivered out of planned, as a thin bar (the one number a customer asks about). */
function progress(done, total) {
  const fill = h("span");
  fill.style.inlineSize = `${total ? Math.min(100, Math.round((done / total) * 100)) : 0}%`; // CSSOM: allowed under the strict CSP
  return h("div", { class: "progress", attrs: { role: "img", "aria-label": `سُلّم ${done} من ${total}` } }, fill);
}

export async function render(ctx) {
  const [, sub] = ctx.parts;
  if (sub === "new") return newOrder(ctx);
  if (sub) return orderDetail(ctx, sub);
  return list(ctx);
}

async function list({ me, query }) {
  const filter = FILTERS.some(([k]) => k === query.filter) ? query.filter : "active";
  const rows = await rpc("app_list_orders", { p_filter: filter, p_search: query.q ?? null });
  const search = h("input", { attrs: { name: "q", value: query.q ?? "", placeholder: "بحث برقم الطلبية أو الزبون أو المنتج", "aria-label": "بحث" } });
  const form = h("form", { class: "search-row mt", attrs: { role: "search" } }, search, h("button", { class: "btn-secondary", attrs: { type: "submit" }, text: "بحث" }));
  form.addEventListener("submit", (e) => { e.preventDefault(); location.hash = `#/orders?filter=${filter}&q=${encodeURIComponent(search.value)}`; });
  return h("div", {},
    pageHead("الطلبيات", null,
      me.roles.includes("SUPERVISOR") ? h("a", { class: "btn", attrs: { href: "#/orders/new" }, text: "+ طلبية جديدة" }) : null),
    h("nav", { class: "tabs", attrs: { "aria-label": "تصفية الطلبيات" } },
      FILTERS.map(([k, label]) => h("a", { attrs: { href: `#/orders?filter=${k}`, "aria-current": k === filter ? "page" : null }, text: label }))),
    form, h("div", { class: "mt" }),
    rows.length ? h("div", { class: "list" }, rows.map((r) => h("a", { class: `list-row order-row ${r.overdue ? "overdue" : ""}`, attrs: { href: `#/orders/${r.id}` } },
      h("div", { class: "order-row-main" },
        h("div", { class: "order-row-top" }, h("b", { class: "ltr", text: r.order_code }), statusBadge(r.status), r.overdue ? badge(`متأخرة ${r.days_late} يوم`, "danger") : null),
        h("div", { class: "small", text: `${r.customer_name} — ${r.product_name}` }),
        progress(r.delivered_qty, r.planned_qty),
        h("div", { class: "order-row-meta small muted" },
          h("span", {}, "سُلّم ", h("b", { class: "num", text: r.delivered_qty }), " من ", h("span", { class: "num", text: r.planned_qty })),
          h("span", {}, "في الإنتاج ", h("b", { class: "num", text: r.in_production_qty })),
          h("span", {}, "التسليم ", h("span", { class: "num", text: r.due_date }))))))) : empty("لا توجد طلبيات"));
}

const splitList = (v) => [...new Set(String(v ?? "").split(/[,،\n]+/).map((x) => x.trim()).filter(Boolean))];

/** Colours × sizes grid: the supervisor types the colours and sizes once, then a quantity per cell. */
function quantityGrid() {
  const colors = input({ name: "colors", required: true, placeholder: "مثال: أبيض، أزرق، أسود", maxlength: 600 });
  const sizes = input({ name: "sizes", required: true, placeholder: "مثال: S، M، L، XL", maxlength: 300, class: "ltr" });
  const grid = h("div", { class: "mt" });
  const total = h("b", { class: "num", text: "0" });
  const draw = () => {
    const cs = splitList(colors.value), ss = splitList(sizes.value);
    const old = Object.fromEntries([...grid.querySelectorAll("input")].map((x) => [x.name, x.value]));
    if (!cs.length || !ss.length) { grid.replaceChildren(h("p", { class: "small muted", text: "اكتب الألوان والمقاسات لتظهر خانات الكميات." })); recount(); return; }
    grid.replaceChildren(h("div", { class: "table-wrap" }, h("table", { class: "qty-grid" },
      h("thead", {}, h("tr", {}, h("th", { text: "اللون \\ المقاس" }), ss.map((z) => h("th", { class: "num ltr", text: z })))),
      h("tbody", {}, cs.map((c, i) => h("tr", {}, h("th", { text: c }), ss.map((z, j) => {
        const name = `q_${i}_${j}`;
        return h("td", {}, input({ name, type: "number", inputmode: "numeric", min: 0, step: 1, class: "qty-input",
          value: old[name] ?? "", "aria-label": `${c} — ${z}`, "data-color": c, "data-size": z }));
      })))))));
    recount();
  };
  const recount = () => { total.textContent = [...grid.querySelectorAll("input")].reduce((s, x) => s + (int(x.value) || 0), 0); };
  colors.addEventListener("change", draw); sizes.addEventListener("change", draw);
  colors.addEventListener("blur", draw); sizes.addEventListener("blur", draw);
  grid.addEventListener("input", recount);
  const fill = h("button", { class: "btn-ghost btn-sm", attrs: { type: "button" }, text: "نفس الكمية لكل الخانات", onclick: () => {
    const first = [...grid.querySelectorAll("input")].find((x) => int(x.value) > 0);
    if (first) grid.querySelectorAll("input").forEach((x) => { x.value = first.value; });
    recount();
  } });
  draw();
  const read = (form) => [...form.querySelectorAll(".qty-grid input")]
    .map((x) => ({ color: x.dataset.color, size: x.dataset.size, plannedQty: int(x.value) || 0 })).filter((l) => l.plannedQty > 0);
  return { node: h("fieldset", {}, h("legend", { text: "الألوان والمقاسات والكميات" }),
    h("div", { class: "grid grid-2" }, field("الألوان (افصل بينها بفاصلة)", colors), field("المقاسات (افصل بينها بفاصلة)", sizes)),
    grid, h("div", { class: "row small mt" }, h("span", {}, "إجمالي القطع: ", total), fill)), read };
}

function newOrder({ me, navigate }) {
  if (!me.roles.includes("SUPERVISOR")) throw Object.assign(new Error("إنشاء الطلبيات من صلاحية المشرف"), { code: "FORBIDDEN" });
  const q = quantityGrid();
  let send = true;
  // Enter or the main button = save AND send to cutting; this button = save as draft.
  const draftBtn = h("button", { class: "btn-secondary", attrs: { type: "button" }, text: "حفظ كمسودة",
    onclick: () => { send = false; draftBtn.closest("form").requestSubmit(); } });
  const form = actionForm({
    submit: "حفظ وإرسال للقص",
    children: [
      h("p", { class: "small muted", text: "رقم الطلبية يُنشأ تلقائياً." }),
      h("div", { class: "grid grid-2" },
        field("الزبون", input({ name: "customerName", required: true, maxlength: 150 })),
        field("تاريخ التسليم المطلوب", input({ name: "dueDate", type: "date", required: true, min: todayLocal() })),
        field("المنتج", input({ name: "productName", required: true, maxlength: 150 })),
        field("رمز الموديل (اختياري)", input({ name: "modelCode", maxlength: 60 })),
        field("تواصل الزبون (اختياري)", input({ name: "customerContact", maxlength: 200 }))),
      q.node,
      field("ملاحظات للقصاص (اختياري)", h("textarea", { attrs: { name: "notes", maxlength: 2000 } })),
      draftBtn,
    ],
    run: async (data, _op, formEl) => {
      const toCutting = send;
      send = true;
      const lines = q.read(formEl);
      if (!lines.length) throw new Error("اكتب كمية لخانة واحدة على الأقل");
      const res = await rpc("app_create_order", { p: {
        customerName: data.customerName, customerContact: optional(data.customerContact), productName: data.productName,
        modelCode: optional(data.modelCode), dueDate: data.dueDate, notes: optional(data.notes), lines, send: toCutting } });
      navigate(`#/orders/${res.id}`);
      return res.sent ? `تم إنشاء الطلبية ${res.orderCode} وإرسالها للقص` : `تم حفظ الطلبية ${res.orderCode} كمسودة`;
    },
  });
  form.classList.add("card");
  return h("div", {}, pageHead("طلبية جديدة", "حدّد الألوان والمقاسات والكميات، ثم أرسلها للقصاص."), form);
}

/** Quantities editor (supervisor): colours/sizes stay fixed, never below what is cut. */
function quantitiesForm(o) {
  return details("تعديل الكميات", actionForm({
    submit: "حفظ الكميات",
    children: [h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["اللون / المقاس", "المطلوب", "مقصوص"].map((t, i) => h("th", { class: i ? "num" : "", text: t })))),
      h("tbody", {}, o.lines.map((l) => h("tr", {}, h("td", { text: `${l.color} / ${l.size}` }),
        h("td", { class: "num" }, input({ name: `plan_${l.id}`, type: "number", inputmode: "numeric", min: Math.max(1, l.cut_qty), step: 1, value: l.planned_qty, class: "qty-input", "aria-label": `${l.color} / ${l.size}` })),
        h("td", { class: "num", text: l.cut_qty }))))))],
    run: async (d) => {
      const lines = o.lines.filter((l) => int(d[`plan_${l.id}`]) !== l.planned_qty).map((l) => ({ lineId: l.id, plannedQty: int(d[`plan_${l.id}`]) }));
      if (!lines.length) throw new Error("لم تتغير أي كمية");
      await rpc("app_set_line_quantities", { p_order: o.id, p: { lines } });
      return "تم تعديل الكميات";
    },
  }));
}

async function orderDetail({ me }, id) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("الطلب غير موجود");
  const o = await rpc("app_get_order", { p_id: id });
  const viewAll = me.roles.some((r) => ["ADMIN", "SUPERVISOR", "REVIEWER"].includes(r));
  const actions = [];
  if (o.can_manage && o.status === "DRAFT") {
    actions.push(actionButton("إرسال للقص", { confirm: "إرسال الطلبية للقصاص؟ بعد الإرسال تُعدَّل الكميات فقط.", run: async () => { await rpc("app_release_order", { p_id: id }); return "تم إرسال الطلبية للقص"; } }));
    actions.push(actionButton("إلغاء المسودة", { cls: "btn-ghost", confirm: "إلغاء هذه المسودة؟", run: async () => { await rpc("app_cancel_order", { p_id: id }); return "تم إلغاء الطلبية"; } }));
  }
  if (o.can_delete) {
    actions.push(actionButton("حذف الطلبية", {
      cls: "btn-danger-quiet",
      confirm: `حذف الطلبية ${o.order_code} نهائياً؟ ستختفي من كل القوائم ولا يمكن التراجع.`,
      run: async () => {
        await rpc("app_delete_order", { p_id: id });
        location.hash = "#/orders";
        return `تم حذف الطلبية ${o.order_code}`;
      },
    }));
  }
  if (o.can_manage && o.status === "RELEASED") {
    actions.push(actionButton("إغلاق الطلبية", { cls: "btn-secondary", confirm: "إغلاق الطلبية؟ يُسمح فقط إذا لم تبقَ منها قطع في الإنتاج أو المخزن.", run: async () => { await rpc("app_close_order", { p_id: id }); return "تم إغلاق الطلبية"; } }));
  }
  // where the pieces are, on the route (rank 1..6); transit / dispute have no stage
  const counts = {}; let between = 0;
  for (const w of o.where) { if (STAGES[w.rank - 1]) counts[STAGES[w.rank - 1]] = (counts[STAGES[w.rank - 1]] ?? 0) + w.qty; else between += w.qty; }
  const fact = (label, v, tone) => h("div", { class: `fact ${tone ?? ""}` }, h("dt", { text: label }), h("dd", { class: "num", text: v }));
  const optionalSection = (title, rows, cols) => (rows.length ? h("section", { class: "block" }, h("h2", { text: title }), table(cols, rows)) : null);
  return h("div", {},
    pageHead(`الطلبية ${o.order_code}`, `${o.customer_name} — ${o.product_name}${o.model_code ? ` (${o.model_code})` : ""}`),
    h("div", { class: "row order-badges" }, statusBadge(o.status), o.overdue ? badge(`متأخرة ${o.days_late} يوم`, "danger") : null,
      h("span", { class: "small muted" }, "التسليم ", h("b", { class: "num", text: o.due_date }))),
    h("section", { class: "card order-summary" },
      h("div", { class: "order-progress" },
        h("div", {}, h("span", { class: "big-num num", text: o.delivered_qty }), h("span", { class: "muted" }, " / ", h("span", { class: "num", text: o.planned_qty }), " قطعة سُلّمت")),
        progress(o.delivered_qty, o.planned_qty)),
      routeRail(null, counts),
      between ? h("p", { class: "small muted route-note" }, "بين قسمين (لم تُستلم بعد) ", h("b", { class: "num", text: between })) : null,
      h("dl", { class: "facts" },
        fact("المطلوب", o.planned_qty), fact("مقصوص", o.cut_qty), fact("في الإنتاج", o.in_production_qty),
        fact("في المخزن", o.in_warehouse_qty), fact("المتبقي", o.remaining_qty, o.overdue ? "danger" : ""), fact("متلف", o.scrapped_qty, o.scrapped_qty ? "danger" : ""))),
    o.notes ? h("p", { class: "note-box", text: o.notes }) : null,
    h("section", { class: "block" }, h("h2", { text: "الألوان والمقاسات" }),
      table([
        { label: "اللون / المقاس", cell: (l) => h("span", {}, `${l.color} / ${l.size}`, l.defective_qty ? h("span", { class: "badge danger sm", text: `معيب ${l.defective_qty}` }) : null) },
        { label: "المطلوب", num: true, cell: (l) => l.planned_qty },
        { label: "مقصوص", num: true, cell: (l) => l.cut_qty + l.replacement_cut_qty },
        { label: "مسلَّم", num: true, cell: (l) => h("b", { text: l.delivered_qty }) },
      ], o.lines),
      o.can_manage && ["DRAFT", "RELEASED"].includes(o.status) ? h("div", { class: "mt" }, quantitiesForm(o)) : null),
    optionalSection("دفعات القص", o.lots, [
      { label: "اللون / المقاس", cell: (l) => h("span", {}, `${l.color} / ${l.size}`, l.is_replacement ? h("span", { class: "badge warn sm", text: "بديل" }) : null) },
      { label: "الكمية", num: true, cell: (l) => l.created_qty }, { label: "بواسطة", cell: (l) => l.created_by_name }]),
    optionalSection("التسليمات للزبون", o.shipments, [
      { label: "التاريخ", num: true, cell: (s) => s.delivered_on }, { label: "الكمية", num: true, cell: (s) => s.quantity },
      { label: "بواسطة", cell: (s) => s.created_by_name }]),
    h("p", { class: "small muted meta-line", text: `أنشأها ${o.created_by_name} ${fmtDate(o.created_at)}${o.released_at ? ` · أُرسلت للقص ${fmtDate(o.released_at)}` : ""}` }),
    viewAll ? h("p", { class: "small" }, h("a", { attrs: { href: `#/reports?tab=movements&orderId=${o.id}` }, text: "سجل حركات هذه الطلبية" })) : null,
    actions.length ? h("div", { class: "row page-actions" }, actions) : null);
}
