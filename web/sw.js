// Service worker: makes the app installable and lets the SCREENS open without a network.
// Security rules:
//  - Only this site's own static files are cached. Business data is NEVER cached
//    (shared factory phones), and requests to Supabase (data, sign-in, Edge Functions) are not touched.
//  - Network first: every update reaches users as soon as they are online; the cache is only a fallback.
//  - Nothing is written while offline: the database is the only source of truth.
const VERSION = "2026-10-30.10";
const CACHE = `garment-shell-${VERSION}`;
const SHELL = [
  "", "index.html", "manifest.webmanifest", "css/app.css",
  "vendor/supabase-2.118.0.js",
  "js/api.js", "js/app.js", "js/config.js", "js/csv.js", "js/dom.js", "js/forms.js", "js/icons.js", "js/labels.js", "js/pwa.js",
  "js/pages/account.js", "js/pages/admin.js", "js/pages/dashboard.js", "js/pages/orders.js", "js/pages/quality.js",
  "js/pages/reports.js", "js/pages/tasks.js", "js/pages/transfers.js", "js/pages/warehouse.js", "js/pages/work.js",
  "icons/icon.svg", "icons/icon-192.png", "icons/icon-512.png", "icons/maskable-512.png", "icons/apple-touch-icon.png",
  "fonts/plex-arabic-arabic-400.woff2", "fonts/plex-arabic-arabic-600.woff2", "fonts/plex-arabic-arabic-700.woff2",
  "fonts/plex-arabic-latin-400.woff2", "fonts/plex-arabic-latin-600.woff2", "fonts/plex-arabic-latin-700.woff2", "fonts/OFL-LICENSE.txt",
];

const scopePath = () => new URL(self.registration.scope).pathname;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL.map((p) => new Request(p, { cache: "reload" })))));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith("garment-shell-") && k !== CACHE) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin || url.search) return;          // Supabase & anything dynamic: untouched
  const rel = url.pathname.startsWith(scopePath()) ? url.pathname.slice(scopePath().length) : null;
  const isPage = req.mode === "navigate";
  if (!isPage && (rel === null || !SHELL.includes(rel))) return;           // only known static files
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const res = await fetch(req);
      if (res.ok && res.type === "basic" && !isPage) await cache.put(req, res.clone());
      return res;
    } catch {
      return (await cache.match(isPage ? "index.html" : req)) ?? Response.error();
    }
  })());
});
