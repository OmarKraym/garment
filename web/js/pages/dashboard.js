import { rpc } from "../api.js";
import { badge, empty, h, pageHead, table } from "../dom.js";

const tile = (label, value, href, tone) =>
  h(href ? "a" : "div", { class: `tile ${tone ?? ""}`, attrs: href ? { href } : {} },
    h("div", { class: "label", text: label }), h("div", { class: "value", text: value ?? 0 }));

export async function render({ me }) {
  const d = await rpc("app_dashboard");
  const m = d.mine;
  const out = [pageHead(`مرحباً، ${me.display_name}`, "ملخص العمل الحالي")];
  if (m.has_custody) {
    out.push(h("div", { class: "tiles" },
      tile("بانتظار استلامك", m.incoming, "#/transfers", m.incoming ? "warn" : ""),
      tile("قطع سليمة في عهدتك", m.good, "#/tasks"),
      tile("قطع معيبة في عهدتك", m.defective, "#/tasks", m.defective ? "danger" : ""),
      tile("تكليفاتي المفتوحة", m.open_work, "#/tasks")));
  }
  const f = d.factory;
  if (f) {
    out.push(h("div", { class: "tiles" },
      tile("طلبات نشطة", f.active_orders, "#/orders"),
      tile("طلبات متأخرة", f.overdue.length, "#/orders?filter=overdue", f.overdue.length ? "danger" : ""),
      tile("تحويلات بانتظار الاستلام", f.pending_transfers, "#/transfers?tab=all"),
      tile("قطع عليها خلاف", f.disputed_units, "#/transfers?tab=disputes", f.disputed_units ? "danger" : ""),
      tile("عيوب مفتوحة", f.open_defects, "#/quality", f.open_defects ? "warn" : ""),
      tile("إجمالي القطع في المصنع", f.units_on_hand),
      tile("سُلّم اليوم", f.delivered_today),
      tile("تحويلات مفتوحة أكثر من 24 ساعة", f.stale_transfers, null, f.stale_transfers ? "warn" : "")));
    out.push(h("div", { class: "grid grid-2" },
      h("section", { class: "card" }, h("h2", { text: "توزيع القطع على المراحل" }),
        f.stages.length ? table([
          { label: "المرحلة", cell: (r) => r.label },
          { label: "سليم", num: true, cell: (r) => r.good },
          { label: "معيب", num: true, cell: (r) => r.defective },
        ], f.stages) : empty("لا توجد قطع في الإنتاج حالياً")),
      h("section", { class: "card" }, h("h2", { text: "الطلبات المتأخرة" }),
        f.overdue.length ? table([
          { label: "الطلب", cell: (r) => h("a", { attrs: { href: `#/orders/${r.id}` }, text: r.order_code }) },
          { label: "التسليم", num: true, cell: (r) => h("span", {}, r.due_date, " ", badge(`${r.days_late} يوم`, "danger")) },
          { label: "المتبقي", num: true, cell: (r) => r.remaining_qty },
        ], f.overdue, () => "overdue") : empty("لا توجد طلبات متأخرة"))));
  }
  if (!m.has_custody && !f) out.push(h("div", { class: "card" }, h("p", { class: "muted", text: "لم تُسند إليك أقسام بعد. تواصل مع مدير النظام." })));
  return h("div", {}, out);
}
