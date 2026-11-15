const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('a removed download stays hidden after reload and failed refresh', async () => {
  const source = fs.readFileSync(require.resolve('../web/public/play/app.js'), 'utf8');
  const old = {game_id: '00000000-0000-0000-0000-000000000001', name: 'Removed', version: 1};
  const active = {game_id: '00000000-0000-0000-0000-000000000002', name: 'Active', version: 1};
  let saved = JSON.stringify({selected: old.game_id, catalog: [old, active], installed: {[old.game_id]: old, [active.game_id]: active}});
  function load(status, catalog = [active], withdrawn = null) {
    const element = {innerHTML: '', querySelector: () => null};
    const context = vm.createContext({
      URL, location: {href: 'https://example.test/play/'}, navigator: {}, matchMedia: () => ({matches: false}),
      document: {getElementById: () => element, querySelector: () => null, addEventListener() {}},
      window: {addEventListener() {}}, setTimeout() {}, clearTimeout() {}, setInterval() {},
      localStorage: {getItem: () => saved, setItem: (_, value) => saved = value},
      fetch: async (url) => {
        if (url.includes('withdrawn.json')) {
          return {status: withdrawn ? 200 : 404, ok: !!withdrawn, json: async () => withdrawn};
        }
        return {status, ok: status === 200, json: async () => catalog};
      },
    });
    vm.runInContext(source.slice(0, source.indexOf("app.addEventListener(")), context);
    return {context, element};
  }
  const online = load(200, [active], {[old.game_id]: old.version});
  await vm.runInContext("screen = {name: 'code', game: state.selected}; sync()", online.context);
  assert.doesNotMatch(online.element.innerHTML, /Removed/);
  assert.match(online.element.innerHTML, /Active/);
  assert.ok(JSON.parse(saved).installed[old.game_id]);
  assert.equal(JSON.parse(saved).selected, undefined);
  const restarted = load(404);
  await vm.runInContext('sync()', restarted.context);
  assert.doesNotMatch(restarted.element.innerHTML, /Removed/);
  assert.match(restarted.element.innerHTML, /Active/);
  const outdated = load(200, [old, active]);
  await vm.runInContext('sync()', outdated.context);
  assert.doesNotMatch(outdated.element.innerHTML, /Removed/);
  assert.match(outdated.element.innerHTML, /Active/);
});
const id = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
test('unpublish removes only the selected publication and retries deployment', async (t) => {
  const publisher = require('./publish.cjs');
  let head = 'head';
  let tree = {'catalog.json': 'catalog', [id + '/snapshot.json']: 'snapshot',
    [id + '/media/audio.mp3']: 'audio', [other + '/media/audio.mp3']: 'other-audio', 'app/player.apk': 'apk'};
  const blobs = new Map([['catalog', Buffer.from(JSON.stringify([{game_id: id, version: 4}, {game_id: other, version: 1}]))]]);
  let pending, commits = 0, dispatches = 0;
  t.mock.method(globalThis, 'fetch', async (url, {method, body} = {}) => {
    const endpoint = new URL(url).pathname.split('/repos/mgoutside16-spec/larp')[1];
    const data = body && JSON.parse(body);
    if (endpoint === '') return Response.json({permissions: {push: true}});
    if (endpoint === '/git/ref/heads/games') return Response.json({object: {sha: head}});
    if (endpoint === '/git/commits/' + head) return Response.json({tree: {sha: 'current'}});
    if (endpoint === '/git/trees/current') return Response.json({tree: Object.entries(tree).map(([path, sha]) => ({path, sha, type: 'blob'}))});
    if (endpoint.startsWith('/git/blobs/')) return Response.json({content: blobs.get(endpoint.split('/').at(-1)).toString('base64')});
    if (endpoint === '/git/blobs') {
      const sha = String(blobs.size);
      blobs.set(sha, Buffer.from(data.content, 'base64'));
      return Response.json({sha});
    }
    if (endpoint === '/git/trees') {
      pending = Object.fromEntries(data.tree.map(({path, sha}) => [path, sha]));
      return Response.json({sha: 'next'});
    }
    if (endpoint === '/git/commits') {
      assert.deepEqual(data.parents, [head]);
      commits++;
      return Response.json({sha: 'commit-' + commits});
    }
    if (endpoint === '/git/refs/heads/games' && method === 'PATCH') {
      assert.equal(data.force, false);
      head = data.sha; tree = pending;
      return Response.json({});
    }
    if (endpoint === '/dispatches') {
      assert.equal(data.event_type, 'publish');
      if (++dispatches === 1) return new Response('temporary error', {status: 503});
      return new Response(null, {status: 204});
    }
    throw new Error('Unexpected request: ' + endpoint);
  });
  await assert.rejects(() => publisher.unpublish('token', id), /503/);
  assert.deepEqual(JSON.parse(blobs.get(tree['catalog.json'])), [{game_id: other, version: 1}]);
  assert.deepEqual(JSON.parse(blobs.get(tree['withdrawn.json'])), {[id]: 4});
  assert.equal(tree[id + '/snapshot.json'], undefined);
  assert.equal(tree[id + '/media/audio.mp3'], undefined);
  assert.equal(tree[other + '/media/audio.mp3'], 'other-audio');
  assert.equal(tree['app/player.apk'], 'apk');
  await publisher.unpublish('token', id);
  assert.equal(commits, 1);
  assert.equal(dispatches, 2);
});
