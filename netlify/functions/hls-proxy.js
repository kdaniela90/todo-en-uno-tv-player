/**
 * hls-proxy.js — Netlify Function
 *
 * El servidor IPTV responde a /live/u/p/id.m3u8 con un 302 redirect a un
 * servidor de media (23.237.74.2). Los proxy rules de Netlify (status=200
 * force=true) NO siguen redirects del upstream — los pasan al cliente.
 * Esta función sigue el redirect server-side con fetch redirect:'follow',
 * obtiene el m3u8 real, y reescribe las URLs de segmentos para que el
 * browser las pida vía proxies CDN del mismo origen.
 *
 * Rutas CDN usadas para segmentos (netlify.toml):
 *   23.237.74.2           → /xtream-live-relay/
 *   23.237.104.74:8080    → /xtream-media/
 *   23.158.40.201         → /xtream-vod-media/
 *   cualquier otro host   → /xtream-chunks/ (→ allinonestream.xyz:8080)
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV = 'http://allinonestream.xyz:8080';

  const fetchHeaders = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*', 'Connection': 'keep-alive' };

  // Envuelve un fetch con timeout via Promise.race (no necesita AbortController).
  function fetchWithTimeout(url, opts, ms) {
    return Promise.race([
      fetch(url, opts),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
    ]);
  }

  try {
    let m3u8 = null;
    let finalBase = `${IPTV}/live/${u}/${p}/`;

    // ── Intento 1: fetch directo al servidor IPTV ──────────────────────────────
    // fetch con redirect:'follow' sigue el 302 a 23.237.74.2 server-side.
    // Funciona si las IPs de Lambda no están bloqueadas.
    try {
      const resp = await fetchWithTimeout(
        `${IPTV}/live/${u}/${p}/${id}.m3u8`,
        { redirect: 'follow', headers: fetchHeaders },
        isLocal ? 10000 : 5000,
      );
      if (resp.ok) {
        const text = await resp.text();
        if (text && text.includes('#EXTM3U')) {
          m3u8 = text;
          // resp.url = URL final después de seguir el redirect (ej. http://23.237.74.2/live/play/{token}/{id})
          const finalUrl = resp.url || `${IPTV}/live/${u}/${p}/${id}.m3u8`;
          finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);
        }
      }
    } catch (e) {
      // Timeout o IPs de Lambda bloqueadas → intentar vía CDN
    }

    // ── Intento 2 (solo producción): CDN self-loop ─────────────────────────────
    // El CDN usa IPs de edge no bloqueadas. Netlify pasa el 302 a Lambda,
    // y el fetch con redirect:'follow' lo sigue hasta 23.237.74.2.
    if (!m3u8 && !isLocal) {
      try {
        const resp = await fetchWithTimeout(
          `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
          { redirect: 'follow', headers: fetchHeaders },
          6000,
        );
        if (resp.ok) {
          const text = await resp.text();
          if (text && text.includes('#EXTM3U')) {
            m3u8 = text;
            const finalUrl = resp.url || `${IPTV}/live/${u}/${p}/${id}.m3u8`;
            finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);
          }
        } else {
          return { statusCode: resp.status, body: `Stream unavailable (${resp.status})` };
        }
      } catch (e) {
        return { statusCode: 504, body: 'Stream timeout' };
      }
    }

    if (!m3u8) {
      return { statusCode: 502, body: 'Could not retrieve stream' };
    }

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache',
      },
      body: rewriteSegments(m3u8, finalBase, IPTV),
    };

  } catch (err) {
    return { statusCode: 500, body: `Proxy error: ${err.message}` };
  }
};

/**
 * Reescribe URLs de segmentos/.m3u8 para que pasen por los proxies CDN.
 * El host del URL determina qué ruta CDN usar:
 *   23.237.74.2        → /xtream-live-relay/ (servidor de media live)
 *   23.237.104.74:8080 → /xtream-media/
 *   23.158.40.201      → /xtream-vod-media/
 *   cualquier otro     → /xtream-chunks/ (→ allinonestream.xyz:8080)
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http')) abs = uri;
      else if (uri.startsWith('/')) abs = new URL(uri, IPTV).href;
      else abs = new URL(uri, finalBase).href;

      const { host, pathname } = new URL(abs);

      if (host === '23.237.74.2' || host === '23.237.74.2:80') return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74') return '/xtream-media' + pathname;
      if (host === '23.158.40.201:80' || host === '23.158.40.201') return '/xtream-vod-media' + pathname;
      return '/xtream-chunks' + pathname;
    } catch {
      return uri;
    }
  }

  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    return t ? toProxy(t) : line;
  });

  m3u8 = m3u8.replace(/(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm,
    (_, a, uri, b) => a + toProxy(uri) + b);

  return m3u8;
}
