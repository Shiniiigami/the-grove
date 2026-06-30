/* The Grove — service worker
   - network-first for the app shell so the newest build always wins (kills stale installs)
   - cached fallback so the app still opens with no signal
   - push + notificationclick handlers (used once push is wired on the backend)
   Bump VERSION every build so old caches are cleared and the new worker takes over.
*/
const VERSION = 'grove-2026-06-30ar';
const SHELL = ['./', './index.html', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL).catch(() => {})));
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (e) => {
  if (e.data === 'skipWaiting') self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch (_) { return; }
  // never touch cross-origin (Supabase API, Google Fonts, CDNs) — let them go straight to network
  if (url.origin !== self.location.origin) return;

  const isNav = req.mode === 'navigate' || url.pathname.endsWith('/') || url.pathname.endsWith('index.html');

  if (isNav) {
    // network-first: always try the freshest build, fall back to cache only when offline
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        const c = await caches.open(VERSION);
        c.put('./index.html', fresh.clone());
        c.put('./', fresh.clone());
        return fresh;
      } catch (err) {
        const cached = (await caches.match('./index.html')) || (await caches.match('./'));
        return cached || new Response('<h1>Offline</h1><p>The Grove will load once you have signal.</p>', { status: 503, headers: { 'Content-Type': 'text/html' } });
      }
    })());
    return;
  }

  // other same-origin assets (audio, icons): stale-while-revalidate
  e.respondWith((async () => {
    const cached = await caches.match(req);
    const fetchP = fetch(req).then(res => {
      try { if (res && res.ok) caches.open(VERSION).then(c => c.put(req, res.clone())); } catch (_) {}
      return res;
    }).catch(() => null);
    return cached || (await fetchP) || new Response('', { status: 504 });
  })());
});

/* ===== push (active once the backend sends pushes) ===== */
self.addEventListener('push', (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; }
  catch (_) { try { data = { title: 'The Grove', body: e.data && e.data.text() }; } catch (__) {} }
  // The backend brands every push by tacking " from The Grove" onto the title,
  // which is redundant with the app icon and wraps awkwardly on the lock screen.
  // Strip that suffix so the title stays one clean category line ("\ud83d\udcdc A new deed").
  let title = (data.title || 'The Grove')
    .replace(/\s*(?:[\u2014\u2013-]\s*)?from the grove\b[.!]?\s*$/i, '')
    .trim() || 'The Grove';
  const opts = {
    body: data.body || '',
    icon: data.icon || './icon-192.png',
    badge: data.badge || './icon-192.png',
    tag: data.tag || 'grove',
    renotify: true,
    data: { url: data.url || './' }
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil((async () => {
    const all = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if ('focus' in c) { try { c.navigate(url); } catch (_) {} return c.focus(); }
    }
    if (clients.openWindow) return clients.openWindow(url);
  })());
});
