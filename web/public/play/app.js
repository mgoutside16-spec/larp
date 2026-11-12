// «Мир Снов» — веб-игрок для iPhone и любых телефонов без Android-приложения.
// Игры скачиваются с сайта мастерской, хранятся на телефоне и работают без интернета.
'use strict';

const GAMES = new URL('../games/', location.href).href;
const DATA = 'mir-snov-data';
const MEDIA = 'mir-snov-media';
const KEY = 'mir-snov-state';
const LOCK_MS = 30 * 60 * 1000;
const app = document.getElementById('app');

let state = loadState();
let screen = {name: 'home'};
let syncing = false;
let syncText = '';
let syncPercent = null;

function loadState() {
  try { return {installed: {}, profiles: {}, locks: {}, ...JSON.parse(localStorage.getItem(KEY) || '{}')}; }
  catch { return {installed: {}, profiles: {}, locks: {}}; }
}
function saveState() { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch { /* память переполнена */ } }

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
let toastTimer;
function toast(text) {
  const el = document.getElementById('toast');
  el.textContent = text; el.className = 'visible';
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.className = ''; }, 5000);
}
const standalone = () => navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
const isIOS = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const mimeOf = (path) => ({png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', bmp: 'image/bmp',
  mp3: 'audio/mpeg', wav: 'audio/wav', ogg: 'audio/ogg', m4a: 'audio/mp4', flac: 'audio/flac',
  mp4: 'video/mp4', webm: 'video/webm', mov: 'video/quicktime'})[(path.split('.').pop() || '').toLowerCase()] || 'application/octet-stream';
const mb = (n) => (n / 1024 / 1024).toFixed(1).replace('.', ',');

// ---------- Данные ----------
async function fetchJson(url) {
  const response = await fetch(`${url}?t=${Date.now()}`, {cache: 'no-store'});
  if (response.status === 404) return null;
  if (!response.ok) throw new Error('Сайт мастерской временно недоступен.');
  return response.json();
}
async function installedSnapshot(id) {
  const cached = await (await caches.open(DATA)).match(`${GAMES}${id}/installed.json`);
  return cached ? cached.json() : null;
}
async function sha256Hex(buffer) {
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function download(url, size, onBytes) {
  const response = await fetch(`${url}?download=1`, {cache: 'no-store'});
  if (!response.ok) throw new Error('Не удалось скачать материал. Проверьте интернет.');
  if (!response.body) { const b = await response.arrayBuffer(); onBytes(b.byteLength); return b; }
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    chunks.push(value); received += value.length; onBytes(value.length);
    if (received > size) throw new Error('Файл материала повреждён.');
  }
  const out = new Uint8Array(received);
  let offset = 0;
  for (const c of chunks) { out.set(c, offset); offset += c.length; }
  return out.buffer;
}

async function installGame(row, onProgress) {
  const id = row.game_id;
  const snap = await fetchJson(`${GAMES}${id}/snapshot.json`);
  if (!snap || snap.game_id !== id || !snap.manifest || !Array.isArray(snap.files)) throw new Error(`Игра «${row.name}» опубликована не полностью. Попробуйте позже.`);
  const media = await caches.open(MEDIA);
  const total = snap.files.reduce((s, f) => s + f.size, 0) || 1;
  let done = 0;
  const wanted = new Set();
  for (const file of snap.files) {
    const url = `${GAMES}${file.storage_path}`;
    wanted.add(url);
    const cached = await media.match(url);
    if (cached && Number(cached.headers.get('Content-Length')) === file.size) { done += file.size; onProgress(done / total); continue; }
    const buffer = await download(url, file.size, (n) => { done += n; onProgress(Math.min(done / total, 0.99)); });
    if (buffer.byteLength !== file.size || (file.sha256 && await sha256Hex(buffer) !== file.sha256)) {
      throw new Error('Материал скачался с ошибкой. Повторите загрузку.');
    }
    await media.put(url, new Response(new Blob([buffer], {type: mimeOf(file.path)}), {headers: {
      'Content-Type': mimeOf(file.path), 'Content-Length': String(file.size)}}));
  }
  // Все файлы на месте — переключаемся на новую версию.
  await (await caches.open(DATA)).put(`${GAMES}${id}/installed.json`, new Response(JSON.stringify(snap), {headers: {'Content-Type': 'application/json'}}));
  for (const request of await media.keys()) {
    if (request.url.startsWith(`${GAMES}${id}/`) && !wanted.has(request.url)) await media.delete(request);
  }
  state.installed[id] = {name: row.name, description: row.description || '', version: snap.version, records: snap.manifest.records.length};
  saveState();
}

const refresh = () => { if (screen.name === 'home') render(); };
async function sync(manual = false) {
  if (syncing) return;
  syncing = true; syncText = 'Проверяем игры…'; syncPercent = null; refresh();
  let failure = null;
  try {
    const catalog = await fetchJson(`${GAMES}catalog.json`) || [];
    if (!Array.isArray(catalog)) throw new Error('Список игр повреждён.');
    state.catalog = catalog.map((r) => ({game_id: r.game_id, name: r.name, description: r.description, version: r.version}));
    saveState();
    for (const row of catalog) {
      if ((state.installed[row.game_id]?.version || 0) >= row.version) continue;
      syncText = `Загружаем «${row.name}»…`; syncPercent = 0; refresh();
      try {
        await installGame(row, (p) => { syncPercent = p; updateProgress(); });
      } catch (error) { failure = error.message; }
    }
  } catch {
    failure = 'Нет связи с сайтом мастерской. Скачанные игры работают без интернета.';
  }
  syncing = false; syncPercent = null;
  syncText = failure || 'Игры и материалы обновлены. Можно играть без интернета.';
  if (manual || failure) toast(syncText);
  refresh();
}

// ---------- Коды ----------
function lockInfo(id) {
  const lock = state.locks[id] || {wrong: 0, until: 0};
  if (lock.until && lock.until <= Date.now()) { lock.until = 0; lock.wrong = 0; state.locks[id] = lock; saveState(); }
  return lock;
}
async function openCode(id, code) {
  const lock = lockInfo(id);
  if (lock.until > Date.now()) return {error: lockedText(lock)};
  const snap = await installedSnapshot(id);
  if (!snap) return {error: 'Игра ещё не скачана. Подключитесь к интернету.'};
  const record = snap.manifest.records.find((r) => r.code === code);
  if (record) { lock.wrong = 0; state.locks[id] = lock; saveState(); return {record}; }
  lock.wrong = (lock.wrong || 0) + 1;
  if (lock.wrong >= 3) { lock.until = Date.now() + LOCK_MS; lock.wrong = 0; state.locks[id] = lock; saveState(); return {error: lockedText(lock)}; }
  state.locks[id] = lock; saveState();
  return {error: `Код не найден. Осталось попыток: ${3 - lock.wrong}.`};
}
function lockedText(lock) {
  const left = Math.max(0, lock.until - Date.now());
  const m = Math.floor(left / 60000), s = Math.floor((left % 60000) / 1000);
  return `Три неверных кода. Повторите через ${m}:${String(s).padStart(2, '0')}.`;
}

// ---------- Показ материалов ----------
const ALLOWED = new Set(['P', 'BR', 'H1', 'H2', 'H3', 'H4', 'B', 'STRONG', 'I', 'EM', 'U', 'UL', 'OL', 'LI', 'BLOCKQUOTE', 'DIV', 'SPAN']);
function safeHtml(html) {
  const doc = new DOMParser().parseFromString(`<div>${html}</div>`, 'text/html');
  const clean = (node) => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType === 1) {
        if (!ALLOWED.has(child.tagName)) { child.replaceWith(document.createTextNode(child.textContent)); continue; }
        for (const attr of [...child.attributes]) child.removeAttribute(attr.name);
        clean(child);
      } else if (child.nodeType !== 3) child.remove();
    }
  };
  const root = doc.body.firstChild;
  clean(root);
  return root.innerHTML;
}
function blockHtml(id, block) {
  if (block.kind === 'text') return `<div>${safeHtml(block.value)}</div>`;
  const url = `${GAMES}${id}/${block.value.split('/').map(encodeURIComponent).join('/')}`;
  if (block.kind === 'image') return `<img src="${esc(url)}" alt="">`;
  if (block.kind === 'audio') return `<audio controls preload="metadata" src="${esc(url)}"></audio>`;
  if (block.kind === 'video') return `<video controls playsinline preload="metadata" src="${esc(url)}"></video>`;
  return '';
}

// ---------- Экраны ----------
function updateProgress() {
  const bar = document.querySelector('.progress > div');
  if (bar && syncPercent !== null) bar.style.width = `${Math.round(syncPercent * 100)}%`;
  const label = document.getElementById('sync-text');
  if (label && syncPercent !== null) label.textContent = `${syncText} ${Math.round(syncPercent * 100)}%`;
}

function installHint() {
  if (standalone()) return '';
  return `<section class="card warn"><strong>Сначала добавьте приложение на экран «Домой».</strong>
    ${isIOS() ? `<ol class="steps small"><li>Нажмите в Safari кнопку «Поделиться» (квадрат со стрелкой вверх).</li><li>Выберите «На экран „Домой“» → «Добавить».</li><li>Закройте Safari и откройте значок «Мир Снов».</li></ol>`
      : '<p class="small">В меню браузера выберите «Добавить на главный экран», затем откройте приложение со значка.</p>'}
    <p class="small muted">Без этого телефон может удалить скачанную игру.</p></section>`;
}

function render() {
  if (screen.name === 'home') return renderHome();
  if (screen.name === 'name') return renderName();
  if (screen.name === 'code') return renderCode();
  if (screen.name === 'record') return renderRecord();
}

function renderHome() {
  const rows = new Map();
  for (const row of state.catalog || []) rows.set(row.game_id, row);
  for (const [id, g] of Object.entries(state.installed)) if (!rows.has(id)) rows.set(id, {game_id: id, name: g.name, version: g.version});
  const list = [...rows.values()].map((row) => {
    const local = state.installed[row.game_id];
    const status = !local ? 'Ещё не скачана' : local.version < row.version ? 'Есть обновление' : 'Скачана · работает без интернета';
    return `<button class="game" data-game="${esc(row.game_id)}" ${local ? '' : 'disabled'}><span><b>${esc(row.name)}</b><small>${esc(status)}</small></span><span>›</span></button>`;
  }).join('');
  app.innerHTML = `<div class="topbar"><h1>Мир Снов</h1></div>
    ${installHint()}
    <section class="card"><p id="sync-text" class="small ${syncing ? '' : 'muted'}">${esc(syncText || (navigator.onLine ? '' : 'Нет интернета. Скачанные игры доступны.'))}</p>
      ${syncing && syncPercent !== null ? '<div class="progress"><div></div></div>' : ''}
      <button class="wide" data-action="sync" ${syncing ? 'disabled' : ''}>${syncing ? 'Загружаем…' : 'Проверить обновления'}</button></section>
    <h2>Ваши игры</h2>
    ${list || '<p class="muted">Мастер пока не опубликовал игры. Подключитесь к интернету и нажмите «Проверить обновления».</p>'}`;
  updateProgress();
}

function renderName() {
  const id = screen.game, current = state.profiles[id] || '';
  app.innerHTML = `<div class="topbar"><h1>${esc(state.installed[id]?.name)}</h1><button class="link" data-action="home">Игры</button></div>
    <section class="card"><h2>Как зовут вашего персонажа?</h2>
    <input class="text" id="char-name" maxlength="100" value="${esc(current)}" placeholder="Имя персонажа" autocomplete="off">
    <p class="error" id="name-error"></p><button class="primary wide" data-action="save-name">Продолжить</button></section>`;
  document.getElementById('char-name').focus();
}

function renderCode() {
  const id = screen.game, lock = lockInfo(id);
  const locked = lock.until > Date.now();
  app.innerHTML = `<div class="topbar"><h1>${esc(state.installed[id]?.name)}</h1><button class="link" data-action="home">Игры</button></div>
    <p class="muted">Персонаж: ${esc(state.profiles[id])} · <button class="link" data-action="rename">Изменить имя</button></p>
    <section class="card"><h2>Введите код</h2>
      <input class="code" id="code" inputmode="numeric" pattern="[0-9]*" maxlength="5" autocomplete="off" placeholder="•••••" value="${esc(screen.code || '')}" ${locked ? 'disabled' : ''}>
      <p class="error" id="code-error">${esc(locked ? lockedText(lock) : screen.error || '')}</p>
      <button class="primary wide" data-action="open" ${locked ? 'disabled' : ''}>Открыть материал</button>
      <p class="small muted">Пять цифр с игровой карточки.</p></section>`;
  if (locked) setTimeout(() => { if (screen.name === 'code' && screen.game === id) renderCode(); }, 1000);
}

async function renderRecord() {
  const {game, record} = screen;
  app.innerHTML = `<div class="topbar"><button class="link" data-action="back">‹ Ввести другой код</button></div>
    <article class="record"><h2>${esc(record.title)}</h2>${record.blocks.map((b) => blockHtml(game, b)).join('')}</article>
    <button class="wide" data-action="back">Ввести другой код</button>`;
  app.querySelectorAll('img,video,audio').forEach((el) => el.addEventListener('error', () => {
    el.insertAdjacentHTML('afterend', '<p class="error">Не удалось показать материал. Подключитесь к интернету и нажмите «Проверить обновления».</p>');
  }, {once: true}));
}

// ---------- События ----------
app.addEventListener('click', async (event) => {
  const target = event.target.closest('[data-action],[data-game]');
  if (!target) return;
  if (target.dataset.game) {
    const id = target.dataset.game;
    if (!state.installed[id]) return;
    state.selected = id; saveState();
    screen = state.profiles[id] ? {name: 'code', game: id} : {name: 'name', game: id};
    return render();
  }
  const action = target.dataset.action;
  if (action === 'sync') return sync(true);
  if (action === 'home') { screen = {name: 'home'}; return render(); }
  if (action === 'rename') { screen = {name: 'name', game: screen.game}; return render(); }
  if (action === 'back') { screen = {name: 'code', game: screen.game}; return render(); }
  if (action === 'save-name') {
    const value = document.getElementById('char-name').value.trim();
    if (!value || value.length > 100) { document.getElementById('name-error').textContent = 'Введите имя от 1 до 100 символов.'; return; }
    state.profiles[screen.game] = value; saveState();
    screen = {name: 'code', game: screen.game}; return render();
  }
  if (action === 'open') {
    const code = document.getElementById('code').value.trim();
    if (!/^\d{5}$/.test(code)) { document.getElementById('code-error').textContent = 'Введите пять цифр.'; return; }
    const result = await openCode(screen.game, code);
    if (result.record) { screen = {name: 'record', game: screen.game, record: result.record}; return render(); }
    screen = {name: 'code', game: screen.game, error: result.error}; return render();
  }
});
app.addEventListener('keydown', (event) => {
  if (event.key !== 'Enter') return;
  if (event.target.id === 'code') app.querySelector('[data-action="open"]')?.click();
  if (event.target.id === 'char-name') app.querySelector('[data-action="save-name"]')?.click();
});
app.addEventListener('input', (event) => {
  if (event.target.id === 'code') event.target.value = event.target.value.replace(/\D/g, '').slice(0, 5);
});
window.addEventListener('online', () => sync());
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && navigator.onLine && screen.name === 'home') sync(); });

(async function start() {
  if ('serviceWorker' in navigator) {
    try { await navigator.serviceWorker.register('sw.js'); } catch { /* офлайн-режим недоступен */ }
  }
  try { if (navigator.storage?.persist) await navigator.storage.persist(); } catch { /* не поддерживается */ }
  if (state.selected && state.installed[state.selected]) {
    screen = state.profiles[state.selected] ? {name: 'code', game: state.selected} : {name: 'name', game: state.selected};
  }
  render();
  if (navigator.onLine) sync();
})();
