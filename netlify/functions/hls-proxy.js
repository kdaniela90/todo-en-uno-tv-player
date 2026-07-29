/**
 * hls-proxy.js — Netlify Function (fallback, no longer used for main live flow)
 *
 * El flujo principal de live ahora usa /xtream-live/ directamente desde el browser
 * con un custom HLS.js loader que reescribe URLs de segmentos. Esta función se
 * mantiene como fallback para dispositivos que no soporten el custom loader.
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const IPTV = 'http://allinonestream.xyz:8080';

  const headers = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' };

  try {
    // Intenta fetch directo primero
    let m3u8 = null;
    let finalBase = `${IPTV}/live/${u}/${p}/`;

    try {
      const r = await fetch(`${IPTV}/live/${u}/${p}/${id}.m3u8`, { redirect: 'follow', headers });
      if (r.ok) {
        const t = await r.text();
        if (t.includes('#EXTM3U')) { m3u8 = t; finalBase = (r.url || '').replace(/[^/]+$/, '') || finalBase; }
      }
    } catch (_) {}

    // Fallback: CDN self-loop
    if (!m3u8) {
      const r = await fetch(`${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`, { redirect: 'follow', headers });
      if (!r.ok) return { statusCode: r.status, body: `Stream unavailable (${r.status})` };
      const t = await r.text();
      if (!t.includes('#EXTM3U')) return { statusCode: 502, body: 'Invalid stream response' };
      m3u8 = t;
    }

    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/vnd.apple.mpegurl', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache' },
      body: rewriteSegments(m3u8, finalBase, IPTV),
    };
  } catch (err) {
    return { statusCode: 500, body: `Proxy error: ${err.message}` };
  }
};

function rewriteSegments(m3u8, finalBase, IPTV) {
  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      const abs = uri.startsWith('http') ? uri : uri.startsWith('/') ? new URL(uri, IPTV).href : new URL(uri, finalBase).href;
      const { host, pathname } = new URL(abs);
      if (host === '23.237.104.74:8080' || host === '23.237.104.74') return '/xtream-media' + pathname;
      if (host === '23.158.40.201:80' || host === '23.158.40.201') return '/xtream-vod-media' + pathname;
      return '/xtream-chunks' + pathname;
    } catch { return uri; }
  }
  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, l => { const t = l.trim(); return t ? toProxy(t) : l; });
  m3u8 = m3u8.replace(/(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm, (_, a, u, b) => a + toProxy(u) + b);
  return m3u8;
}
