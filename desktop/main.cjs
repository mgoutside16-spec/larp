// «Мир Снов для Граней» для Windows: оболочка Electron вокруг мастерской.
// Игры хранятся в профиле пользователя (%APPDATA%\LARP Studio) и не удаляются при обновлении программы.
const {app, BrowserWindow, protocol, ipcMain, shell, net} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {pathToFileURL} = require('node:url');

const SCHEME = 'larp';
const HOST = 'studio';
const WEB_ROOT = path.join(__dirname, 'web');

protocol.registerSchemesAsPrivileged([{
  scheme: SCHEME,
  privileges: {standard: true, secure: true, supportFetchAPI: true, stream: true, corsEnabled: true},
}]);

// Папка с играми остаётся прежней («LARP Studio»), чтобы переименование не потеряло данные.
app.setName('Мир Снов для Граней');
app.setPath('userData', path.join(app.getPath('appData'), 'LARP Studio'));

if (!app.requestSingleInstanceLock()) {
  app.quit();
}

function ffmpegPath() {
  if (process.env.LARP_FFMPEG) return process.env.LARP_FFMPEG;
  if (app.isPackaged && process.platform === 'win32') return path.join(process.resourcesPath, 'ffmpeg.exe');
  return 'ffmpeg';
}

function parseSeconds(text) {
  const m = /(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(text);
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : null;
}

function runFfmpeg(args, onProgress) {
  return new Promise((resolve, reject) => {
    const child = spawn(ffmpegPath(), args, {windowsHide: true});
    let duration = null;
    let tail = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      tail = (tail + chunk).slice(-4000);
      if (duration === null) {
        const d = /Duration:\s*([\d:.]+)/.exec(tail);
        if (d) duration = parseSeconds(d[1]);
      }
      const times = [...chunk.matchAll(/time=\s*([\d:.]+)/g)];
      if (duration && times.length) {
        const t = parseSeconds(times[times.length - 1][1]);
        if (t !== null) onProgress(Math.min(99, (t / duration) * 100));
      }
    });
    child.on('error', reject);
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(`ffmpeg завершился с кодом ${code}: ${tail.split('\n').slice(-3).join(' ')}`)));
  });
}

const LONG_SIDE = 1280;
const videoArgs = (input, output) => [
  '-hide_banner', '-y', '-i', input,
  '-map', '0:v:0', '-map', '0:a:0?',
  '-vf', `scale=w='if(gte(iw,ih),min(${LONG_SIDE},iw),-2)':h='if(gte(iw,ih),-2,min(${LONG_SIDE},ih))'`,
  '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
  '-c:a', 'aac', '-b:a', '96k', '-ac', '2',
  '-movflags', '+faststart', '-map_metadata', '-1',
  output,
];
const audioArgs = (input, output) => [
  '-hide_banner', '-y', '-i', input, '-vn',
  '-c:a', 'aac', '-b:a', '128k', '-map_metadata', '-1',
  output,
];

ipcMain.handle('larp:transcode', async (event, {kind, name, bytes}) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'larp-'));
  const ext = (path.extname(name).slice(1).toLowerCase().replace(/[^a-z0-9]/g, '') || 'bin');
  const input = path.join(dir, `in.${ext}`);
  const outExt = kind === 'video' ? 'mp4' : 'm4a';
  const output = path.join(dir, `out.${outExt}`);
  const job = crypto.randomUUID();
  try {
    fs.writeFileSync(input, Buffer.from(bytes));
    await runFfmpeg(kind === 'video' ? videoArgs(input, output) : audioArgs(input, output),
      (p) => event.sender.send('larp:progress', {job, percent: p}));
    const result = fs.readFileSync(output);
    const base = path.basename(name, path.extname(name)) || 'media';
    return {name: `${base}.${outExt}`, bytes: result.buffer.slice(result.byteOffset, result.byteOffset + result.byteLength)};
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
});

const FILTERS = {
  rpgpack: [{name: 'Игровой пакет', extensions: ['rpgpack']}],
  xlsx: [{name: 'Таблица Excel', extensions: ['xlsx']}],
  pdf: [{name: 'PDF', extensions: ['pdf']}],
  zip: [{name: 'Архив ZIP', extensions: ['zip']}],
};

ipcMain.handle('larp:save', async (event, {name, bytes}) => {
  const safe = path.basename(String(name || 'файл')).replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
  let target;
  if (process.env.LARP_TEST_DOWNLOADS) {
    target = path.join(process.env.LARP_TEST_DOWNLOADS, safe);
  } else {
    const {dialog} = require('electron');
    const win = BrowserWindow.fromWebContents(event.sender);
    const ext = path.extname(safe).slice(1).toLowerCase();
    const result = await dialog.showSaveDialog(win, {
      title: 'Сохранить файл',
      defaultPath: path.join(app.getPath('documents'), safe),
      filters: [...(FILTERS[ext] || []), {name: 'Все файлы', extensions: ['*']}],
    });
    if (result.canceled || !result.filePath) return null;
    target = result.filePath;
  }
  fs.writeFileSync(target, Buffer.from(bytes));
  return target;
});

// Ключ GitHub хранится зашифрованным средствами Windows в папке программы.
const {safeStorage} = require('electron');
const publisher = require('./publish.cjs');
const tokenFile = () => path.join(app.getPath('userData'), 'github-key.bin');
function readToken() {
  try {
    const data = fs.readFileSync(tokenFile());
    return safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(data) : data.toString('utf8');
  } catch { return null; }
}
ipcMain.handle('larp:github-status', () => ({connected: !!readToken(), site: publisher.SITE}));
ipcMain.handle('larp:github-connect', async (_e, token) => {
  const value = String(token || '').trim();
  if (!/^(github_pat_|ghp_)[A-Za-z0-9_]{20,}$/.test(value)) throw new Error('Это не похоже на ключ GitHub. Он начинается с github_pat_.');
  await publisher.checkToken(value);
  const data = safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(value) : Buffer.from(value, 'utf8');
  fs.writeFileSync(tokenFile(), data);
  return true;
});
ipcMain.handle('larp:github-disconnect', () => { fs.rmSync(tokenFile(), {force: true}); return true; });
ipcMain.handle('larp:publish', async (event, pub) => {
  const token = readToken();
  if (!token) throw new Error('Сначала подключите GitHub.');
  const send = (p) => { try { event.sender.send('larp:publish-progress', p); } catch { /* окно закрыто */ } };
  try {
    const result = await publisher.publish(token, pub, send);
    const live = await publisher.waitLive(pub.gameId, pub.version, 8 * 60 * 1000, send);
    return {...result, live};
  } catch (error) {
    throw new Error(error.message);
  }
});

function createWindow() {
  const win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 900,
    minHeight: 600,
    title: 'Мир Снов для Граней',
    icon: path.join(__dirname, 'icon.png'),
    autoHideMenuBar: true,
    backgroundColor: '#f6f4f1',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      spellcheck: false,
    },
  });
  win.setMenuBarVisibility(false);
  win.webContents.setWindowOpenHandler(({url}) => {
    if (/^https?:/i.test(url)) void shell.openExternal(url);
    return {action: 'deny'};
  });
  win.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(`${SCHEME}://${HOST}/`)) {
      event.preventDefault();
      if (/^https?:/i.test(url)) void shell.openExternal(url);
    }
  });
  win.on('close', async (event) => {
    if (win.forceClose) return;
    event.preventDefault();
    let dirty = false;
    try {
      dirty = await win.webContents.executeJavaScript(
        "!!document.querySelector('dialog[open]#record-editor, dialog[open].record-editor') || document.querySelector('#template-panel')?.dataset.dirty==='true'", true);
    } catch { dirty = false; }
    if (dirty) {
      const {dialog} = require('electron');
      const {response} = await dialog.showMessageBox(win, {
        type: 'warning', buttons: ['Остаться', 'Закрыть без сохранения'], defaultId: 0, cancelId: 0,
        title: 'Несохранённые изменения', message: 'Открыт редактор. Несохранённые изменения пропадут.',
      });
      if (response === 0) return;
    }
    win.forceClose = true;
    win.close();
  });
  void win.loadURL(`${SCHEME}://${HOST}/index.html`);
  return win;
}

app.on('second-instance', () => {
  const [win] = BrowserWindow.getAllWindows();
  if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
});

app.whenReady().then(() => {
  protocol.handle(SCHEME, (request) => {
    const url = new URL(request.url);
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
    const file = path.normalize(path.join(WEB_ROOT, rel));
    if (url.host !== HOST || !file.startsWith(WEB_ROOT + path.sep)) {
      return new Response('Not found', {status: 404});
    }
    return net.fetch(pathToFileURL(file).toString());
  });
  if (process.env.LARP_TEST_DOWNLOADS) {
    // Только для автоматических проверок: сохранять скачивания без диалога.
    const {session} = require('electron');
    session.defaultSession.on('will-download', (_e, item) => item.setSavePath(path.join(process.env.LARP_TEST_DOWNLOADS, item.getFilename())));
  }
  createWindow();
});

app.on('window-all-closed', () => app.quit());
