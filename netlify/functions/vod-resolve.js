/**
 * vod-resolve.js — Netlify Function
 *
 * Resuelve la URL final de una película VOD usando el mismo self-loop
 * via Netlify CDN que hls-proxy usa para canales en vivo.
 *
 * Flujo:
 *   1. Lambda → /xtream-vod/u/p/id.ext  (CDN proxy, redirect:manual)
 *      CDN IPs no bloqueadas → auth server retorna 302 con TOKEN URL
 *   2. Lambda retorna 302 al browser apuntando a /xtream-vod-media/live/play/TOKEN/id
 *   3. Browser sigue el 302 → CDN → 23.158.40.201:80/live/play/TOKEN/id → MP4
 *
 * Uso: /.netlify/functions/vod-resolve?u=USER&p=PASS&id=STREAM_ID&ext=mp4
 */
exports.handler = async (event) => {
  const { u, p, id, ext = 'mp4' } = event.queryStringParameters || {};

  if (!u || !p || !id) {
    return { statusCode: 400, body: 'Missing params: u, p, id' };
  }

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';

  try {
    // PASO 1: Obtener el redirect via CDN (CDN IPs no bloqueadas por auth server)
    const cdnVodUrl = `${siteBase}/xtream-vod/${u}/${p}/${id}.${ext}`;

    const authResp = await fetch(cdnVodUrl, {
      redirect: 'manual',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    });

    if (authResp.status !== 302) {
      const body = await authResp.text().catch(() => '');
      return {
        statusCode: authResp.status,
        body: `VOD auth failed: HTTP ${authResp.status} | ${body.slice(0, 200)}`,
      };
    }

    const location = authResp.headers.get('location') || '';
    if (!location) {
      return { statusCode: 502, body: 'VOD auth: 302 sin Location header' };
    }

    // location = "http://23.158.40.201:80/live/play/TOKEN/id"
    let tokenPath;
    try {
      tokenPath = new URL(location).pathname;
    } catch (_) {
      tokenPath = location.startsWith('/') ? location : '/' + location;
    }

    // PASO 2: Redirigir al browser a la URL del CDN proxy para el media server VOD
    // /xtream-vod-media/* → http://23.158.40.201:80/:splat (definido en netlify.toml)
    return {
      statusCode: 302,
      headers: {
        'Location': `/xtream-vod-media${tokenPath}`,
        'Cache-Control': 'no-cache, no-store, must-revalidate',
      },
      body: '',
    };

  } catch (err) {
    return {
      statusCode: 500,
      body: `VOD resolve error: ${err.message}`,
    };
  }
};
