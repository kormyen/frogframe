import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { PhotoUpdates } from './index.js';

const request = (path, token = 'test-secret', method = 'GET') => new Request(`https://photos.example${path}`, {
  method, headers: { Authorization: `Bearer ${token}` }
});

test('updates require authentication and a WebSocket handshake', async () => {
  const env = { VIEWER_TOKEN: 'test-secret', UPDATES: { getByName: () => ({ fetch: async () => new Response('forwarded') }) } };
  assert.equal((await worker.fetch(request('/updates', 'wrong'), env)).status, 401);
  assert.equal((await worker.fetch(request('/updates'), env)).status, 426);
  const response = await worker.fetch(new Request('https://photos.example/updates', {
    headers: { Authorization: 'Bearer test-secret', Upgrade: 'websocket' }
  }), env);
  assert.equal(await response.text(), 'forwarded');
});

test('change notification follows the successful bucket write and never runs for denied writes', async () => {
  const calls = [];
  const env = { VIEWER_TOKEN: 'test-secret', ADMIN_TOKEN: 'admin-secret',
    PHOTOS: { delete: async () => calls.push('deleted'), put: async () => calls.push('uploaded') },
    UPDATES: { getByName: () => ({ fetch: async () => { calls.push('notified'); return new Response(null, { status: 204 }); } }) }
  };
  await worker.fetch(request('/image/a.png', 'test-secret', 'DELETE'), env);
  assert.deepEqual(calls, []);
  await worker.fetch(request('/image/a.png', 'admin-secret', 'DELETE'), env);
  assert.deepEqual(calls, ['deleted', 'notified']);
  calls.length = 0;
  await worker.fetch(new Request('https://photos.example/image/a.png', {
    method: 'PUT', headers: { Authorization: 'Bearer admin-secret', 'Content-Type': 'image/png' }, body: 'image'
  }), env);
  assert.deepEqual(calls, ['uploaded', 'notified']);
  calls.length = 0;
  env.PHOTOS.put = async () => { throw new Error('Write failed'); };
  await assert.rejects(worker.fetch(new Request('https://photos.example/image/a.png', {
    method: 'PUT', headers: { Authorization: 'Bearer admin-secret', 'Content-Type': 'image/png' }, body: 'image'
  }), env));
  assert.deepEqual(calls, []);
});

test('notification fan-out tolerates a disconnected tablet and rejects client messages', async () => {
  const messages = [];
  const closed = [];
  const hub = new PhotoUpdates({ getWebSockets: () => [
    { send: () => { throw new Error('Closed'); }, close: () => {} },
    { send: message => messages.push(JSON.parse(message)) }
  ] });
  assert.equal((await hub.fetch(new Request('https://updates/publish', { method: 'POST' }))).status, 204);
  assert.deepEqual(messages, [{ type: 'changed' }]);
  hub.webSocketMessage({ close: code => closed.push(code) }, 'publish');
  assert.deepEqual(closed, [1008]);
});
test('rejects missing configuration and invalid tokens before bucket access', async () => {
  assert.equal((await worker.fetch(request('/manifest'), {})).status, 503);
  assert.equal((await worker.fetch(request('/manifest', 'wrong'), { VIEWER_TOKEN: 'test-secret' })).status, 401);
});
test('lists only images, encodes keys and carries pagination cursor', async () => {
  let options;
  const env = { VIEWER_TOKEN: 'test-secret', PHOTOS: { list: async value => {
    options = value;
    return { objects: [{ key: 'family/été #1.JPG', etag: 'abc' }, { key: 'notes.txt' }], truncated: true, cursor: 'next-page' };
  } } };
  const response = await worker.fetch(request('/manifest?cursor=previous'), env);
  const body = await response.json();
  assert.equal(options.cursor, 'previous');
  assert.equal(body.cursor, 'next-page');
  assert.deepEqual(body.images, [{ key: 'family/été #1.JPG', url: 'https://photos.example/image/family/%C3%A9t%C3%A9%20%231.JPG?v=abc' }]);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
});

test('viewer cannot upload or delete; manager can upload and delete encoded image keys', async () => {
  const writes = [];
  const env = { VIEWER_TOKEN: 'test-secret', ADMIN_TOKEN: 'admin-secret', PHOTOS: {
    put: async (key, body, options) => writes.push({ key, bytes: [...new Uint8Array(await body.arrayBuffer())], options }),
    delete: async key => writes.push({ deleted: key })
  } };
  assert.equal((await worker.fetch(request('/image/a.png', 'test-secret', 'DELETE'), env)).status, 403);
  assert.equal((await worker.fetch(request('/image/a.png', 'test-secret', 'PUT'), env)).status, 403);
  assert.equal(writes.length, 0);
  const upload = new Request('https://photos.example/image/folder/a%20b.png', {
    method: 'PUT', headers: { Authorization: 'Bearer admin-secret', 'Content-Type': 'image/png' }, body: new Uint8Array([1, 2, 3])
  });
  assert.equal((await worker.fetch(upload, env)).status, 201);
  assert.equal(writes[0].key, 'folder/a b.png');
  assert.deepEqual(writes[0].bytes, [1, 2, 3]);
  assert.equal((await worker.fetch(request('/image/folder/a%20b.png', 'admin-secret', 'DELETE'), env)).status, 204);
  assert.equal(writes[1].deleted, 'folder/a b.png');
});

test('manager upload rejects empty bodies, non-images and oversized declared bodies', async () => {
  const env = { VIEWER_TOKEN: 'test-secret', ADMIN_TOKEN: 'admin-secret' };
  for (const [body, type, size, expected] of [
    ['', 'image/png', null, 400], ['abc', 'text/plain', null, 415], ['abc', 'image/png', '41943041', 413]
  ]) {
    const headers = { Authorization: 'Bearer admin-secret', 'Content-Type': type };
    if (size) headers['Content-Length'] = size;
    const req = new Request('https://photos.example/image/a.png', { method: 'PUT', headers, body });
    assert.equal((await worker.fetch(req, env)).status, expected);
  }
});
test('streams image bytes and handles removed objects and malformed keys', async () => {
  let key;
  const env = { VIEWER_TOKEN: 'test-secret', PHOTOS: { get: async value => {
    key = value;
    return value === 'missing.jpg' ? null : {
      body: new Uint8Array([1, 2, 3]), httpEtag: '"abc"',
      writeHttpMetadata: headers => headers.set('Content-Type', 'image/jpeg')
    };
  } } };
  const response = await worker.fetch(request('/image/family/%C3%A9t%C3%A9%20%231.JPG?v=abc'), env);
  assert.equal(key, 'family/été #1.JPG');
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [1, 2, 3]);
  assert.equal(response.headers.get('Content-Type'), 'image/jpeg');
  assert.equal((await worker.fetch(request('/image/missing.jpg'), env)).status, 404);
  assert.equal((await worker.fetch(request('/image/%ZZ.jpg'), env)).status, 400);
  assert.equal((await worker.fetch(request('/image/private.txt'), env)).status, 404);
  assert.equal((await worker.fetch(request('/manifest', 'test-secret', 'POST'), env)).status, 405);
});

test('upload group messages require management access and validate the final count', async () => {
  const events = [];
  const group = '11111111-1111-1111-1111-111111111111';
  const env = { VIEWER_TOKEN: 'test-secret', ADMIN_TOKEN: 'admin-secret',
    PHOTOS: { put: async () => {} },
    UPDATES: { getByName: () => ({ fetch: async (_url, options) => {
      events.push(JSON.parse(options.body)); return new Response(null, { status: 204 });
    } }) }
  };
  const action = (step, token = 'admin-secret', added = 3) => new Request(`https://photos.example/upload-groups/${group}/${step}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ added })
  });
  assert.equal((await worker.fetch(action('start', 'test-secret'), env)).status, 403);
  assert.equal(events.length, 0);
  assert.equal((await worker.fetch(action('start'), env)).status, 204);
  assert.equal((await worker.fetch(new Request('https://photos.example/image/a.png', {
    method: 'PUT', headers: { Authorization: 'Bearer admin-secret', 'Content-Type': 'image/png', 'X-PhotoTab-Upload-Group': group }, body: 'image'
  }), env)).status, 201);
  assert.equal((await worker.fetch(action('finish'), env)).status, 204);
  assert.deepEqual(events, [{ type: 'upload-started', group }, { type: 'changed', uploadGroup: group }, { type: 'upload-finished', group, added: 3 }]);
  for (const count of [-1, 1.5, '3', null, 100001]) assert.equal((await worker.fetch(action('finish', 'admin-secret', count), env)).status, 400);
  assert.equal(events.length, 3);
  assert.equal((await worker.fetch(action('start'), { ...env, UPDATES: null })).status, 503);
});
