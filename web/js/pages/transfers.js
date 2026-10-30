import { rpc } from "../api.js";
import { badge, details, empty, field, fmtDate, h, input, pageHead } from "../dom.js";
import { actionButton, actionForm, int } from "../forms.js";
import { CONDITION_LABEL, DIRECTION, TRANSFER_STATE } from "../labels.js";

const TABS = [["incoming", "بانتظار استلامي"], ["disputes", "الخلافات"], ["outgoing", "أرسلتُها"], ["all", "كل التحويلات المفتوحة"]];

function receiveControls(t) {
  const all = actionButton(`استلام الكل (${t.pending_qty})`, {
    run: async (op) => {
      await op.run("app_receive", (requestKey) => ({ p_id: t.id, p: { requestKey, acceptQty: t.pending_qty, disputeQty: 0, rejectQty: 0 } }));
      return `تم استلام ${t.pending_qty} قطعة`;
    },
  });
  const partial = actionForm({
    submit: "تأكيد",
    children: [
      h("div", { class: "inline-fields" },
        field("مستلم فعلاً", input({ name: "accept", type: "number", inputmode: "numeric", min: 0, max: t.pending_qty, value: t.pending_qty })),
        field("ناقص / مختلف عليه", input({ name: "dispute", type: "number", inputmode: "numeric", min: 0, max: t.pending_qty, value: 0 })),
        field("مرفوض (يعود للمرسل)", input({ name: "reject", type: "number", inputmode: "numeric", min: 0, max: t.pending_qty, value: 0 }))),
      field("السبب (إلزامي عند وجود فرق)", input({ name: "reason", maxlength: 1000 })),
    ],
    run: async (d, op) => {
      const acceptQty = int(d.accept) || 0, disputeQty = int(d.dispute) || 0, rejectQty = int(d.reject) || 0;
      await op.run("app_receive", (requestKey) => ({ p_id: t.id, p: { requestKey, acceptQty, disputeQty, rejectQty, reason: d.reason?.trim() || null } }));
      return "تم تسجيل الاستلام";
    },
  });
  return h("div", { class: "mt" }, h("div", { class: "row" }, all), details("استلام جزئي / تسجيل فرق", partial));
}

function resolveControls(t, canAccept) {
  return details(`حل الخلاف (${t.disputed_qty} قطعة)`, actionForm({
    submit: "حفظ",
    children: [
      h("p", { class: "small muted", text: "القطع التي وُجدت تُستلم أو تُرجع. القطع المفقودة فعلاً لا يشطبها إلا مدير النظام بتصحيح موثّق." }),
      h("div", { class: "inline-fields" },
        canAccept ? field("وُجدت وتُستلم", input({ name: "accept", type: "number", inputmode: "numeric", min: 0, max: t.disputed_qty, value: 0 })) : null,
        field("تُرجع للمرسل", input({ name: "ret", type: "number", inputmode: "numeric", min: 0, max: t.disputed_qty, value: 0 }))),
      field("التوضيح", input({ name: "reason", required: true, maxlength: 1000 })),
    ],
    run: async (d, op) => {
      await op.run("app_resolve_dispute", (requestKey) => ({ p_id: t.id, p: { requestKey, acceptQty: canAccept ? int(d.accept) || 0 : 0, returnQty: int(d.ret) || 0, reason: d.reason } }));
      return "تم تسجيل حل الخلاف";
    },
  }));
}

/** One transfer with its receive / dispute controls. ctx = { mine: custody ids, is_supervisor }. Used here and in «مهامي». */
export function transferCard(t, ctx) {
  const chip = (label, val, tone) => h("span", { class: `qty-chip ${tone ? `badge ${tone}` : ""}` }, `${label} `, h("b", { class: "num", text: val }));
  const receiver = ctx.mine.includes(t.to_custody_id);
  const sender = ctx.mine.includes(t.from_custody_id);
  return h("article", { class: "card m0 transfer", dataset: { order: t.order_code } },
    h("div", { class: "card-row" },
      h("div", {}, h("b", { text: t.order_code }), ` — ${t.color} / ${t.size} `, h("span", { class: "small muted ltr", text: t.lot_code }),
        h("div", { class: "small" }, "من ", h("b", { text: t.from_label }), " إلى ", h("b", { text: t.to_label })),
        h("div", { class: "small muted" }, `${DIRECTION[t.direction]} · أرسلها ${t.created_by_name} · ${fmtDate(t.created_at)} · `, h("span", { class: "ltr", text: t.transfer_code })),
        t.reason ? h("div", { class: "small", text: `السبب: ${t.reason}` }) : null),
      h("div", { class: "row" },
        badge(CONDITION_LABEL[t.condition], t.condition === "DEFECTIVE" ? "danger" : "ok"),
        badge(TRANSFER_STATE[t.state], t.disputed_qty ? "danger" : t.pending_qty ? "warn" : "ok"),
        t.open && t.age_hours >= 24 ? badge(`مفتوح منذ ${t.age_hours} ساعة`, "warn") : null)),
    h("div", { class: "qtys mt" }, chip("مُرسل", t.dispatched_qty), chip("مستلم", t.accepted_qty),
      t.pending_qty ? chip("بانتظار الاستلام", t.pending_qty, "warn") : null, t.disputed_qty ? chip("خلاف", t.disputed_qty, "danger") : null,
      t.returned_qty ? chip("مُرجع للمرسل", t.returned_qty) : null, t.written_off_qty ? chip("شُطب إدارياً", t.written_off_qty, "danger") : null),
    receiver && t.pending_qty > 0 ? receiveControls(t) : null,
    t.disputed_qty > 0 && (receiver || sender || ctx.is_supervisor) ? resolveControls(t, receiver || ctx.is_supervisor) : null);
}

export async function render({ me, query }) {
  const viewAll = me.roles.some((r) => ["ADMIN", "SUPERVISOR", "REVIEWER"].includes(r));
  const tabs = TABS.filter(([k]) => (k === "all" ? viewAll : me.departments.length > 0 || k === "disputes"));
  const tab = tabs.some(([k]) => k === query.tab) ? query.tab : tabs[0][0];
  const v = await rpc("app_list_transfers", { p_tab: tab });
  return h("div", {},
    pageHead("سجل التحويلات", "القطع المرسلة تبقى «قيد النقل» حتى يؤكد المستلم الكمية؛ الفروقات تُسجل كخلاف ولا تختفي."),
    h("nav", { class: "tabs", attrs: { "aria-label": "أنواع التحويلات" } },
      tabs.map(([k, label]) => h("a", { attrs: { href: `#/transfers?tab=${k}`, "aria-current": k === tab ? "page" : null }, text: label }))),
    v.rows.length ? h("div", { class: "stack" }, v.rows.map((t) => transferCard(t, v))) : empty("لا توجد تحويلات هنا"));
}
