import { rpc } from "../api.js";
import { badge, details, empty, field, h, input, pageHead, table } from "../dom.js";
import { actionForm, int, optional } from "../forms.js";

function shipForm(orderId, lines, today) {
  return details("تسليم للزبون", actionForm({
    submit: "تسليم",
    confirm: (d) => `تأكيد تسليم ${lines.reduce((s, _l, i) => s + (int(d[`q${i}`]) || 0), 0)} قطعة للزبون؟ هذه العملية تُخرج القطع من المخزن.`,
    children: [
      ...lines.map((l, i) => h("div", { class: "row" },
        h("span", { class: "grow" }, `${l.color} / ${l.size} — ${l.lot_code} `, h("span", { class: "muted small", text: `(المتاح ${l.qty})` })),
        input({ name: `q${i}`, type: "number", inputmode: "numeric", min: 0, max: l.qty, placeholder: "0", class: "qty-input", "aria-label": `كمية ${l.color} / ${l.size} — ${l.lot_code}` }))),
      h("div", { class: "inline-fields" },
        field("تاريخ التسليم", input({ name: "date", type: "date", value: today, max: today, required: true })),
        field("ملاحظة", input({ name: "notes", maxlength: 500 }))),
    ],
    run: async (d, op) => {
      const chosen = lines.map((l, i) => ({ lotId: l.lot_id, custodyId: l.custody_id, quantity: int(d[`q${i}`]) || 0 })).filter((x) => x.quantity > 0);
      if (!chosen.length) throw new Error("أدخل كمية للتسليم");
      const r = await op.run("app_create_shipment", (requestKey) => ({ p: { requestKey, orderId, deliveredOn: d.date, notes: optional(d.notes), lines: chosen } }));
      return `تم التسليم ${r.shipmentCode} (${r.quantity} قطعة)`;
    },
  }));
}

export async function render() {
  const v = await rpc("app_warehouse_view");
  const byOrder = new Map();
  for (const l of v.lines) byOrder.set(l.order_id, [...(byOrder.get(l.order_id) ?? []), l]);
  return h("div", {},
    pageHead("المخزن والتسليم", "يُسلَّم للزبون فقط ما استُلم في المخزن بحالة سليمة، ولا يتجاوز المتبقي من الطلب."),
    byOrder.size ? h("div", { class: "stack" }, [...byOrder.entries()].map(([orderId, lines]) => {
      const o = v.orders.find((x) => x.id === orderId);
      const good = lines.filter((l) => l.condition === "GOOD");
      return h("section", { class: "card m0 wh-order", dataset: { order: lines[0].order_code } },
        h("div", { class: "card-row" },
          h("div", {}, h("a", { attrs: { href: `#/orders/${orderId}` } }, h("b", { text: lines[0].order_code })), ` — ${lines[0].product_name}`,
            o ? h("div", { class: "small muted" }, "المتبقي للتسليم: ", h("b", { class: "num", text: o.remaining_qty }), " · التسليم ", h("span", { class: "num", text: o.due_date })) : null),
          o?.overdue ? badge(`متأخر ${o.days_late} يوم`, "danger") : null),
        h("div", { class: "mt" }, table([
          { label: "الكمية", num: true, cell: (l) => h("b", { text: l.qty }) },
          { label: "الحالة", cell: (l) => badge(l.condition === "GOOD" ? "سليم" : "معيب", l.condition === "GOOD" ? "ok" : "danger") },
          { label: "اللون/المقاس", cell: (l) => `${l.color} / ${l.size}` },
          { label: "الدفعة", cls: "ltr small", cell: (l) => l.lot_code },
        ], lines)),
        v.can_ship && good.length && o ? shipForm(orderId, good, v.today) : null);
    })) : empty("لا توجد قطع في المخزن حالياً"),
    h("section", { class: "card mt" }, h("h2", { text: "آخر التسليمات" }),
      v.shipments.length ? table([
        { label: "رقم التسليم", cls: "ltr small", cell: (s) => s.shipment_code }, { label: "الطلب", cell: (s) => s.order_code },
        { label: "الزبون", cell: (s) => s.customer_name }, { label: "التاريخ", num: true, cell: (s) => s.delivered_on },
        { label: "الكمية", num: true, cell: (s) => s.quantity }, { label: "بواسطة", cell: (s) => s.created_by_name },
      ], v.shipments) : empty("لا توجد تسليمات بعد")));
}
