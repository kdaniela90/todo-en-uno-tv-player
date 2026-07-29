/**
 * hls-proxy.js — Netlify Function
 *
 * Producción: self-loop via Netlify CDN proxy (/xtream-live/).
 *   El CDN tiene status=200 force=true, lo que significa que ya sigue
 *   cualquier redirect del servidor IPTV internamente y retorna 200 con
 *   el contenido directo — NO se debe esperar 302.
 * Local (netlify dev): fetch directo al servidor IPTV.
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV = 'http://allinonestream.xyz:8080';

  const fetchHeaders = {
    'User-Agent': 'Mozilla/5.0',
    'Accept': '*/*',
    'Connection': 'keep-alive',
  };

  try {
    let m3u8;

    if (isLocal) {
      // ── MODO LOCAL: fetch directo al servidor IPTV ──
      const directUrl = `${IPTV}/live/${u}/${p}/${id}.m3u8`;
      const resp = await fetch(directUrl, { redirect: 'follow', headers: fetchHeaders });
      if (!resp.ok) {
        return { statusCode: resp.status, body: `Stream unavailable (${resp.status})` };
      }
      m3u8 = await resp.text();
      const finalUrl = resp.url || directUrl;
      const finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);
      m3u8 = rewriteSegments(m3u8, finalBase, IPTV);

    } else {
      // ── MODO PRODUCCIÓN: via CDN proxy ──
      // status=200 force=true en netlify.toml significa que el CDN ya sigue
      // el redirect del IPTV y devuelve 200 con el contenido — no 302.
      const cdnUrl = `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`;
      const resp = await fetch(cdnUrl, { redirect: 'follow', headers: fetchHeaders });
      if (!resp.ok) {
        return { statusCode: resp.status, body: `Stream unavailable (${resp.status})` };
      }
      m3u8 = await resp.text();
      // finalBase para resolver segmentos con URL relativa
      const finalBase = (resp.url || cdnUrl).replace(/\/[^/]*$/, '/');
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
    return { statusCode: 500, body: `Proxy error: ${err.message}` };
  }
};

/**
 * Reescribe segmentos y URIs de EXT-X-KEY/EXT-X-MAP para que pasen
 * por el proxy /xtream-media/, asegurando que connect-src 'self' no bloquee nada.
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http')) abs = uri;
      else if (uri.startsWith('/')) abs = new URL(uri, IPTV).href;
      else abs = new URL(uri, finalBase).href;
      return '/xtream-media' + new URL(abs).pathname;
    } catch {
      return uri;
    }
  }

  // Rewrite non-comment lines (segment URLs)
  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    if (!t) return line;
    return toProxy(t);
  });

  // Rewrite URI="..." inside EXT-X-KEY and EXT-X-MAP tags
  m3u8 = m3u8.replace(/(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm, (match, pre, uri, post) => {
    return pre + toProxy(uri) + post;
  });

  return m3u8;
}
