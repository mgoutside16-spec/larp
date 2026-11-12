// Публикация игр для игроков: файлы кладутся в ветку `games` репозитория на GitHub,
// после чего GitHub Actions выкладывает их на GitHub Pages вместе с сайтом.
const crypto = require('node:crypto');

const OWNER = 'mgoutside16-spec';
const REPO = 'larp';
const BRANCH = 'games';
const API = process.env.LARP_TEST_GITHUB_API || 'https://api.github.com';
const SITE = process.env.LARP_TEST_SITE || `https://${OWNER}.github.io/${REPO}/`;

class PublishError extends Error {}

async function gh(token, method, path, body) {
  let response;
  try {
    response = await fetch(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Mir-Snov-dlya-Graney',
        ...(body ? {'Content-Type': 'application/json'} : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new PublishError('Нет связи с GitHub. Проверьте интернет и повторите публикацию.');
  }
  if (response.status === 404 && method === 'GET') return null;
  if (response.status === 401) throw new PublishError('Ключ GitHub не подходит или срок его действия закончился. Подключите GitHub заново.');
  if (response.status === 403 || response.status === 404) {
    throw new PublishError('У ключа GitHub нет права записи в репозиторий larp. Создайте ключ заново по инструкции.');
  }
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new PublishError(`GitHub ответил ошибкой ${response.status}. Повторите позже. ${text.slice(0, 200)}`);
  }
  return response.status === 204 ? null : response.json();
}

async function checkToken(token) {
  const repo = await gh(token, 'GET', `/repos/${OWNER}/${REPO}`);
  if (!repo) throw new PublishError('Репозиторий larp не найден для этого ключа. Проверьте, что при создании ключа выбран репозиторий larp.');
  if (!repo.permissions || !repo.permissions.push) {
    throw new PublishError('У ключа нет права записи. При создании ключа включите «Contents: Read and write».');
  }
  return true;
}

const gitBlobSha = (bytes) => crypto.createHash('sha1')
  .update(`blob ${bytes.length}\0`).update(bytes).digest('hex');

const json = (value) => Buffer.from(`${JSON.stringify(value, null, 1)}\n`, 'utf8');

async function publish(token, pub, onProgress = () => {}) {
  const id = String(pub.gameId).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new PublishError('Некорректный идентификатор игры.');
  onProgress({stage: 'Проверяем доступ к GitHub…', percent: 0});
  await checkToken(token);

  // Что уже опубликовано.
  const ref = await gh(token, 'GET', `/repos/${OWNER}/${REPO}/git/ref/heads/${BRANCH}`);
  const existing = new Map();
  let catalog = [];
  if (ref) {
    const commit = await gh(token, 'GET', `/repos/${OWNER}/${REPO}/git/commits/${ref.object.sha}`);
    const tree = await gh(token, 'GET', `/repos/${OWNER}/${REPO}/git/trees/${commit.tree.sha}?recursive=1`);
    for (const entry of tree.tree || []) if (entry.type === 'blob') existing.set(entry.path, entry.sha);
    const catalogSha = existing.get('catalog.json');
    if (catalogSha) {
      const blob = await gh(token, 'GET', `/repos/${OWNER}/${REPO}/git/blobs/${catalogSha}`);
      try { catalog = JSON.parse(Buffer.from(blob.content, 'base64').toString('utf8')); } catch { catalog = []; }
      if (!Array.isArray(catalog)) catalog = [];
    }
  }
  const knownShas = new Set(existing.values());
  // Версия опубликованной игры только растёт, иначе телефоны не увидят обновление.
  const previous = catalog.find((row) => row && row.game_id === id);
  if (previous && Number(previous.version) >= pub.version) {
    pub.version = Number(previous.version) + 1;
    pub.manifest = {...pub.manifest, version: pub.version};
  }

  // Новое содержимое ветки: всё прежнее, кроме папки этой игры.
  const entries = new Map();
  for (const [path, sha] of existing) {
    if (path === 'catalog.json' || path.startsWith(`${id}/`)) continue;
    entries.set(path, sha);
  }

  const upload = async (bytes) => {
    const sha = gitBlobSha(bytes);
    if (knownShas.has(sha)) return sha;
    const created = await gh(token, 'POST', `/repos/${OWNER}/${REPO}/git/blobs`, {content: Buffer.from(bytes).toString('base64'), encoding: 'base64'});
    if (created.sha !== sha) throw new PublishError('GitHub получил файл с ошибкой. Повторите публикацию.');
    knownShas.add(sha);
    return sha;
  };

  const total = pub.files.reduce((sum, f) => sum + f.bytes.byteLength, 0) || 1;
  let done = 0;
  const files = [];
  for (const file of pub.files) {
    const bytes = Buffer.from(file.bytes);
    onProgress({stage: `Загружаем материалы на GitHub… ${Math.round((done / total) * 100)}%`, percent: (done / total) * 90});
    entries.set(`${id}/${file.path}`, await upload(bytes));
    files.push({path: file.path, storage_path: `${id}/${file.path}`, size: bytes.length, sha256: file.sha256});
    done += bytes.length;
  }
  onProgress({stage: 'Обновляем список игр…', percent: 92});
  const updatedAt = new Date().toISOString();
  entries.set(`${id}/snapshot.json`, await upload(json({game_id: id, project_id: id, version: pub.version, manifest: pub.manifest, files})));
  catalog = catalog.filter((row) => row && row.game_id !== id);
  catalog.push({game_id: id, project_id: id, name: pub.name, description: String(pub.description || '').slice(0, 4000), version: pub.version, record_count: pub.recordCount, updated_at: updatedAt});
  catalog.sort((a, b) => String(a.game_id).localeCompare(String(b.game_id)));
  entries.set('catalog.json', await upload(json(catalog)));

  // Одна свежая версия без истории: ветка не разрастается старыми видео.
  const tree = await gh(token, 'POST', `/repos/${OWNER}/${REPO}/git/trees`, {
    tree: [...entries].map(([path, sha]) => ({path, mode: '100644', type: 'blob', sha})),
  });
  const commit = await gh(token, 'POST', `/repos/${OWNER}/${REPO}/git/commits`, {
    message: `Публикация «${pub.name}», версия ${pub.version}`, tree: tree.sha, parents: [],
  });
  if (ref) await gh(token, 'PATCH', `/repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}`, {sha: commit.sha, force: true});
  else await gh(token, 'POST', `/repos/${OWNER}/${REPO}/git/refs`, {ref: `refs/heads/${BRANCH}`, sha: commit.sha});
  onProgress({stage: 'Файлы отправлены. GitHub выкладывает их на сайт…', percent: 95});
  return {version: pub.version, updatedAt};
}

// Ждём, пока сайт начнёт отдавать новую версию (обычно 1–3 минуты).
async function waitLive(gameId, version, timeoutMs = 8 * 60 * 1000, onProgress = () => {}) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const response = await fetch(`${SITE}games/catalog.json?t=${Date.now()}`, {cache: 'no-store'});
      if (response.ok) {
        const rows = await response.json();
        const row = Array.isArray(rows) && rows.find((r) => r.game_id === gameId.toLowerCase());
        if (row && row.version >= version) return true;
      }
    } catch { /* сайт ещё обновляется или нет сети */ }
    const minutes = Math.floor((Date.now() - started) / 60000);
    onProgress({stage: `GitHub выкладывает игру на сайт… прошло ${minutes} мин.`, percent: 96});
    await new Promise((r) => setTimeout(r, 15000));
  }
  return false;
}

module.exports = {publish, checkToken, waitLive, PublishError, SITE, OWNER, REPO};
