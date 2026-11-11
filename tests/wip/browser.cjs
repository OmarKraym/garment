const fs = require("node:fs");
const assert = require("node:assert/strict");
const { chromium } = require(
  process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES
    ? process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES + "/playwright"
    : "playwright",
);
const fixture = process.env.WIP_FIXTURE
  ? JSON.parse(fs.readFileSync(process.env.WIP_FIXTURE, "utf8"))
  : require("./fixture.cjs");
(async () => {
  const b = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROMIUM_PATH || "/usr/bin/chromium",
    args: ["--no-sandbox"],
  });
  let passed = [];
  try {
    for (const width of [390, 1440]) {
      const context = await b.newContext({ viewport: { width, height: 900 } });
      const p = await context.newPage();
      const errors = [];
      p.on("pageerror", (e) => errors.push(e.message));
      let requests = [];
      await context.route("https://*.supabase.co/**", async (route) => {
        const req = route.request();
        let response = {};
        if (req.url().includes("wip_snapshot")) response = fixture;
        else if (req.url().includes("wip_dispatch")) {
          requests.push(req.postDataJSON());
          response = { ok: true };
        } else if (req.url().includes("/token"))
          response = {
            access_token: "test",
            refresh_token: "test",
            expires_in: 3600,
          };
        return route.fulfill({
          contentType: "application/json",
          body: JSON.stringify(response),
        });
      });
      await p.goto("http://127.0.0.1:8080");
      await p.locator("[name=username]").fill("test");
      await p.locator("[name=password]").fill("test");
      await p.locator("form button").click();
      await p.locator(".nav").waitFor();
      assert.equal(await p.locator("html").getAttribute("dir"), "rtl");
      assert(
        await p.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      );
      await p.locator("[data-act=newOrder]").click();
      await p.locator("[name=orderNo]").fill("TEST-001");
      await p.locator("[name=note]").fill("<img src=x onerror=alert(1)>");
      await p.locator("#newColor").fill("أحمر");
      await p.locator("[data-act=addColor]").click();
      assert(
        await p
          .locator("#colors")
          .textContent()
          .then((t) => t.includes("أحمر")),
      );
      await p.locator("[data-form=order] button.primary").click();
      await p.waitForFunction(() => !document.querySelector("dialog").open);
      assert(requests.at(-1).p.colors.includes("أحمر"));
      passed.push(width + ": login, order form, RTL, no horizontal overflow");
      await p.locator("[data-act=more]").click();
      await p.locator("[data-nav=dashboard]").click();
      await p.locator("[data-act=verify]").click();
      await p.waitForFunction(() =>
        document.querySelector("#toast").textContent.includes("سليمة"),
      );
      assert(
        await p.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      );
      passed.push(width + ": audit hash verification and responsive dashboard");
      await p.locator("[data-act=more]").click();
      await p.locator("[data-nav=settings]").click();
      await p.locator("[data-act=reset]").click();
      assert(await p.locator("[data-confirm]").isDisabled());
      await p.locator("[name=confirmation]").fill("wrong");
      assert(await p.locator("[data-confirm]").isDisabled());
      await p.locator("[name=confirmation]").fill("مسح بيانات الإنتاج");
      assert(await p.locator("[data-confirm]").isEnabled());
      await p.locator("[data-act=close]").click();
      passed.push(width + ": destructive action confirmation guard");
      if (fixture.orders.length) {
        await p.locator("[data-nav=cutter]").click();
        await p.locator("[data-act=cut]").first().click();
        const c = fixture.orders[0];
        await p.locator("[data-pick=size]").first().click();
        assert.equal(
          Number(await p.locator("[name=qty]").inputValue()),
          fixture.lots
            .filter(
              (l) =>
                l.orderId === c.id &&
                l.size === c.sizes[0] &&
                l.color === c.colors[0],
            )
            .reduce((s, l) => s + l.qty, 0),
        );
        await p.locator("[data-act=close]").click();
      }
      await p.screenshot({
        path: "/tmp/garment-" + width + ".png",
        fullPage: true,
      });
      assert.deepEqual(errors, []);
      await p.evaluate(() => navigator.serviceWorker.ready);
      await p.reload();
      await p.locator(".nav").waitFor();
      await context.setOffline(true);
      await p.reload();
      await p.locator("[data-form=login]").waitFor();
      assert(await p.title().then((t) => t.includes("عهدة")));
      passed.push(
        width + ": cached shell reloads offline; no private production cache",
      );
      await context.close();
    }
    console.log(JSON.stringify({ passed }, null, 2));
  } finally {
    await b.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
