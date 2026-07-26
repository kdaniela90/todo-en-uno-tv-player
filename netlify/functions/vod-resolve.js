/**
 * vod-resolve.js — Netlify Function
 *
 * Producción: self-loop via CDN para obtener el token de sesión VOD.
 * Local: redirect 302 directo al servidor IPTV.
 */
exports.handler = async (event) => {
  const { u, p, id, ext = 'mp4', type = 'movie' } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV = 'http://allinonestream.xyz:8080';

  if (isLocal) {
    // ── MODO LOCAL: redirigir directo al servidor IPTV ──
    const path = type === 'series' ? 'series' : 'movie';
    return {
      statusCode: 302,
      headers: {
        'Location': `${IPTV}/${path}/${u}/${p}/${id}.${ext}`,
        'Cache-Control': 'no-cache',
      },
      body: '',
    };
  }

  // ── MODO PRODUCCIÓN: self-loop via CDN ──
  try {
    const pathPrefix = type === 'series' ? 'xtream-series' : 'xtream-vod';
    const cdnVodUrl = `${siteBase}/${pathPrefix}/${u}/${p}/${id}.${ext}`;

    const authResp = await fetch(cdnVodUrl, {
      redirect: 'manual',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    });

    if (authResp.status !== 302) {
      const body = await authResp.text().catch(() => '');
      return { statusCode: authResp.status, body: `VOD auth failed: HTTP ${authResp.status} | ${body.slice(0, 200)}` };
    }

    const location = authResp.headers.get('location') || '';
    if (!location) return { statusCode: 502, body: 'VOD auth: 302 sin Location header' };

    let tokenPath;
    try { tokenPath = new URL(location).pathname; }
    catch { tokenPath = location.startsWith('/') ? location : '/' + location; }

    return {
      statusCode: 302,
      headers: {
        'Location': `/xtream-vod-media${tokenPath}`,
        'Cache-Control': 'no-cache, no-store, must-revalidate',
      },
      body: '',
    };

  } catch (err) {
    return { statusCode: 500, body: `VOD resolve error: ${err.message}` };
  }
};
