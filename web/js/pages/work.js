import { rpc } from "../api.js";
import { badge, empty, field, fmtDate, h, input, pageHead, select, table } from "../dom.js";
import { actionButton, actionForm, int, optional } from "../forms.js";
import { ASSIGN_STATUS } from "../labels.js";

export function progressForm(a, canCancel) {
  return h("div", { class: "row mt" },
    actionForm({
      className: "row", submit: "تحديث",
      children: [field("المنجز", input({ name: "done", type: "number", inputmode: "numeric", min: 0, max: a.assigned_qty, value: a.completed_qty, class: "qty-input" }))],
      run: async (d) => {
        const done = int(d.done);
        await rpc("app_update_assignment", { p_id: a.id, p: { completedQty: done, status: done >= a.assigned_qty ? "DONE" : "IN_PROGRESS" } });
        return done >= a.assigned_qty ? "أُنجزت المهمة" : "تم تحديث التقدم";
      },
    }),
    canCancel ? cancelButton(a) : null);
}

const cancelButton = (a) => actionButton("إلغاء", {
  cls: "btn-sm btn-ghost", confirm: "إلغاء هذه المهمة؟",
  run: async () => { await rpc("app_update_assignment", { p_id: a.id, p: { completedQty: a.completed_qty, status: "CANCELLED" } }); return "تم الإلغاء"; },
});

function assignForm(v, preselect) {
  const lineSel = select("line", v.lines.map((l) => ({ value: l.id, label: l.label })));
  const lotBox = h("div", {});
  const preDept = preselect && v.depts.find((d) => d.members.some((m) => m.id === preselect));
  const deptSel = select("dept", v.depts.map((d) => ({ value: d.id, label: d.name })), (preDept ?? v.depts.find((d) => d.members.length) ?? v.depts[0])?.id);
  const people = h("div", { class: "grid grid-3" });
  const refreshLots = () => {
    const l = v.lines.find((x) => x.id === lineSel.value);
    lotBox.replaceChildren(field("الدفعة (اختياري)", select("lot", [{ value: "", label: "بدون تحديد" }, ...(l?.lots ?? []).map((x) => ({ value: x.id, label: x.code }))], "")));
  };
  const refreshPeople = () => {
    const d = v.depts.find((x) => x.id === deptSel.value);
    people.replaceChildren(...(d?.members.length ? d.members.map((m) => h("label", { class: "check" },
      h("input", { attrs: { type: "checkbox", name: "emp", value: m.id, checked: m.id === preselect } }), m.name)) : [h("p", { class: "muted small", text: "لا يوجد عمال في هذا القسم" })]));
  };
  lineSel.addEventListener("change", refreshLots);
  deptSel.addEventListener("change", refreshPeople);
  refreshLots(); refreshPeople();
  return actionForm({
    submit: "إسناد",
    children: [h("div", { class: "grid grid-2" }, field("سطر الطلب", lineSel), lotBox, field("القسم", deptSel),
      field("الكمية المسندة (لكل عامل)", input({ name: "quantity", type: "number", inputmode: "numeric", min: 1, required: true }))),
      h("fieldset", {}, h("legend", { text: "العمال — اختيار أكثر من عامل يعني عملاً مشتركاً" }), people),
      field("ملاحظات", input({ name: "notes", maxlength: 500 }))],
    run: async (d, op, form) => {
      const employeeIds = [...form.querySelectorAll("input[name=emp]:checked")].map((x) => x.value);
      if (!employeeIds.length) throw new Error("اختر عاملاً واحداً على الأقل");
      await rpc("app_create_assignments", { p: { orderLineId: d.line, lotId: optional(d.lot), departmentId: d.dept, employeeIds, quantity: int(d.quantity), notes: optional(d.notes) } });
      return employeeIds.length > 1 ? "تم إسناد عمل مشترك" : "تم إسناد العمل";
    },
  });
}

export async function render({ query }) {
  const v = await rpc("app_work_view");
  return h("div", {},
    pageHead("المهام وتوزيع العمل", "المهام تسجل من يعمل على ماذا. العمل المشترك يُحسب جهداً ولا يضيف قطعاً."),
    h("section", { class: "card" }, h("h2", { text: "مهامي" }),
      v.mine.length ? h("div", { class: "stack" }, v.mine.map((a) => h("div", { class: "card m0" },
        h("div", { class: "card-row" },
          h("div", {}, h("b", { text: a.order_code }), ` — ${a.color} / ${a.size} `, a.lot_code ? h("span", { class: "small muted ltr", text: a.lot_code }) : null,
            h("div", { class: "small muted", text: `${a.department_name} · ${fmtDate(a.created_at)}${a.co_workers > 0 ? ` · مشتركة مع ${a.co_workers}` : ""}` }),
            a.notes ? h("div", { class: "small", text: a.notes }) : null),
          h("div", { class: "row" }, badge(ASSIGN_STATUS[a.status], a.status === "DONE" ? "ok" : a.status === "IN_PROGRESS" ? "primary" : ""),
            h("span", { class: "num", text: `${a.completed_qty} / ${a.assigned_qty}` }))),
        ["ASSIGNED", "IN_PROGRESS"].includes(a.status) ? progressForm(a, v.can_cancel) : null)))
        : empty("لا توجد مهام مسندة إليك")),
    v.assigner ? h("section", { class: "card" }, h("h2", { text: "إسناد عمل جديد" }), v.lines.length ? assignForm(v, query.employee) : empty("لا توجد طلبات مطلقة بعد؛ تُسند المهام على أوامر مطلقة للإنتاج")) : null,
    v.assigner ? h("section", { class: "card" }, h("h2", { text: "المهام المفتوحة في المصنع" }),
      v.open.length ? table([
        { label: "الموظف", cell: (a) => a.employee_name }, { label: "القسم", cell: (a) => a.department_name },
        { label: "الطلب", cell: (a) => a.order_code }, { label: "اللون/المقاس", cell: (a) => `${a.color} / ${a.size}` },
        { label: "المنجز", num: true, cell: (a) => `${a.completed_qty} / ${a.assigned_qty}` },
        { label: "الحالة", cell: (a) => ASSIGN_STATUS[a.status] },
        { label: "", cell: (a) => (v.can_cancel ? cancelButton(a) : "") },
      ], v.open) : empty("لا توجد مهام مفتوحة")) : null);
}
