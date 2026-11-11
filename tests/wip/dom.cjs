const fs = require("node:fs"),
  assert = require("node:assert/strict"),
  crypto = require("node:crypto");
const { JSDOM, VirtualConsole } = require(process.env.JSDOM_PATH || "jsdom");
const fixture = process.env.WIP_FIXTURE
  ? JSON.parse(fs.readFileSync(process.env.WIP_FIXTURE, "utf8"))
  : require("./fixture.cjs");
const errors = [],
  requests = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => {
  if (!e.message.includes("Not implemented: HTMLCanvasElement"))
    errors.push(e.message);
});
const dom = new JSDOM(fs.readFileSync("web/index.html", "utf8"), {
  url: "https://test.invalid/",
  runScripts: "dangerously",
  virtualConsole: vc,
  beforeParse(w) {
    w.TextEncoder = TextEncoder;
    Object.defineProperty(w.crypto, "subtle", {
      value: crypto.webcrypto.subtle,
    });
    w.crypto.randomUUID = crypto.randomUUID;
    w.HTMLDialogElement.prototype.showModal = function () {
      this.open = true;
    };
    w.HTMLDialogElement.prototype.close = function () {
      this.open = false;
    };
    w.confirm = () => true;
    w.fetch = async (url, opt) => {
      if (url.includes("wip_snapshot"))
        return { ok: true, json: async () => structuredClone(fixture) };
      if (url.includes("wip_dispatch")) {
        requests.push(JSON.parse(opt.body));
        return { ok: true, json: async () => ({ ok: true }) };
      }
      return {
        ok: true,
        json: async () => ({
          access_token: "test",
          refresh_token: "test",
          expires_in: 3600,
        }),
      };
    };
  },
});
const w = dom.window,
  d = w.document,
  tick = () => new Promise((r) => setTimeout(r, 30));
const click = async (s) => {
  const el = d.querySelector(s);
  assert(el, "Missing " + s);
  el.click();
  await tick();
};
const set = (s, v) => {
  d.querySelector(s).value = v;
};
const submit = async (s) => {
  d.querySelector(s).dispatchEvent(
    new w.Event("submit", { bubbles: true, cancelable: true }),
  );
  await tick();
};
(async () => {
  try {
    set("[name=username]", "test");
    set("[name=password]", "test");
    await submit("[data-form=login]");
    assert(d.querySelector(".nav"));
    await click("[data-act=newOrder]");
    set("#newColor", "أحمر");
    await click("[data-act=addColor]");
    assert(d.querySelector("#colors").textContent.includes("أحمر"));
    set("[name=orderNo]", "TEST");
    await submit("[data-form=order]");
    assert(requests.at(-1).p.colors.includes("أحمر"));
    await click("[data-act=more]");
    await click("[data-nav=dashboard]");
    await w.WIP.Dashboard.verify(fixture);
    const bad = structuredClone(fixture);
    bad.moves[0].qty = 999;
    await assert.rejects(() => w.WIP.Dashboard.verify(bad));
    await click("[data-act=more]");
    await click("[data-nav=settings]");
    await click("[data-act=editTailor]");
    assert(d.querySelector("[name=employeeId]"));
    await click("[data-act=close]");
    await click("[data-act=reset]");
    assert(d.querySelector("[data-confirm]").disabled);
    set("[name=confirmation]", "مسح بيانات الإنتاج");
    d.querySelector("[name=confirmation]").dispatchEvent(
      new w.Event("input", { bubbles: true }),
    );
    assert(!d.querySelector("[data-confirm]").disabled);
    await click("[data-act=close]");
    for (const s of [
      "cutter",
      "tailor",
      "finish1",
      "press",
      "finish2",
      "warehouse",
    ]) {
      const n = d.querySelector('[data-nav="' + s + '"]');
      if (!n) {
        await click("[data-act=more]");
      }
      await click('[data-nav="' + s + '"]');
      assert(d.querySelector("h1"));
      if (s === "tailor" || s === "finish1") {
        await click("[data-tab=active]");
      }
    }
    assert.deepEqual(errors, []);
    console.log(
      "PASS: login, create form, color chips, all station renders, dashboard, SHA-256 verification, edited move rejection, tailor account binding form, reset confirmation guard",
    );
  } finally {
    dom.window.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
