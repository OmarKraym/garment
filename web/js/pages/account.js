import { edge } from "../api.js";
import { field, h, input, pageHead } from "../dom.js";
import { actionForm } from "../forms.js";
import { ROLE_LABEL } from "../labels.js";
import { installCard } from "../pwa.js";

/** Change own password through the `account` Edge Function (verifies the current password server-side). */
export function changePasswordForm() {
  const pw = (name, label, auto) => field(label, input({ name, type: "password", autocomplete: auto, required: true, minlength: name === "current" ? 1 : 10, maxlength: 72 }));
  return actionForm({
    className: "w-form", submit: "تغيير كلمة المرور",
    children: [pw("current", "كلمة المرور الحالية", "current-password"),
      field("كلمة المرور الجديدة", input({ name: "next", type: "password", autocomplete: "new-password", required: true, minlength: 10, maxlength: 72 }),
        "10 أحرف على الأقل، حروف وأرقام، ولا تحتوي اسم المستخدم."),
      pw("again", "أعد كتابة كلمة المرور الجديدة", "new-password")],
    run: async (d, _op, form) => {
      if (d.next !== d.again) throw new Error("كلمتا المرور الجديدتان غير متطابقتين");
      await edge("account", { action: "change_password", currentPassword: d.current, newPassword: d.next });
      form.reset();
      return "تم تغيير كلمة المرور";
    },
  });
}

export async function render({ me }) {
  return h("div", {},
    pageHead("حسابي"),
    h("section", { class: "card w-narrow" },
      h("dl", { class: "kv" },
        h("dt", { text: "الاسم" }), h("dd", { text: me.display_name }),
        h("dt", { text: "اسم المستخدم" }), h("dd", { class: "ltr", text: me.username }),
        h("dt", { text: "الأدوار" }), h("dd", { text: me.roles.map((r) => ROLE_LABEL[r] ?? r).join("، ") }),
        h("dt", { text: "الأقسام" }), h("dd", { text: me.departments.map((d) => d.name_ar).join("، ") || "—" }))),
    h("section", { class: "card w-narrow" }, h("h2", { text: "تغيير كلمة المرور" }), changePasswordForm()),
    installCard());
}
