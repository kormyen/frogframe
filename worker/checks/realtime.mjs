import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const mf = new Miniflare(convertV4MiniflareOptions({ workers: [{
  modules: true,
  scriptPath: fileURLToPath(new URL('../src/index.js', import.meta.url)),
  compatibilityDate: '2026-11-09',
  bindings: { VIEWER_TOKEN: 'viewer', ADMIN_TOKEN: 'manager' },
  r2Buckets: ['PHOTOS'],
  durableObjects: { UPDATES: { className: 'PhotoUpdates', useSQLite: true } }
}] }));
let socket;
try {
  assert.equal((await mf.dispatchFetch('https://photos.example/updates', { headers: { Upgrade: 'websocket' } })).status, 401);
  const response = await mf.dispatchFetch('https://photos.example/updates', {
    headers: { Authorization: 'Bearer viewer', Upgrade: 'websocket' }
  });
  assert.equal(response.status, 101);
  socket = response.webSocket;
  const messages = [];
  socket.addEventListener('message', event => messages.push(JSON.parse(event.data)));
  socket.accept();
  const waitForCount = async count => {
    const until = Date.now() + 3000;
    while (messages.length < count && Date.now() < until) await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(messages.length, count);
  };
  await waitForCount(1);
  assert.deepEqual(messages[0], { type: 'connected' });
  const upload = await mf.dispatchFetch('https://photos.example/image/test.png', {
    method: 'PUT', headers: { Authorization: 'Bearer manager', 'Content-Type': 'image/png' }, body: 'image bytes'
  });
  assert.equal(upload.status, 201);
  await waitForCount(2);
  assert.deepEqual(messages[1], { type: 'changed' });
  const manifest = await mf.dispatchFetch('https://photos.example/manifest', { headers: { Authorization: 'Bearer viewer' } });
  assert.equal((await manifest.json()).images.length, 1);
  assert.equal((await mf.dispatchFetch('https://photos.example/image/test.png', {
    method: 'DELETE', headers: { Authorization: 'Bearer manager' }
  })).status, 204);
  await waitForCount(3);
  assert.deepEqual(messages[2], { type: 'changed' });
  const empty = await mf.dispatchFetch('https://photos.example/manifest', { headers: { Authorization: 'Bearer viewer' } });
  assert.equal((await empty.json()).images.length, 0);
  const group = '11111111-1111-1111-1111-111111111111';
  const groupAction = (action, body) => mf.dispatchFetch(`https://photos.example/upload-groups/${group}/${action}`, {
    method: 'POST', headers: { Authorization: 'Bearer manager', 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {})
  });
  assert.equal((await groupAction('start')).status, 204);
  await waitForCount(4);
  assert.deepEqual(messages[3], { type: 'upload-started', group });
  for (const key of ['one.png', 'two.png']) {
    assert.equal((await mf.dispatchFetch(`https://photos.example/image/${key}`, {
      method: 'PUT', headers: { Authorization: 'Bearer manager', 'Content-Type': 'image/png', 'X-PhotoTab-Upload-Group': group }, body: key
    })).status, 201);
  }
  await waitForCount(6);
  assert.deepEqual(messages.slice(4), [{ type: 'changed', uploadGroup: group }, { type: 'changed', uploadGroup: group }]);
  assert.equal((await groupAction('finish', { added: 2 })).status, 204);
  await waitForCount(7);
  assert.deepEqual(messages[6], { type: 'upload-finished', group, added: 2 });
  console.log('Local WebSocket, grouped upload, delete and manifest checks passed');
} finally {
  socket?.close();
  await mf.dispose();
}
