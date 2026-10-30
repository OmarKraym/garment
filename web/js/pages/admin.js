import { edge, rpc } from "../api.js";
import { badge, details, empty, field, fmtDate, h, input, pageHead, secretDialog, select, table } from "../dom.js";
import { actionButton, actionForm, int, optional } from "../forms.js";
import { CONDITION_LABEL, MODE_LABEL, ROLE_LABEL, STAGE_LABEL, STAGES } from "../labels.js";

const ROLE_HELP = {
  ADMIN: "الحسابات والأقسام والصلاحيات وتصحيح الكميات",
  SUPERVISOR: "الطلبات وإطلاقها، قرارات العيوب، توزيع المهام",
  REVIEWER: "عرض التقارير والمطابقة فقط، دون تعديل",
};

/** Permissions (global roles) + department memberships (each = "worker in department X"). */
function accessPicker(departments, current = []) {
  const has = (role, dept) => current.some((r) => r.role === role && (r.department_id ?? null) === (dept ?? null));
  return h("div", { class: "stack" },
    h("fieldset", {}, h("legend", { text: "الصلاحيات" }),
      h("div", { class: "grid grid-3" }, ["ADMIN", "SUPERVISOR", "REVIEWER"].map((r) => h("label", { class: "role-option" },
        h("input", { attrs: { type: "checkbox", name: "role", value: r, checked: has(r) } }),
        h("span", {}, h("b", { text: ROLE_LABEL[r] }), h("span", { class: "small muted", text: ` — ${ROLE_HELP[r]}` })))))),
    h("fieldset", {}, h("legend", { text: "الأقسام (يعمل فيها ويستلم ويُسلِّم القطع)" }),
      h("div", { class: "grid grid-3" }, departments.filter((d) => d.active).map((d) => h("label", { class: "check" },
        h("input", { attrs: { type: "checkbox", name: "dept", value: d.id, checked: has("WORKER", d.id) } }),
        d.name_ar, d.custody_mode === "INDIVIDUAL" ? h("span", { class: "small muted", text: " (عهدة فردية)" }) : null)))));
}

const readRoles = (form) => [
  ...[...form.querySelectorAll("input[name=role]:checked")].map((x) => ({ role: x.value })),
  ...[...form.querySelectorAll("input[name=dept]:checked")].map((x) => ({ role: "WORKER", departmentId: x.value })),
];

function showTempPassword(res, displayName, isNew) {
  secretDialog({
    title: isNew ? "تم إنشاء الحساب" : "كلمة مرور مؤقتة جديدة",
    intro: "سلّم الموظف اسم المستخدم وكلمة المرور التالية. تظهر هذه الكلمة الآن فقط ولا يمكن عرضها مرة أخرى.",
    rows: [["الموظف", displayName], ["اسم المستخدم", res.username]],
    secret: res.temporaryPassword,
    note: `صالحة لمدة ${res.expiresInHours} ساعة ولمرة واحدة: عند أول دخول يُجبر الموظف على اختيار كلمة مرور جديدة، ولا يستطيع تنفيذ أي عملية قبل ذلك.`,
  });
}

function createEmployeeForm(departments) {
  return details("إضافة موظف", actionForm({
    submit: "إنشاء الحساب",
    children: [
      h("div", { class: "grid grid-2" },
        field("اسم المستخدم", input({ name: "username", required: true, pattern: "[a-z0-9_.]{3,32}", autocomplete: "off", class: "ltr", maxlength: 32 }), "حروف لاتينية صغيرة وأرقام و _ . — يكتبه الموظف عند الدخول"),
        field("الاسم الظاهر", input({ name: "displayName", required: true, maxlength: 100 }))),
      accessPicker(departments),
      h("p", { class: "small muted", text: "كلمة المرور يُنشئها النظام تلقائياً وتظهر لك مرة واحدة بعد الحفظ." }),
    ],
    run: async (d, _op, form) => {
      const roles = readRoles(form);
      if (!roles.length) throw new Error("اختر صلاحية أو قسماً واحداً على الأقل");
      const res = await edge("staff-admin", { action: "create", username: d.username.trim().toLowerCase(), displayName: d.displayName.trim(), roles });
      form.reset();
      showTempPassword(res, d.displayName.trim(), true);
      return "تم إنشاء الحساب";
    },
  }));
}

function passwordBadge(e) {
  if (!e.must_change_password) return null;
  if (e.temp_expired) return badge("انتهت صلاحية كلمة المرور المؤقتة", "danger");
  return badge(`بانتظار أول دخول — حتى ${fmtDate(e.temp_expires_at)}`, "warn");
}

function employeeCard(e, v) {
  const self = e.id === v.self_id;
  const workerDepts = e.roles.filter((r) => r.role === "WORKER").map((r) => r.department_name);
  const perms = e.roles.filter((r) => r.role !== "WORKER").map((r) => ROLE_LABEL[r.role]);
  const initials = e.display_name.trim().split(/\s+/).map((w) => w[0]).slice(0, 2).join("");
  const rolesForm = actionForm({
    submit: "حفظ الصلاحيات والأقسام", children: [accessPicker(v.departments, e.roles)],
    run: async (_d, _op, form) => {
      const roles = readRoles(form);
      if (!roles.length) throw new Error("اختر صلاحية أو قسماً واحداً على الأقل");
      await rpc("app_set_employee_roles", { p_employee: e.id, p_roles: roles });
      return "تم تحديث الصلاحيات والأقسام";
    },
  });
  const account = self ? null : h("div", { class: "row account-actions" },
    e.active ? actionButton("إصدار كلمة مرور مؤقتة جديدة", {
      cls: "btn-sm btn-secondary",
      confirm: `إصدار كلمة مرور مؤقتة جديدة لـ ${e.display_name}؟ ستتوقف كلمة مروره الحالية فوراً.`,
      run: async () => {
        const res = await edge("staff-admin", { action: "reset_password", employeeId: e.id });
        showTempPassword(res, e.display_name, false);
        return "تم إصدار كلمة مرور مؤقتة";
      },
    }) : null,
    actionButton(e.active ? "إيقاف الحساب" : "تفعيل الحساب", {
      cls: e.active ? "btn-sm btn-danger-quiet" : "btn-sm",
      confirm: e.active ? `إيقاف حساب ${e.display_name}؟ سيُمنع من الدخول فوراً.` : null,
      run: async () => { await edge("staff-admin", { action: "set_active", employeeId: e.id, active: !e.active }); return e.active ? "تم إيقاف الحساب" : "تم تفعيل الحساب"; },
    }));
  // Irreversible: the admin must type the username. The server re-checks everything.
  const remove = self ? null : details("حذف الحساب", h("div", { class: "danger-zone stack" },
    h("p", { class: "small", text: "يُحذف حساب الدخول نهائياً ويختفي الموظف من القوائم، ويبقى اسمه في السجلات السابقة (من قصّ، من أرسل، من استلم). لا يمكن التراجع." }),
    h("p", { class: "small muted", text: "لا يُحذف حساب لديه قطع في عهدته أو تحويلات بانتظار استلامه أو تكليفات مفتوحة. للإيقاف المؤقت استخدم «إيقاف الحساب»." }),
    actionForm({
      submit: "حذف الحساب نهائياً", danger: true,
      children: [field(`للتأكيد اكتب اسم المستخدم: ${e.username}`, input({ name: "confirm", required: true, autocomplete: "off", autocapitalize: "off", spellcheck: "false", class: "ltr", maxlength: 32 }))],
      confirm: () => `حذف حساب ${e.display_name} نهائياً؟`,
      run: async (d) => {
        if (d.confirm.trim().toLowerCase() !== e.username) throw new Error("اسم المستخدم غير مطابق");
        await edge("staff-admin", { action: "delete", employeeId: e.id, confirmUsername: d.confirm });
        return `تم حذف حساب ${e.display_name}`;
      },
    })));
  return h("article", { class: `person employee ${e.active ? "" : "inactive"}`, dataset: { username: e.username } },
    h("div", { class: "person-head" },
      h("span", { class: "avatar", attrs: { "aria-hidden": "true" }, text: initials }),
      h("div", { class: "person-main" },
        h("div", { class: "person-name" }, h("b", { text: e.display_name }), h("span", { class: "small muted ltr", text: e.username })),
        h("div", { class: "small muted", text: [...perms, ...workerDepts].join(" · ") || "بلا صلاحيات" })),
      e.active ? null : badge("موقوف", "danger")),
    passwordBadge(e) ? h("div", { class: "person-flags" }, passwordBadge(e)) : null,
    h("div", { class: "person-actions" },
      e.active && workerDepts.length ? h("a", { class: "btn btn-sm btn-ghost", attrs: { href: `#/work?employee=${e.id}` }, text: e.open_tasks ? `إسناد مهمة (${e.open_tasks} مفتوحة)` : "إسناد مهمة" }) : null,
      details("إدارة الحساب", h("div", { class: "stack" }, rolesForm, account, remove))));
}

function departmentsSection(v) {
  const stageOpts = [{ value: "", label: "بدون مرحلة" }, ...STAGES.map((s) => ({ value: s, label: STAGE_LABEL[s] }))];
  const modeOpts = Object.entries(MODE_LABEL).map(([value, label]) => ({ value, label }));
  return h("section", { class: "block" }, h("h2", { text: "الأقسام" }),
    h("div", { class: "people" }, v.departments.map((d) => h("div", { class: "person dept" },
      h("div", { class: "card-row" },
        h("div", {}, h("b", { text: d.name_ar }), " ", h("span", { class: "small muted ltr", text: d.code }),
          h("div", { class: "small muted", text: `${d.stage ? STAGE_LABEL[d.stage] : "بدون مرحلة"} · ${MODE_LABEL[d.custody_mode]} · ${d.member_count} عامل` })),
        h("div", { class: "row" }, d.active ? null : badge("موقوف", "danger"),
          d.stage && d.stage !== "CUTTING" ? (d.allow_return ? null : badge("الإرجاع موقوف", "warn")) : null)),
      details("تعديل", actionForm({
        submit: "حفظ",
        children: [h("div", { class: "inline-fields" },
          field("الاسم", input({ name: "nameAr", value: d.name_ar, required: true, maxlength: 100 })),
          field("نوع العهدة", select("custodyMode", modeOpts, d.custody_mode)),
          field("الحالة", select("active", [{ value: "true", label: "فعّال" }, { value: "false", label: "موقوف" }], String(d.active))),
          field("الإرجاع للمرحلة السابقة", select("allowReturn", [{ value: "true", label: "مسموح (مع ذكر السبب)" }, { value: "false", label: "موقوف" }], String(d.allow_return))))],
        run: async (x) => {
          await rpc("app_update_department", { p_id: d.id, p: { nameAr: x.nameAr, custodyMode: x.custodyMode, active: x.active === "true", allowReturn: x.allowReturn === "true" } });
          return "تم تحديث القسم";
        },
      }))))),
    details("إضافة قسم", actionForm({
      submit: "إضافة",
      children: [h("div", { class: "inline-fields" },
        field("الرمز", input({ name: "code", required: true, pattern: "[A-Za-z0-9_]{2,32}", class: "ltr", maxlength: 32 })),
        field("الاسم", input({ name: "nameAr", required: true, maxlength: 100 })),
        field("المرحلة", select("stage", stageOpts, "")),
        field("نوع العهدة", select("custodyMode", modeOpts, "SHARED")))],
      run: async (x) => {
        await rpc("app_create_department", { p: { code: x.code, nameAr: x.nameAr, stage: optional(x.stage), custodyMode: x.custodyMode } });
        return "تمت إضافة القسم";
      },
    })));
}

async function adjustments() {
  const v = await rpc("app_adjustments_view");
  const sign = select("sign", [{ value: "-1", label: "إنقاص (قطع مفقودة/زائدة في السجل)" }, { value: "1", label: "زيادة (قطع موجودة غير مسجلة)" }], "-1");
  return h("div", {},
    pageHead("تصحيح الكميات", "للمدير فقط، بسبب مكتوب. لا يُعدَّل أي سجل سابق؛ التصحيح حركة جديدة تظهر في المطابقة والتدقيق.",
      h("a", { class: "btn btn-ghost", attrs: { href: "#/admin" }, text: "رجوع للإدارة" })),
    h("section", { class: "card" }, h("h2", { text: "تصحيح جديد" }), actionForm({
      submit: "تسجيل التصحيح", danger: true,
      confirm: (d) => `تأكيد ${d.sign === "1" ? "زيادة" : "إنقاص"} ${d.quantity} قطعة؟`,
      children: [h("div", { class: "grid grid-2" },
        field("الدفعة", select("lot", v.lots.map((l) => ({ value: l.id, label: l.label })), undefined, { required: true })),
        field("العهدة", select("custody", v.custodies.map((c) => ({ value: c.id, label: c.label })), undefined, { required: true })),
        field("الحالة", select("condition", Object.entries(CONDITION_LABEL).map(([value, label]) => ({ value, label })), "GOOD")),
        field("الاتجاه", sign),
        field("الكمية", input({ name: "quantity", type: "number", inputmode: "numeric", min: 1, required: true })),
        field("مرجع (محضر جرد…)", input({ name: "reference", maxlength: 200 }))),
        field("السبب", input({ name: "reason", required: true, minlength: 3, maxlength: 1000 }))],
      run: async (d, op) => {
        await op.run("app_create_adjustment", (requestKey) => ({ p: { requestKey, lotId: d.lot, custodyId: d.custody, condition: d.condition,
          signedQty: int(d.quantity) * int(d.sign), reason: d.reason, reference: optional(d.reference) } }));
        return "تم تسجيل التصحيح";
      },
    })),
    h("section", { class: "card" }, h("h2", { text: "الأرصدة الحالية" }), v.holdings.length ? table([
      { label: "الطلب", cell: (x) => x.order_code }, { label: "اللون/المقاس", cell: (x) => `${x.color} / ${x.size}` },
      { label: "الدفعة", cls: "ltr small", cell: (x) => x.lot_code }, { label: "العهدة", cell: (x) => x.custody_label },
      { label: "الحالة", cell: (x) => CONDITION_LABEL[x.condition] }, { label: "الكمية", num: true, cell: (x) => x.qty },
    ], v.holdings) : empty("لا توجد أرصدة")),
    h("section", { class: "card" }, h("h2", { text: "سجل التصحيحات" }), v.history.length ? table([
      { label: "الوقت", cell: (x) => fmtDate(x.created_at) }, { label: "الطلب", cell: (x) => x.order_code },
      { label: "الدفعة", cls: "ltr small", cell: (x) => x.lot_code }, { label: "العهدة", cell: (x) => x.custody_label },
      { label: "الحالة", cell: (x) => CONDITION_LABEL[x.condition] }, { label: "الكمية", num: true, cell: (x) => (x.signed_qty > 0 ? `+${x.signed_qty}` : x.signed_qty) },
      { label: "السبب", cell: (x) => x.reason }, { label: "المرجع", cell: (x) => x.reference ?? "" }, { label: "اعتمده", cell: (x) => x.approved_by_name },
    ], v.history) : empty("لا توجد تصحيحات")));
}

export async function render({ parts }) {
  if (parts[1] === "adjustments") return adjustments();
  const v = await rpc("app_admin_view");
  return h("div", {},
    pageHead("الإدارة", null, h("a", { class: "btn btn-secondary", attrs: { href: "#/admin/adjustments" }, text: "تصحيح الكميات" })),
    h("section", { class: "block" }, h("h2", {}, "الموظفون ", badge(String(v.employees.length))), createEmployeeForm(v.departments),
      v.employees.length ? h("div", { class: "people mt" }, v.employees.map((e) => employeeCard(e, v))) : empty("لا يوجد موظفون")),
    departmentsSection(v));
}
