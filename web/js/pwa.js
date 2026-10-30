// Installable app (PWA): service worker, connection status, and the install prompt.
import { h } from "./dom.js";

let deferredPrompt = null;
const listeners = new Set();

export function initPwa() {
  if ("serviceWorker" in navigator && window.isSecureContext) {
    navigator.serviceWorker.register("sw.js", { scope: "./" }).catch(() => undefined);
  }
  window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferredPrompt = e;
    listeners.forEach((fn) => fn());
  });
  window.addEventListener("appinstalled", () => { deferredPrompt = null; listeners.forEach((fn) => fn()); });

  // Offline notice: operations are never queued offline — the database must confirm every one.
  const banner = h("div", { class: "offline-banner hidden", attrs: { role: "status" },
    text: "لا يوجد اتصال بالإنترنت. لا تُعرض البيانات ولا تُحفظ أي عملية حتى يعود الاتصال." });
  document.body.prepend(banner);
  const update = () => banner.classList.toggle("hidden", navigator.onLine);
  window.addEventListener("offline", update);
  window.addEventListener("online", () => { update(); window.dispatchEvent(new CustomEvent("refresh")); });
  update();
}

export const isInstalled = () => window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

/** "Install app" section for the account page (Android/desktop prompt, iPhone instructions). */
export function installCard() {
  const box = h("section", { class: "card w-narrow" });
  const draw = () => {
    if (isInstalled()) return box.replaceChildren(h("h2", { text: "التطبيق" }), h("p", { class: "muted", text: "التطبيق مثبت على هذا الجهاز." }));
    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
    const button = deferredPrompt ? h("button", { attrs: { type: "button" }, text: "تثبيت التطبيق", onclick: async () => {
      const p = deferredPrompt; deferredPrompt = null;
      await p.prompt(); await p.userChoice.catch(() => undefined); draw();
    } }) : null;
    box.replaceChildren(h("h2", { text: "تثبيت التطبيق" }),
      h("p", { class: "muted", text: ios
        ? "في Safari: اضغط زر المشاركة ثم «إضافة إلى الشاشة الرئيسية»."
        : button ? "ثبّت النظام كتطبيق على هذا الجهاز ليفتح من الشاشة الرئيسية بملء الشاشة."
          : "من قائمة المتصفح اختر «تثبيت التطبيق» أو «إضافة إلى الشاشة الرئيسية»." }),
      button);
  };
  listeners.add(draw);
  draw();
  return box;
}
