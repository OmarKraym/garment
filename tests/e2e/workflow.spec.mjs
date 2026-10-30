// Full factory workflow through the real UI, on desktop and a 360px phone.
import fs from "node:fs";
import { expect, test } from "@playwright/test";
import { startServer } from "./local-supabase.mjs";

test.describe.configure({ mode: "serial" });

let srv, page;
const PW = { admin: "Admin#Pass2026", cutter: "Cutter#Pass2026", tailor: "Tailor#Pass2026", tailor2: "Tailor2#Pass2026", boss: "Boss#Pass20261" };
let ORDER = "";   // automatic order number, read from the screen
const XSS = "<img src=x onerror=window.__xss=1>";

test.beforeAll(async ({ browser }) => {
  srv = await startServer();
  const admin = await srv.bootstrapAdmin("admin", PW.admin);
  const adminAuth = (await srv.db.pool.query("SELECT auth_user_id FROM factory.employees WHERE id = $1", [admin.id])).rows[0].auth_user_id;
  const d = srv.db.depts;
  const mk = async (name, roles) => {
    const u = await srv.db.makeUser(name, roles, { caller: adminAuth });
    await srv.db.pool.query("UPDATE auth.users SET encrypted_password = $2 WHERE id = $1", [u.authId, PW[name]]);
  };
  await mk("cutter", [{ role: "WORKER", departmentId: d.CUTTING }]);
  await mk("tailor", [{ role: "WORKER", departmentId: d.SEWING }]);
  await mk("tailor2", [{ role: "WORKER", departmentId: d.SEWING }]);
  await mk("boss", [{ role: "SUPERVISOR" }, ...["FINISHING_1", "IRONING", "FINISHING_2"].map((c) => ({ role: "WORKER", departmentId: d[c] }))]);

  page = await browser.newPage();
  page.on("dialog", (dg) => dg.accept());
  await page.addInitScript(() => {
    window.__csp = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
  });
  page.errors = [];
  page.on("pageerror", (e) => page.errors.push(String(e)));
});

test.afterAll(async () => { await page?.close(); await srv?.close(); });

// ---------------------------------------------------------------- helpers
const seq = () => page.evaluate(() => Number(document.getElementById("app").dataset.seq ?? 0));
/** Waits until a render that started after `after` has finished, then checks layout. */
async function settle(after = -1) {
  await page.waitForFunction((n) => { const a = document.getElementById("app"); return !a.hasAttribute("aria-busy") && Number(a.dataset.seq ?? 0) > n; }, after);
  const { sw, w } = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, w: window.innerWidth }));
  expect(sw, "no horizontal page scroll").toBeLessThanOrEqual(w + 1);
}
async function go(hash) { const n = await seq(); await page.evaluate((x) => { if (location.hash === x) window.dispatchEvent(new Event("refresh")); else location.hash = x; }, hash); await settle(n); }
async function login(user, pw) {
  await page.goto(`${srv.origin}/`);
  await page.getByLabel("اسم المستخدم").fill(user);
  await page.getByLabel("كلمة المرور").fill(pw);
  await page.getByRole("button", { name: "دخول" }).click();
  await expect(page.locator(".topbar")).toBeVisible();
  await settle();
}
async function logout() {
  await page.locator(".user-menu > summary").click();
  await page.getByRole("button", { name: "خروج" }).click();
  await expect(page.getByRole("button", { name: "دخول" })).toBeVisible();
}
/** Runs a UI action and waits for its success toast. */
async function act(fn, toastText) {
  await page.evaluate(() => document.getElementById("toasts").replaceChildren());
  const n = await seq();
  await fn();
  await expect(page.locator("#toasts")).toContainText(toastText);
  await settle(n);
}
const open = async (scope, summary) => { await scope.locator("summary", { hasText: summary }).first().click(); };
async function receiveAll() {
  await go("#/tasks");
  for (let i = 0; i < 10; i++) {
    const b = page.getByRole("button", { name: /^استلام الكل/ });
    if ((await b.count()) === 0) return;
    await act(() => b.first().click(), "تم استلام");
  }
}
async function passForward() {
  await go("#/tasks");
  const card = page.locator(".stock-group").first();
  await act(() => card.getByRole("button", { name: /^تمرير إلى/ }).click(), "تم تمرير");
}

// ---------------------------------------------------------------- tests
test("host security headers and anonymous access", async () => {
  const res = await page.request.get(`${srv.origin}/`);
  const hd = res.headers();
  expect(hd["content-security-policy"]).toContain("frame-ancestors 'none'");
  expect(hd["content-security-policy"]).toContain("script-src 'self'");
  expect(hd["x-frame-options"]).toBe("DENY");
  expect(hd["x-content-type-options"]).toBe("nosniff");
  const anon = await page.request.post(`${srv.origin}/rest/v1/rpc/app_dashboard`, {
    headers: { apikey: "local-test-anon-key", authorization: "Bearer local-test-anon-key", "content-type": "application/json" }, data: {},
  });
  expect(anon.status()).toBe(401); // the public key alone can call nothing
  await page.goto(`${srv.origin}/`);
  await page.getByLabel("اسم المستخدم").fill("admin");
  await page.getByLabel("كلمة المرور").fill("wrong-password-1");
  await page.getByRole("button", { name: "دخول" }).click();
  await expect(page.locator(".alert.error")).toContainText("غير صحيحة");
});

test("admin creates an account; the employee must replace the temporary password", async () => {
  await login("admin", PW.admin);
  await go("#/admin");
  await open(page.locator("main"), "إضافة موظف");
  const form = page.locator("details[open] form").first();
  await form.getByLabel("اسم المستخدم").fill("store1");
  await form.getByLabel("الاسم الظاهر").fill("أمين المخزن");
  await expect(form.getByLabel(/كلمة مرور/)).toHaveCount(0);            // the admin never chooses the password
  await form.getByLabel("المخزن والتسليم").check();
  await act(() => form.getByRole("button", { name: "إنشاء الحساب" }).click(), "تم إنشاء الحساب");
  const dialog = page.locator("dialog.secret-dialog");
  await expect(dialog).toBeVisible();
  await expect(dialog).toContainText("store1");
  const temp = (await dialog.locator(".secret").textContent()).trim();
  expect(temp).toMatch(/^[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4}$/);
  await dialog.getByRole("button", { name: /تم/ }).click();
  await expect(page.locator("dialog.secret-dialog")).toHaveCount(0);       // the secret is gone from the page
  await expect(page.locator('.employee[data-username="store1"]')).toContainText("بانتظار أول دخول");
  await go("#/admin/adjustments");
  await expect(page.getByRole("heading", { name: "تصحيح الكميات" })).toBeVisible();
  await logout();

  await login("store1", temp);
  await expect(page.getByRole("heading", { name: "غيّر كلمة المرور أولاً" })).toBeVisible();
  await expect(page.locator(".nav")).toContainText("حسابي");
  await page.getByLabel("كلمة المرور الحالية").fill(temp);
  await page.getByLabel(/^كلمة المرور الجديدة/).fill("Store#Mine2026");
  await page.getByLabel("أعد كتابة كلمة المرور الجديدة").fill("Store#Mine2026");
  await page.getByRole("button", { name: "تغيير كلمة المرور" }).click();
  await expect(page.getByRole("heading", { name: "غيّر كلمة المرور أولاً" })).toHaveCount(0);
  await expect(page.locator(".nav")).toContainText("المخزن");
  await logout();
  await login("store1", "Store#Mine2026");
  await logout();
});

test("owner's route: order (auto number) → cutter edits qty & cuts → distributes to 2 tailors → return → finishing → ironing → finishing 2 → warehouse", async () => {
  // supervisor: colours × sizes grid, automatic number, saved AND sent to cutting in one step
  await login("boss", PW.boss);
  await go("#/orders/new");
  await expect(page.getByLabel("رقم الطلب")).toHaveCount(0);                 // no manual order number
  const due = new Date(Date.now() + 30 * 864e5).toISOString().slice(0, 10);
  await page.getByLabel("الزبون", { exact: true }).fill("=HYPERLINK(1)");
  await page.getByLabel("تاريخ التسليم المطلوب").fill(due);
  await page.getByLabel("المنتج").fill("قميص رجالي");
  await page.getByLabel("رمز الموديل (اختياري)").fill(XSS);
  await page.getByLabel(/^الألوان/).fill("أزرق");
  await page.getByLabel(/^المقاسات/).fill("M، L");
  await page.getByLabel(/^المقاسات/).blur();
  await page.getByLabel("أزرق — M").fill("10");                               // L left empty → not ordered
  await act(() => page.getByRole("button", { name: "حفظ وإرسال للقص" }).click(), "وإرسالها للقص");
  ORDER = /PO-\d{4}-\d{4}/.exec(await page.locator("h1").textContent())[0];
  await expect(page.locator("main")).toContainText(XSS);                      // shown as text, never executed
  expect(await page.evaluate(() => window.__xss)).toBeUndefined();
  await expect(page.locator("main")).toContainText("قيد الإنتاج");
  await logout();

  // the administrator gives the tailor an extra assignment from the employee card
  await login("admin", PW.admin);
  await go("#/admin");
  const n0 = await seq();
  await page.locator('.employee[data-username="tailor"]').getByRole("link", { name: "إسناد مهمة" }).click();
  await settle(n0);
  await expect(page.getByRole("checkbox", { name: "tailor", exact: true })).toBeChecked();
  await page.getByLabel(/^الكمية المسندة/).fill("10");
  await act(() => page.getByRole("button", { name: "إسناد", exact: true }).click(), "تم إسناد العمل");
  await logout();

  // cutter: lands on «مهامي», raises the quantity to 12 (quantities only), cuts 12, splits 7 + 5
  await login("cutter", PW.cutter);
  await expect(page.locator("h1")).toHaveText("مهامي");
  const card = page.locator(`.cut-order[data-order="${ORDER}"]`);
  await card.getByLabel("المطلوب أزرق / M").fill("12");
  await card.getByLabel("قصّ الآن أزرق / M").fill("12");
  await act(() => card.getByRole("button", { name: "حفظ" }).click(), "تم تسجيل قص 12");
  const lot = page.locator(".stock-group", { hasText: ORDER });
  await expect(lot.locator(".good-total")).toHaveText("12");
  await lot.getByLabel("tailor", { exact: true }).check();
  await lot.getByLabel("tailor2", { exact: true }).check();
  await lot.getByRole("button", { name: "وزّع بالتساوي" }).click();
  await expect(lot.getByLabel("tailor — أزرق / M")).toHaveValue("6");
  await lot.getByLabel("tailor — أزرق / M").fill("7");
  await lot.getByLabel("tailor2 — أزرق / M").fill("5");
  await act(() => lot.getByRole("button", { name: "توزيع" }).click(), "تم توزيع 12 قطعة على 2 عمال");
  await logout();

  // tailor: receives 7, sees the assignment, passes everything to finishing 1
  await login("tailor", PW.tailor);
  await expect(page.locator(".nav .count")).toHaveText("1");
  await receiveAll();
  await expect(page.locator("main")).toContainText("تكليفاتي");
  await passForward();
  await logout();

  // tailor2: receives 5, returns 1 to the cutter with a reason, passes 4
  await login("tailor2", PW.tailor2);
  await receiveAll();
  const t2 = page.locator(".stock-group").first();
  await open(t2, "إرجاع إلى قسم القص");
  await t2.getByLabel("كمية الإرجاع").fill("1");
  await t2.getByLabel("سبب الإرجاع").fill("قص غير مطابق للمقاس");
  await act(() => t2.getByRole("button", { name: "إرجاع", exact: true }).click(), "تم إرجاع 1");
  await passForward();
  await logout();

  // cutter takes the returned piece back and gives it to tailor2 again
  await login("cutter", PW.cutter);
  await receiveAll();
  const back = page.locator(".stock-group", { hasText: ORDER });
  await back.getByLabel("tailor2", { exact: true }).check();
  await back.getByLabel("tailor2 — أزرق / M").fill("1");
  await act(() => back.getByRole("button", { name: "توزيع" }).click(), "تم توزيع 1");
  await logout();
  await login("tailor2", PW.tailor2);
  await receiveAll();
  await passForward();
  await logout();

  // finishing 1: 2 defective, 1 repaired, 1 scrapped by the supervisor, 11 continue
  await login("boss", PW.boss);
  await receiveAll();
  const good = page.locator(".stock-group").first();
  await expect(good.locator(".good-total")).toHaveText("12");
  await open(good, "تسجيل عيب");
  await good.getByLabel("الكمية المعيبة").fill("2");
  await act(() => good.getByRole("button", { name: "تسجيل عيب" }).click(), "تم تسجيل العيب");
  const bad = page.locator(".stock-group").first();
  await expect(bad.locator(".bad-total")).toHaveText("2");
  await open(bad, "تسجيل إصلاح");
  await bad.getByLabel("الكمية المُصلحة").fill("1");
  await act(() => bad.getByRole("button", { name: "تسجيل الإصلاح" }).click(), "تم تسجيل الإصلاح");
  await go("#/quality");
  const defect = page.locator("article", { hasText: ORDER }).first();
  await open(defect, "قرار المشرف");
  await defect.locator("select[name=decision]").selectOption("SCRAP");
  await defect.getByLabel(/^الكمية/).fill("1");
  await defect.getByLabel("سبب القرار").fill("تمزق لا يمكن إصلاحه");
  await act(() => defect.getByRole("button", { name: "اعتماد القرار" }).click(), "تم تسجيل القرار");
  await go("#/tasks");
  await expect(page.locator(".stock-group .good-total")).toHaveText("11");
  await expect(page.locator(".stock-group .bad-total")).toHaveText("0");
  await passForward();   // → ironing
  await receiveAll();
  await passForward();   // → finishing 2
  await receiveAll();
  await passForward();   // → warehouse
  await logout();

  // warehouse receives and delivers to the customer
  await login("store1", "Store#Mine2026");
  await receiveAll();
  await go("#/warehouse");
  const wh = page.locator(`.wh-order[data-order="${ORDER}"]`);
  await open(wh, "تسليم للزبون");
  await wh.getByLabel(/^كمية/).fill("11");
  await act(() => wh.getByRole("button", { name: "تسليم", exact: true }).click(), "تم التسليم");
  await expect(page.locator("main")).toContainText("لا توجد قطع في المخزن حالياً");
  await logout();
});

test("reports reconcile, CSV export is injection-safe and audited, order closes", async () => {
  await login("boss", PW.boss);
  await go("#/reports?type=reconciliation");
  await expect(page.locator(".alert.success")).toContainText("كل الكميات متطابقة");
  await go("#/reports?type=orders&filter=all");
  const [dl] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "تصدير CSV" }).click()]);
  const csv = fs.readFileSync(await dl.path(), "utf8");
  expect(csv.charCodeAt(0)).toBe(0xfeff);
  expect(csv).toContain("'=HYPERLINK(1)");
  expect(csv).toContain(`${ORDER},'=HYPERLINK(1),قميص رجالي,`);
  expect(csv).toMatch(new RegExp(`${ORDER},.*,قيد الإنتاج \\(أُرسلت للقص\\),12,12,0,0,11,1,1,0`));
  await go("#/reports?type=audit");
  await expect(page.locator("main")).toContainText("report.export");
  await go("#/orders?filter=all");
  const n = await seq();
  await page.getByRole("link", { name: ORDER }).click();
  await settle(n);
  await act(() => page.getByRole("button", { name: "إغلاق الطلبية" }).click(), "تم إغلاق الطلبية");
  for (const p of ["#/", "#/tasks", "#/transfers?tab=all", "#/work", "#/quality?all=1", "#/warehouse", "#/reports?type=movements", "#/account"]) {
    await go(p);
    await page.screenshot({ path: test.info().outputPath(`${p.replace(/\W+/g, "_")}.png`), fullPage: true });
  }
  await logout();
});

test("installable PWA: manifest, icons, service worker, offline shell without cached data", async () => {
  // every static file is in the service-worker list (so an update never leaves a stale file behind)
  const web = new URL("../../web/", import.meta.url).pathname;
  const files = fs.readdirSync(web, { recursive: true }).filter((f) => fs.statSync(web + f).isFile() && !["_headers", "sw.js"].includes(f));
  const shell = JSON.parse(/const SHELL = (\[[\s\S]*?\]);/.exec(fs.readFileSync(web + "sw.js", "utf8"))[1].replace(/,\s*\]/, "]"));
  expect([...files].sort()).toEqual(shell.filter(Boolean).sort());

  const manifest = await (await page.request.get(`${srv.origin}/manifest.webmanifest`)).json();
  expect(manifest).toMatchObject({ display: "standalone", start_url: "./", dir: "rtl", lang: "ar" });
  for (const icon of manifest.icons) expect((await page.request.get(`${srv.origin}/${icon.src}`)).status()).toBe(200);
  expect(manifest.icons.some((i) => i.purpose === "maskable" && i.sizes === "512x512")).toBe(true);

  await page.goto(`${srv.origin}/`);
  expect(await page.evaluate(async () => !!(await navigator.serviceWorker.ready).active)).toBe(true);
  await page.reload();
  expect(await page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
  await login("boss", PW.boss);              // fetches data through the network while controlled
  await go("#/reports?type=stages");
  const cached = await page.evaluate(async () => {
    const out = [];
    for (const k of await caches.keys()) for (const r of await (await caches.open(k)).keys()) out.push(new URL(r.url).pathname);
    return out;
  });
  expect(cached.length).toBeGreaterThan(10);
  expect(cached.filter((u) => /\/(rest|auth|functions)\//.test(u))).toEqual([]);   // no business data cached

  await page.context().setOffline(true);
  await page.reload();
  await expect(page.locator(".offline-banner")).toBeVisible();
  await expect(page.locator("#app")).toContainText("إعادة المحاولة");   // shell opens, data does not
  await page.context().setOffline(false);                              // back online → reloads data by itself
  await expect(page.locator(".topbar")).toBeVisible();
  await expect(page.locator(".offline-banner")).toBeHidden();
  await logout();
});

test("no CSP violations and no script errors during the whole session", async () => {
  expect(await page.evaluate(() => window.__csp)).toEqual([]);
  expect(page.errors).toEqual([]);
});
