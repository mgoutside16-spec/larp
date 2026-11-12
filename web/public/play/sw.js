// Офлайн-игрок «Мир Снов»: оболочка приложения и скачанные материалы игр.
const SHELL = 'mir-snov-shell-3';
const MEDIA = 'mir-snov-media';
const SHELL_FILES = ['./', './index.html', './app.js', './app.css', './manifest.webmanifest',
  './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith('mir-snov-shell-') && k !== SHELL).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

function rangeResponse(request, blob, type) {
  const size = blob.size;
  const base = {'Content-Type': type, 'Accept-Ranges': 'bytes'};
  const header = request.headers.get('range');
  if (!header) return new Response(blob, {status: 200, headers: {...base, 'Content-Length': String(size)}});
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return new Response(null, {status: 416, headers: {'Content-Range': `bytes */${size}`}});
  let start, end;
  if (m[1] === '') { start = Math.max(size - Number(m[2]), 0); end = size - 1; }
  else { start = Number(m[1]); end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1); }
  if (start >= size || start > end) return new Response(null, {status: 416, headers: {'Content-Range': `bytes */${size}`}});
  return new Response(blob.slice(start, end + 1, type), {status: 206, headers: {
    ...base, 'Content-Length': String(end - start + 1), 'Content-Range': `bytes ${start}-${end}/${size}`}});
}

async function serveMedia(request) {
  const url = new URL(request.url);
  url.search = '';
  const cached = await (await caches.open(MEDIA)).match(url.href);
  if (cached) {
    const blob = await cached.blob();
    return rangeResponse(request, blob, cached.headers.get('Content-Type') || blob.type || 'application/octet-stream');
  }
  return fetch(request);
}

async function serveShell(request) {
  const cache = await caches.open(SHELL);
  const cached = await cache.match(request, {ignoreSearch: true});
  if (cached) return cached;
  try { return await fetch(request); }
  catch (error) {
    if (request.mode === 'navigate') { const index = await cache.match('./index.html'); if (index) return index; }
    throw error;
  }
}

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || event.request.method !== 'GET') return;
  const scope = new URL(self.registration.scope);
  if (/\/games\/[0-9a-f-]{36}\/media\//.test(url.pathname)) {
    if (url.searchParams.has('download')) return; // скачивание при установке игры идёт напрямую
    event.respondWith(serveMedia(event.request));
  } else if (url.pathname.startsWith(scope.pathname)) {
    event.respondWith(serveShell(event.request));
  }
});
