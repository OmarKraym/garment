// Form helper: one retry-safe operation per form, busy state, inline error, success toast + refresh.
import { ApiError, operation } from "./api.js";
import { alertBox, h, toast } from "./dom.js";

/**
 * actionForm({ children, submit: "حفظ", danger, confirm: (data) => "…?" , run: async (data, op) => "success text" })
 * `run` receives the form values and the operation (use op.run(fn, (key) => args) for idempotent writes).
 */
export function actionForm({ children = [], submit = "حفظ", danger = false, confirm, run, className = "" }) {
  const op = operation();
  const msg = h("div", { class: "msg" });
  const button = h("button", { attrs: { type: "submit" }, class: danger ? "btn-danger" : "", text: submit });
  const form = h("form", { class: className, attrs: { novalidate: false } }, children, button, msg);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (button.disabled) return;
    const data = Object.fromEntries(new FormData(form).entries());
    const question = confirm?.(data);
    if (question && !window.confirm(question)) return;
    button.disabled = true;
    const label = button.textContent;
    button.textContent = "جارٍ الحفظ…";
    msg.replaceChildren();
    try {
      const text = await run(data, op, form);
      if (text) toast(text);
      window.dispatchEvent(new CustomEvent("refresh"));
    } catch (err) {
      const m = err instanceof ApiError ? err.message : (err?.message ?? "خطأ غير متوقع");
      msg.replaceChildren(alertBox("error", m));
    } finally {
      button.disabled = false;
      button.textContent = label;
    }
  });
  return form;
}

/** Single button that performs an operation (with optional confirmation). */
export function actionButton(label, { confirm, run, cls = "" }) {
  const op = operation();
  const msg = h("div", { class: "msg" });
  const b = h("button", { attrs: { type: "button" }, class: cls, text: label });
  b.addEventListener("click", async () => {
    if (confirm && !window.confirm(confirm)) return;
    b.disabled = true;
    msg.replaceChildren();
    try {
      const text = await run(op);
      if (text) toast(text);
      window.dispatchEvent(new CustomEvent("refresh"));
    } catch (err) {
      msg.replaceChildren(alertBox("error", err?.message ?? "خطأ غير متوقع"));
    } finally {
      b.disabled = false;
    }
  });
  return h("span", { class: "stack" }, b, msg);
}

export const int = (v) => Number.parseInt(String(v ?? "").trim(), 10);
export const optional = (v) => { const s = String(v ?? "").trim(); return s ? s : null; };
