const imageKey = /\.(jpe?g|png|webp|gif|heic|heif|avif)$/i;

async function notifyViewers(env, change = { type: 'changed' }) {
  if (!env.UPDATES) return false;
  try {
    const response = await env.UPDATES.getByName('photos').fetch('https://updates/publish', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(change)
    });
    if (!response.ok) throw new Error('Notification rejected');
    return true;
  } catch {
    // The image operation has already completed. Do not ask the Mac to repeat it.
    console.error('Photo change notification failed');
    return false;
  }
}

export class PhotoUpdates {
  constructor(ctx) { this.ctx = ctx; }
  async fetch(request) {
    if (request.method === 'POST' && new URL(request.url).pathname === '/publish') {
      const change = request.body ? await request.json() : { type: 'changed' };
      for (const socket of this.ctx.getWebSockets()) {
        try { socket.send(JSON.stringify(change)); }
        catch { try { socket.close(1011, 'Reconnect'); } catch {} }
      }
      return new Response(null, { status: 204 });
    }
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('WebSocket required', { status: 426 });
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.send(JSON.stringify({ type: 'connected' }));
    return new Response(null, { status: 101, webSocket: client });
  }
  webSocketMessage(socket) { socket.close(1008, 'Read-only connection'); }
  // The compatibility date enables automatic close-frame replies, including empty close frames.
  webSocketClose() {}
  webSocketError(socket) { try { socket.close(1011, 'Reconnect'); } catch {} }
}

export default {
  async fetch(request, env) {
    if (!env.VIEWER_TOKEN) return new Response('Viewer token is not set', { status: 503 });
    const actual = new TextEncoder().encode(request.headers.get('Authorization') || '');
    const digest = value => crypto.subtle.digest('SHA-256', value);
    const [provided, viewer, admin] = await Promise.all([
      digest(actual), digest(new TextEncoder().encode(`Bearer ${env.VIEWER_TOKEN}`)),
      digest(new TextEncoder().encode(`Bearer ${env.ADMIN_TOKEN || ''}`))
    ]);
    const matches = expected => new Uint8Array(provided).every((byte, i) => byte === new Uint8Array(expected)[i]);
    const canManage = !!env.ADMIN_TOKEN && matches(admin);
    if (!matches(viewer) && !canManage) {
      return new Response('Unauthorized', { status: 401 });
    }
    const url = new URL(request.url);
    const groupRoute = url.pathname.match(/^\/upload-groups\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/(start|finish)$/i);
    if (groupRoute && request.method === 'POST') {
      if (!canManage) return new Response('Read-only token', { status: 403 });
      const group = groupRoute[1].toLowerCase();
      let delivered;
      if (groupRoute[2] === 'start') {
        delivered = await notifyViewers(env, { type: 'upload-started', group });
      } else {
        let body;
        try { body = await request.json(); } catch { return new Response('Invalid summary', { status: 400 }); }
        if (!Number.isInteger(body?.added) || body.added < 0 || body.added > 100000) return new Response('Invalid count', { status: 400 });
        delivered = await notifyViewers(env, { type: 'upload-finished', group, added: body.added });
      }
      if (!delivered) return new Response('Updates unavailable', { status: 503 });
      return new Response(null, { status: 204 });
    }
    if (url.pathname === '/updates' && request.method === 'GET') {
      if (!env.UPDATES) return new Response('Updates unavailable', { status: 503 });
      if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return new Response('WebSocket required', { status: 426 });
      return env.UPDATES.getByName('photos').fetch(request);
    }
    if (url.pathname === '/manifest' && request.method === 'GET') {
      const page = await env.PHOTOS.list({ limit: 1000, cursor: url.searchParams.get('cursor') || undefined });
      return Response.json({
        images: page.objects.filter(o => imageKey.test(o.key)).map(o => ({
          key: o.key,
          size: o.size,
          url: `${url.origin}/image/${o.key.split('/').map(encodeURIComponent).join('/')}?v=${encodeURIComponent(o.etag)}`
        })),
        cursor: page.truncated ? page.cursor : null
      }, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (url.pathname.startsWith('/image/')) {
      let key;
      try { key = decodeURIComponent(url.pathname.slice(7)); }
      catch { return new Response('Invalid key', { status: 400 }); }
      if (!imageKey.test(key)) return new Response('Not found', { status: 404 });
      if (request.method === 'PUT' || request.method === 'DELETE') {
        if (!canManage) return new Response('Read-only token', { status: 403 });
        if (new TextEncoder().encode(key).length > 1024) return new Response('Key is too long', { status: 400 });
        if (request.method === 'DELETE') {
          await env.PHOTOS.delete(key);
          await notifyViewers(env);
          return new Response(null, { status: 204 });
        }
        const maxSize = 40 * 1024 * 1024;
        if (Number(request.headers.get('Content-Length')) > maxSize) return new Response('Image is too large', { status: 413 });
        const reader = request.body?.getReader();
        if (!reader) return new Response('Image is empty', { status: 400 });
        const chunks = []; let size = 0;
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > maxSize) { await reader.cancel(); return new Response('Image is too large', { status: 413 }); }
          chunks.push(value);
        }
        if (!size) return new Response('Image is empty', { status: 400 });
        const contentType = request.headers.get('Content-Type') || 'application/octet-stream';
        if (!contentType.startsWith('image/')) return new Response('Use an image file', { status: 415 });
        const group = request.headers.get('X-PhotoTab-Upload-Group');
        if (group && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(group)) return new Response('Invalid upload group', { status: 400 });
        await env.PHOTOS.put(key, new Blob(chunks), { httpMetadata: { contentType } });
        await notifyViewers(env, group ? { type: 'changed', uploadGroup: group.toLowerCase() } : { type: 'changed' });
        return Response.json({ key }, { status: 201 });
      }
      if (request.method !== 'GET') return new Response('Method not allowed', { status: 405 });
      const object = await env.PHOTOS.get(key);
      if (!object) return new Response('Not found', { status: 404 });
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set('ETag', object.httpEtag);
      headers.set('Cache-Control', 'private, max-age=3600');
      headers.set('X-Content-Type-Options', 'nosniff');
      return new Response(object.body, { headers });
    }
    return new Response(request.method === 'GET' ? 'Not found' : 'Method not allowed', { status: request.method === 'GET' ? 404 : 405 });
  }
};
