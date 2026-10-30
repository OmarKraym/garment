// Safe DOM construction: text is always set with textContent — never innerHTML — so data from the
// database can never become executable markup (XSS).

/** h("div", { class: "card", onclick: fn, attrs: { "aria-label": "x" } }, child, "text", [more]) */
export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = String(v);
    else if (k === "attrs") for (const [a, av] of Object.entries(v)) { if (av !== undefined && av !== null && av !== false) el.setAttribute(a, av === true ? "" : String(av)); }
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k in el) el[k] = v;
    else el.setAttribute(k, String(v));
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export function clear(el) { el.replaceChildren(); return el; }

export const num = (v) => h("span", { class: "num", text: v ?? 0 });
export const badge = (text, tone) => h("span", { class: `badge ${tone ?? ""}`, text });
export const empty = (text) => h("p", { class: "empty", text });

export function alertBox(kind, text) {
  return h("div", { class: `alert ${kind}`, attrs: { role: kind === "error" ? "alert" : "status" }, text });
}

export function toast(text) {
  const box = document.getElementById("toasts");
  const t = h("div", { class: "alert success toast", attrs: { role: "status" }, text });
  box.append(t);
  while (box.children.length > 3) box.firstElementChild.remove();
  setTimeout(() => t.remove(), 7000);
}

export function pageHead(title, sub, ...actions) {
  return h("div", { class: "page-head" },
    h("div", {}, h("h1", { text: title }), sub ? h("p", { text: sub }) : null),
    actions.length ? h("div", { class: "row" }, actions) : null);
}

export function table(headers, rows, rowClass) {
  return h("div", { class: "table-wrap" }, h("table", {},
    h("thead", {}, h("tr", {}, headers.map((x) => h("th", { class: x.num ? "num" : "", text: x.label })))),
    h("tbody", {}, rows.map((r) => h("tr", { class: rowClass?.(r) ?? "" },
      headers.map((x) => {
        const v = x.cell(r);
        return h("td", { class: x.num ? "num" : x.cls ?? "" }, v instanceof Node ? v : String(v ?? ""));
      }))))));
}

/** Labelled form control: the label wraps the control (accessible, no ids needed). */
export function field(label, control, hint) {
  return h("label", { class: "field" }, h("span", { class: "label", text: label }), control, hint ? h("span", { class: "hint", text: hint }) : null);
}

export function input(attrs) { return h("input", { attrs }); }

export function select(name, options, value, attrs = {}) {
  return h("select", { attrs: { name, ...attrs } },
    options.map((o) => h("option", { attrs: { value: o.value, selected: String(o.value) === String(value ?? "") }, text: o.label })));
}

export function details(summary, ...content) {
  return h("details", { class: "action" }, h("summary", { text: summary }), content);
}

export function fmtDate(d) {
  if (!d) return "—";
  if (typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d)) return d;
  // Wrapped in Unicode isolates so the date keeps its order inside Arabic sentences (bidi).
  return `\u2068${new Date(d).toLocaleString("ar-LY-u-nu-latn", {
    timeZone: "Africa/Tripoli", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  })}\u2069`;
}

export function todayLocal() {
  return new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Tripoli" });
}

export function formData(form) {
  return Object.fromEntries(new FormData(form).entries());
}

/**
 * Shows a one-time secret (e.g. a temporary password) in a modal dialog. It is never stored:
 * closing the dialog removes it from the page for good.
 */
export function secretDialog({ title, intro, rows = [], secret, note }) {
  const copyMsg = h("span", { class: "small muted", attrs: { role: "status" } });
  const value = h("output", { class: "secret ltr", text: secret });
  const copy = h("button", { class: "btn-secondary", attrs: { type: "button" }, text: "نسخ", onclick: async () => {
    try { await navigator.clipboard.writeText(secret); copyMsg.textContent = "تم النسخ"; }
    catch { getSelection().selectAllChildren(value); copyMsg.textContent = "حدِّد النص وانسخه يدوياً"; }
  } });
  const dlg = h("dialog", { class: "secret-dialog", attrs: { "aria-labelledby": "secret-title" } },
    h("h2", { attrs: { id: "secret-title" }, text: title }),
    intro ? h("p", { text: intro }) : null,
    rows.length ? h("dl", { class: "kv" }, rows.flatMap(([k, v]) => [h("dt", { text: k }), h("dd", { class: "ltr", text: v })])) : null,
    h("div", { class: "secret-box" }, value, copy), copyMsg,
    note ? alertBox("warn", note) : null,
    h("div", { class: "row mt" }, h("button", { attrs: { type: "button" }, text: "تم، سلّمتها للموظف", onclick: () => dlg.close() })));
  dlg.addEventListener("close", () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
  return dlg;
}
