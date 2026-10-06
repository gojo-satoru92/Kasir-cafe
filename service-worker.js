const SHELL_CACHE = "kasir-cafe-shell-v1";
const RUNTIME_CACHE = "kasir-cafe-runtime-v1";
const SHELL_ASSETS = ["./", "./index.html", "./supabase-config.js", "./manifest.webmanifest"];
const THIRD_PARTY_HOSTS = new Set([
  "cdn.jsdelivr.net",
  "unpkg.com",
  "fonts.googleapis.com",
  "fonts.gstatic.com"
]);
const REQUIRED_SCRIPTS = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
  "https://unpkg.com/lucide@latest"
];

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const shell = await caches.open(SHELL_CACHE);
    await shell.addAll(SHELL_ASSETS);
    const runtime = await caches.open(RUNTIME_CACHE);
    await Promise.all(REQUIRED_SCRIPTS.map(async url => {
      try {
        const response = await fetch(url, { mode: "no-cors" });
        if (response.ok || response.type === "opaque") await runtime.put(url, response);
      } catch (error) {
        console.error("Pustaka eksternal belum dapat disimpan untuk offline:", error);
      }
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const cacheNames = await caches.keys();
    await Promise.all(cacheNames
      .filter(name => name.startsWith("kasir-cafe-") && ![SHELL_CACHE, RUNTIME_CACHE].includes(name))
      .map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin === self.location.origin) {
    if (request.mode === "navigate") {
      event.respondWith((async () => {
        try {
          const response = await fetch(request);
          const shell = await caches.open(SHELL_CACHE);
          if (response.ok) await shell.put("./index.html", response.clone());
          return response;
        } catch {
          return (await caches.match("./index.html")) || Response.error();
        }
      })());
    } else {
      event.respondWith((async () => {
        const cached = await caches.match(request);
        if (cached) return cached;
        const response = await fetch(request);
        if (response.ok) {
          const shell = await caches.open(SHELL_CACHE);
          await shell.put(request, response.clone());
        }
        return response;
      })());
    }
    return;
  }

  if (!THIRD_PARTY_HOSTS.has(url.hostname)) return;
  event.respondWith((async () => {
    const runtime = await caches.open(RUNTIME_CACHE);
    const cached = await runtime.match(request);
    if (cached) return cached;
    const response = await fetch(request);
    if (response.ok || response.type === "opaque") await runtime.put(request, response.clone());
    return response;
  })());
});
