// App shell: authentication gate, role-based navigation, hash routing, inactivity sign-out.
import { CONFIG } from "./config.js";
import { ApiError, hasSession, rpc, signIn, signOut } from "./api.js";
import { alertBox, clear, h } from "./dom.js";
import { ROLE_LABEL } from "./labels.js";
import { changePasswordForm } from "./pages/account.js";
import { initPwa } from "./pwa.js";

const PAGES = {
  "": () => import("./pages/dashboard.js"),
  tasks: () => import("./pages/tasks.js"),
  transfers: () => import("./pages/transfers.js"),
  work: () => import("./pages/work.js"),
  orders: () => import("./pages/orders.js"),
  quality: () => import("./pages/quality.js"),
  warehouse: () => import("./pages/warehouse.js"),
  reports: () => import("./pages/reports.js"),
  admin: () => import("./pages/admin.js"),
  account: () => import("./pages/account.js"),
};

const root = document.getElementById("app");
let me = null;
let lastActivity = Date.now();

function parseHash() {
  const raw = location.hash.replace(/^#\/?/, "");
  const [path, qs] = raw.split("?");
  const parts = path.split("/").filter(Boolean);
  return { parts, query: Object.fromEntries(new URLSearchParams(qs ?? "")) };
}

export function navigate(hash) { location.hash = hash; }

function navItems(me) {
  const worker = me.departments.length > 0;
  const has = (r) => me.roles.includes(r);
  const viewAll = has("ADMIN") || has("SUPERVISOR") || has("REVIEWER");
  const items = [];
  if (worker) items.push(["tasks", "مهامي", me.incoming]);
  if (viewAll) items.push(["", "لوحة المتابعة"]);
  if (worker || viewAll) items.push(["orders", "الطلبيات"]);
  if (me.departments.some((d) => d.stage === "WAREHOUSE") || viewAll) items.push(["warehouse", "المخزن والتسليم"]);
  if (worker || viewAll) items.push(["quality", "الجودة والعيوب"]);
  if (worker || viewAll) items.push(["transfers", "سجل التحويلات"]);
  if (has("SUPERVISOR") || has("ADMIN")) items.push(["work", "تكليفات العمل"]);
  if (viewAll) items.push(["reports", "التقارير"]);
  if (has("ADMIN")) items.push(["admin", "الإدارة"]);
  items.push(["account", "حسابي"]);
  return items;
}

/** Old addresses (bookmarks) and each user's home screen. */
function resolveRoute(me, parts) {
  const page = parts[0] ?? "";
  if (page === "stock" || page === "cutting") return "tasks";
  if (page === "") {
    const viewAll = me.roles.some((r) => ["ADMIN", "SUPERVISOR", "REVIEWER"].includes(r));
    if (!viewAll && me.departments.length) return "tasks"; // workers start on «مهامي»
  }
  return page;
}

function shell(content) {
  const { parts } = parseHash();
  const current = resolveRoute(me, parts);
  const roleText = [...me.roles.map((r) => ROLE_LABEL[r]), ...me.departments.map((d) => d.name_ar)].join("، ");
  return h("div", { class: "shell" },
    h("header", { class: "topbar" },
      h("a", { class: "brand", attrs: { href: "#/" }, text: "إدارة إنتاج المصنع" }),
      h("div", { class: "who" },
        h("span", { attrs: { title: roleText }, text: me.display_name }),
        h("button", { class: "btn-sm btn-ghost btn-on-dark", attrs: { type: "button" }, text: "خروج", onclick: () => logout() }))),
    h("nav", { class: "nav", attrs: { "aria-label": "القائمة الرئيسية" } },
      navItems(me).map(([key, label, count]) => h("a", {
        attrs: { href: `#/${key}`, "aria-current": key === current ? "page" : null },
      }, label, count ? h("span", { class: "count", attrs: { "aria-label": `${count} بانتظارك` }, text: count }) : null))),
    h("main", { class: "main", attrs: { id: "main" } }, content));
}

function signInScreen(message) {
  const err = h("div");
  if (message) err.append(alertBox("error", message));
  const user = h("input", { attrs: { name: "username", autocomplete: "username", autocapitalize: "none", spellcheck: "false", dir: "ltr", required: true } });
  const pass = h("input", { attrs: { name: "password", type: "password", autocomplete: "current-password", dir: "ltr", required: true } });
  const button = h("button", { attrs: { type: "submit" }, class: "w-full", text: "دخول" });
  const form = h("form", {},
    h("label", { class: "field" }, h("span", { class: "label", text: "اسم المستخدم" }), user),
    h("label", { class: "field" }, h("span", { class: "label", text: "كلمة المرور" }), pass),
    err, button);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    button.disabled = true;
    err.replaceChildren();
    try {
      await signIn(user.value, pass.value);
      await start();
    } catch (ex) {
      err.replaceChildren(alertBox("error", ex.message));
      button.disabled = false;
    }
  });
  clear(root).append(h("main", { class: "auth-wrap" }, h("div", { class: "card auth-card" },
    h("h1", { text: "إدارة إنتاج المصنع" }),
    h("p", { class: "muted center", text: "سجّل الدخول باسم المستخدم وكلمة المرور" }),
    form)));
  user.focus();
}

async function logout(message) {
  me = null;
  await signOut();
  signInScreen(message);
}

let renders = 0;
/** Renders the current route; #app gets aria-busy while loading and data-seq when done (assistive tech + tests). */
async function render() {
  const seq = ++renders;
  root.setAttribute("aria-busy", "true");
  try { await renderRoute(); } finally {
    if (seq === renders) { root.removeAttribute("aria-busy"); root.dataset.seq = String(seq); }
  }
}

async function renderRoute() {
  if (!me) return;
  try {
    me = await rpc("app_whoami");
  } catch (e) {
    if (e instanceof ApiError && e.code === "UNAUTHENTICATED") return logout(e.message);
    if (!me?.roles) { // first load failed (e.g. offline): no menu yet, offer a retry
      clear(root).append(h("main", { class: "auth-wrap" }, h("div", { class: "card auth-card" },
        h("h1", { text: "إدارة إنتاج المصنع" }), alertBox("error", e.message),
        h("button", { class: "w-full", attrs: { type: "button" }, text: "إعادة المحاولة", onclick: () => render() }))));
      return;
    }
    clear(root).append(shell(alertBox("error", e.message)));
    return;
  }
  if (me.must_change_password) {
    clear(root).append(shell(h("section", { class: "card w-narrow" },
      h("h1", { text: "غيّر كلمة المرور أولاً" }),
      h("p", { class: "muted", text: "تدخل الآن بكلمة مرور مؤقتة أصدرها النظام. اكتبها في الحقل الأول، ثم اختر كلمة مرور جديدة لا يعرفها غيرك. لا يمكن تنفيذ أي عملية قبل ذلك." }),
      changePasswordForm())));
    return;
  }
  const { parts, query } = parseHash();
  const route = resolveRoute(me, parts);
  const loader = PAGES[route];
  const main = h("div", {}, h("p", { class: "loading", attrs: { role: "status" }, text: "جارٍ التحميل…" }));
  clear(root).append(shell(main));
  if (!loader) { main.replaceChildren(alertBox("error", "الصفحة غير موجودة")); return; }
  try {
    const page = await loader();
    const node = await page.render({ me, parts, query, navigate });
    main.replaceChildren(node);
  } catch (e) {
    if (e instanceof ApiError && e.code === "UNAUTHENTICATED") return logout(e.message);
    main.replaceChildren(h("div", { class: "card" },
      h("h1", { text: e instanceof ApiError && e.code === "FORBIDDEN" ? "غير مسموح" : "تعذر عرض الصفحة" }),
      h("p", { class: "muted", text: e.message })));
  }
}

async function start() {
  if (!(await hasSession())) return signInScreen();
  me = {};
  await render();
}

// Inactivity sign-out (factory phones may be shared).
for (const ev of ["pointerdown", "keydown", "touchstart"]) window.addEventListener(ev, () => { lastActivity = Date.now(); }, { passive: true });
setInterval(() => {
  if (me && Date.now() - lastActivity > CONFIG.idleMinutes * 60_000) logout("تم تسجيل الخروج تلقائياً بعد فترة عدم نشاط.");
}, 30_000);

window.addEventListener("hashchange", () => render());
window.addEventListener("refresh", () => render());
window.addEventListener("auth-lost", () => { if (me) logout("انتهت الجلسة. سجّل الدخول من جديد"); });
initPwa();
start();
