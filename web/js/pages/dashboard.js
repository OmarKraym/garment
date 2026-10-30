// «المتابعة» — answers three questions in order: what needs me now, where are the pieces, how is today going.
import { rpc } from "../api.js";
import { badge, h, pageHead, routeRail } from "../dom.js";
import { STAGES } from "../labels.js";

const fmt = (n) => Number(n ?? 0).toLocaleString("en-US");

/** A row in the "needs attention" list: only rendered when count > 0. */
const attention = (count, text, href, tone = "warn") => (count ? h("a", { class: `attn ${tone}`, attrs: { href } },
  h("span", { class: "attn-count num", text: fmt(count) }), h("span", { class: "attn-text", text }), h("span", { class: "attn-go", attrs: { "aria-hidden": "true" } })) : null);

const stat = (value, label, href) => h(href ? "a" : "div", { class: "stat", attrs: href ? { href } : {} },
  h("span", { class: "stat-value num", text: fmt(value) }), h("span", { class: "stat-label", text: label }));

export async function render({ me }) {
  const d = await rpc("app_dashboard");
  const m = d.mine;
  const f = d.factory;
  const out = [pageHead(`مرحباً، ${me.display_name}`)];

  if (m.has_custody) {
    const items = [
      attention(m.incoming, "تحويلات وصلتك وتنتظر الاستلام", "#/tasks"),
      attention(m.defective, "قطع معيبة في عهدتك", "#/tasks", "danger"),
    ].filter(Boolean);
    out.push(h("section", { class: "block" }, h("h2", { text: "عملي" }),
      h("div", { class: "stats" }, stat(m.good, "قطعة سليمة عندك", "#/tasks"), stat(m.open_work, "تكليف مفتوح", "#/tasks"), stat(m.incoming, "بانتظار استلامك", "#/tasks")),
      items.length ? h("div", { class: "attn-list" }, items) : null));
  }

  if (f) {
    const items = [
      attention(f.overdue.length, "طلبيات تجاوزت موعد التسليم", "#/orders?filter=overdue", "danger"),
      attention(f.disputed_units, "قطع عليها خلاف بين قسمين", "#/transfers?tab=disputes", "danger"),
      attention(f.open_defects, "عيوب تنتظر قراراً", "#/quality"),
      attention(f.stale_transfers, "تحويلات لم تُستلم منذ أكثر من يوم", "#/transfers?tab=all"),
    ].filter(Boolean);
    out.push(h("section", { class: "block" }, h("h2", { text: "يحتاج انتباهك" }),
      items.length ? h("div", { class: "attn-list" }, items) : h("p", { class: "all-clear", text: "لا شيء متأخر أو عالق. العمل يسير." })));

    // pieces per stage: ranks "01".."06" are the route; transit / dispute have no stage
    const counts = {}; let transit = 0, defective = 0;
    for (const s of f.stages) {
      const i = Number.parseInt(s.rank, 10) - 1;
      defective += s.defective;
      if (STAGES[i]) counts[STAGES[i]] = (counts[STAGES[i]] ?? 0) + s.good + s.defective;
      else transit += s.good + s.defective;
    }
    out.push(h("section", { class: "block" }, h("h2", {}, "أين القطع الآن ", h("span", { class: "h-note num", text: `${fmt(f.units_on_hand)} قطعة` })),
      h("div", { class: "card m0 route-card" }, routeRail(null, counts),
        transit || defective ? h("div", { class: "route-foot" },
          transit ? h("span", {}, "بين قسمين (لم تُستلم بعد) ", h("b", { class: "num", text: fmt(transit) })) : null,
          defective ? h("span", {}, "منها معيب ", h("b", { class: "num", text: fmt(defective) })) : null) : null)));

    out.push(h("section", { class: "block" }, h("h2", { text: "اليوم" }),
      h("div", { class: "stats" }, stat(f.active_orders, "طلبية قيد الإنتاج", "#/orders"), stat(f.pending_transfers, "تحويل بانتظار الاستلام", "#/transfers?tab=all"), stat(f.delivered_today, "قطعة سُلّمت اليوم", "#/warehouse"))));

    if (f.overdue.length) {
      out.push(h("section", { class: "block" }, h("h2", { text: "الطلبيات المتأخرة" }),
        h("div", { class: "list" }, f.overdue.map((r) => h("a", { class: "list-row overdue", attrs: { href: `#/orders/${r.id}` } },
          h("div", {}, h("div", { class: "ltr list-title", text: r.order_code }), h("div", { class: "small muted" }, "التسليم ", h("span", { class: "num", text: r.due_date }), ` · متبقٍ ${fmt(r.remaining_qty)} قطعة`)),
          badge(`متأخرة ${r.days_late} يوم`, "danger"))))));
    }
  }
  if (!m.has_custody && !f) out.push(h("div", { class: "empty-state" }, h("div", { class: "empty-mark", attrs: { "aria-hidden": "true" } }), h("h2", { text: "لم تُضف إلى أي قسم بعد" }), h("p", { text: "تواصل مع مدير النظام." })));
  return h("div", {}, out);
}
