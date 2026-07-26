/**
 * hls-proxy.js — Netlify Function
 *
 * Producción: self-loop via Netlify CDN (IPs de edge no bloqueadas por el servidor IPTV).
 * Local (netlify dev): fetch directo al servidor IPTV con resolución correcta de rutas relativas.
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV = 'http://allinonestream.xyz:8080';

  try {
    let m3u8;

    if (isLocal) {
      // ── MODO LOCAL: fetch directo al servidor IPTV ──
      const directUrl = `${IPTV}/live/${u}/${p}/${id}.m3u8`;
      const resp = await fetch(directUrl, {
        redirect: 'follow',
        headers: { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      });
      if (!resp.ok) {
        return { statusCode: resp.status, body: `Stream unavailable (${resp.status})` };
      }
      m3u8 = await resp.text();

      // URL final tras redirect (necesaria para resolver rutas relativas)
      const finalUrl = resp.url || directUrl;
      const finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);

      m3u8 = rewriteSegments(m3u8, finalBase, IPTV);

    } else {
      // ── MODO PRODUCCIÓN: self-loop via CDN ──
      const cdnAuthUrl = `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`;
      const authResp = await fetch(cdnAuthUrl, {
        redirect: 'manual',
        headers: { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      });
      if (authResp.status !== 302) {
          return { statusCode: authResp.status, body: `Auth failed (${authResp.status})` };
      }
      const location = authResp.headers.get('location') || '';
      if (!location) return { statusCode: 502, body: 'Auth: 302 sin Location header' };

      let tokenPath;
      try { tokenPath = new URL(location).pathname; }
      catch { tokenPath = location.startsWith('/') ? location : '/' + location; }

      const cdnMediaUrl = `${siteBase}/xtream-media${tokenPath}`;
      const m3u8Resp = await fetch(cdnMediaUrl, {
        redirect: 'follow',
        headers: { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      });
      if (!m3u8Resp.ok) {
        return { statusCode: m3u8Resp.status, body: `Media unavailable (${m3u8Resp.status})` };
      }
      m3u8 = await m3u8Resp.text();
      const finalBase = (m3u8Resp.url || cdnMediaUrl).replace(/\/[^/]*$/, '/');
      m3u8 = rewriteSegments(m3u8, finalBase, IPTV);
    }

    if (!m3u8 || !m3u8.includes('#EXTM3U')) {
      return { statusCode: 502, body: 'Invalid stream response' };
    }

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache',
      },
      body: m3u8,
    };

  } catch (err) {
    return { statusCode: 500, body: 'Proxy error' };
  }
};

/**
 * Reescribe todas las líneas de segmento del m3u8 para que pasen
 * por el proxy /xtream-media/, resolviendo rutas relativas con finalBase.
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  return m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    if (!t) return line;
    // Ya reescrito
    if (t.startsWith('/xtream')) return line;

    let absUrl;
    try {
      if (t.startsWith('http')) {
        absUrl = t;
      } else if (t.startsWith('/')) {
        // Ruta absoluta sin host → resolver contra el servidor IPTV
        absUrl = new URL(t, IPTV).href;
      } else {
        // Ruta relativa → resolver contra la URL base del m3u8
        absUrl = new URL(t, finalBase).href;
      }
      return '/xtream-media' + new URL(absUrl).pathname;
    } catch {
      return line;
    }
  });
}
