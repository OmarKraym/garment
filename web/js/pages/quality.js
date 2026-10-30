import { rpc } from "../api.js";
import { badge, details, empty, field, fmtDate, h, input, pageHead, select } from "../dom.js";
import { actionForm, int } from "../forms.js";
import { DECISION, DEFECT_REASONS } from "../labels.js";

function decisionForm(d) {
  const decision = select("decision", Object.entries(DECISION).map(([value, label]) => ({ value, label })), "REWORK");
  const custodyBox = h("div", {});
  const update = () => custodyBox.replaceChildren(decision.value === "REWORK" ? "" :
    field("من عهدة", select("custody", d.holders.length ? d.holders.map((x) => ({ value: x.custody_id, label: `${x.label} (${x.qty})` }))
      : [{ value: "", label: "لا توجد قطع معيبة في أي عهدة" }], undefined, { required: true })));
  decision.addEventListener("change", update);
  update();
  return details("قرار المشرف", actionForm({
    submit: "اعتماد القرار",
    confirm: (x) => (x.decision !== "REWORK" ? "الإتلاف يُخرج القطع من المخزون نهائياً. متأكد؟" : null),
    children: [h("div", { class: "inline-fields" }, field("القرار", decision),
      field(`الكمية (المفتوح ${d.open_qty})`, input({ name: "quantity", type: "number", inputmode: "numeric", min: 1, max: d.open_qty, value: d.open_qty, required: true })),
      custodyBox), field("سبب القرار", input({ name: "reason", required: true, maxlength: 1000 }))],
    run: async (x, op) => {
      await op.run("app_decide_defect", (requestKey) => ({ p_id: d.id, p: {
        requestKey, decision: x.decision, quantity: int(x.quantity), custodyId: x.decision === "REWORK" ? null : x.custody || null, reason: x.reason } }));
      return x.decision === "REPLACE" ? "تم الإتلاف واعتماد قص بديل (يظهر في شاشة القص)" : "تم تسجيل القرار";
    },
  }));
}

export async function render({ query }) {
  const all = query.all === "1";
  const v = await rpc("app_list_defects", { p_all: all });
  const chip = (label, val, tone) => h("span", { class: `qty-chip ${tone ? `badge ${tone}` : ""}` }, `${label} `, h("b", { class: "num", text: val }));
  return h("div", {},
    pageHead("الجودة والعيوب", "القطع المعيبة تبقى محسوبة في مكانها. الإصلاح يعيدها سليمة دون إضافة قطع، والإتلاف بقرار المشرف فقط.",
      h("a", { class: "btn btn-ghost", attrs: { href: all ? "#/quality" : "#/quality?all=1" }, text: all ? "المفتوحة فقط" : "عرض الكل" })),
    v.rows.length ? h("div", { class: "stack" }, v.rows.map((d) => h("article", { class: "card m0" },
      h("div", { class: "card-row" },
        h("div", {}, h("b", { text: d.order_code }), ` — ${d.color} / ${d.size} `, h("span", { class: "small muted ltr", text: `${d.lot_code} · ${d.defect_code}` }),
          h("div", { text: `${DEFECT_REASONS[d.reason_code] ?? d.reason_code}${d.description ? ` — ${d.description}` : ""}` }),
          h("div", { class: "small muted", text: `اكتُشف في ${d.detected_department}${d.responsible_department ? ` · المسؤول: ${d.responsible_department}` : ""} · ${d.reported_by_name} · ${fmtDate(d.created_at)}` })),
        badge(d.status === "OPEN" ? "مفتوح" : "مغلق", d.status === "OPEN" ? "danger" : "ok")),
      h("div", { class: "qtys mt" }, chip("الكمية", d.quantity), chip("مُصلح", d.repaired_qty, "ok"), chip("متلف", d.scrapped_qty, "danger"), chip("مفتوح", d.open_qty, "warn")),
      d.holders.length ? h("p", { class: "small mt", text: `القطع المعيبة من هذه الدفعة الآن عند: ${d.holders.map((x) => `${x.label} (${x.qty})`).join("، ")}` }) : null,
      d.decisions.length ? h("ul", { class: "small list-plain" }, d.decisions.map((x) =>
        h("li", { text: `${DECISION[x.decision]} — ${x.quantity} قطعة — ${x.reason} (${x.approved_by}، ${fmtDate(x.approved_at)})` }))) : null,
      v.can_decide && d.status === "OPEN" ? decisionForm(d) : null)))
      : empty(all ? "لا توجد عيوب" : "لا توجد عيوب مفتوحة"));
}
