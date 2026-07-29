/**
 * hls-proxy.js — Netlify Function (v3)
 *
 * Fixes:
 *  1. Root-relative segment URLs (ej. /live/u/p/seg.ts) se resolvían contra
 *     IPTV (allinonestream.xyz:8080) en lugar del streaming server real
 *     (23.237.74.2). Eso mandaba los segmentos al servidor equivocado, que
 *     devolvía 302 al browser → Mixed Content bloqueado.
 *  2. Intento 2 (CDN self-loop) usaba resp.url (URL del CDN) como finalBase,
 *     lo que también daba rutas incorrectas. Se añade Fase 1 HEAD para
 *     obtener la URL real del streaming server.
 *
 * Estrategia:
 *   Fase 1 — HEAD redirect:manual a allinonestream.xyz:8080
 *     → Obtener la URL de Location (streaming server) sin que Lambda
 *       conecte a 23.237.74.2. Esa URL se usa como finalBase para resolver
 *       paths de segmentos correctamente.
 *   Fase 2 — CDN self-loop: Lambda pide el M3U8 a través de /xtream-live/
 *     → El CDN edge contacta al streaming server (no Lambda IP)
 *     → Los segmentos también van por CDN edge (mismos redirects) → sin IP-binding
 *
 * Rutas CDN para segmentos (netlify.toml):
 *   23.237.74.2           → /xtream-live-relay/
 *   23.237.104.74:8080    → /xtream-media/
 *   23.158.40.201         → /xtream-vod-media/
 *   cualquier otro host   → /xtream-chunks/ (→ allinonestream.xyz:8080)
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal  = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV     = 'http://allinonestream.xyz:8080';

  const fetchHeaders = {
    'User-Agent': 'Mozilla/5.0',
    'Accept':     '*/*',
    'Connection': 'keep-alive',
  };

  function fetchWithTimeout(url, opts, ms) {
    return Promise.race([
      fetch(url, opts),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms)),
    ]);
  }

  try {
    let m3u8      = null;
    let finalBase = `${IPTV}/live/${u}/${p}/`;

    if (isLocal) {
      // ── LOCAL: fetch directo desde Lambda ─────────────────────────────────
      try {
        const resp = await fetchWithTimeout(
          `${IPTV}/live/${u}/${p}/${id}.m3u8`,
          { redirect: 'follow', headers: fetchHeaders },
          10000,
        );
        if (resp.ok) {
          const text = await resp.text();
          if (text && text.includes('#EXTM3U')) {
            m3u8 = text;
            const finalUrl = resp.url || `${IPTV}/live/${u}/${p}/${id}.m3u8`;
            finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);
          }
        }
      } catch (e) { /* timeout */ }

    } else {
      // ── PRODUCCIÓN: dos fases ───────────────────────────────────────────────

      // Fase 1: HEAD sin redirect — solo para conocer la URL del streaming
      // server sin que Lambda IP toque 23.237.74.2.
      try {
        const headResp = await fetchWithTimeout(
          `${IPTV}/live/${u}/${p}/${id}.m3u8`,
          { method: 'HEAD', redirect: 'manual', headers: fetchHeaders },
          3000,
        );
        const location = headResp.headers.get('location');
        if (location) {
          finalBase = location.substring(0, location.lastIndexOf('/') + 1);
        }
      } catch (e) { /* usa finalBase por defecto */ }

      // Fase 2: CDN self-loop — el edge de Netlify hace la petición real.
      // Segmentos también van por edge (/xtream-live-relay/, etc.) → misma IP.
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
            // resp.url es la URL del CDN de Netlify, NO la del streaming server.
            // Usamos el finalBase de Fase 1 (streaming server real).
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
 * Reescribe URLs de segmentos para que pasen por los proxies CDN del mismo origen.
 *
 * IMPORTANTE: rutas root-relative (empiezan con /) se resuelven contra
 * finalBase (streaming server, ej. http://23.237.74.2/live/u/p/) y NO
 * contra IPTV (allinonestream.xyz:8080). Si se resolvieran contra IPTV,
 * los segmentos irían al proxy /xtream-chunks/ que devuelve 302 al browser.
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  // Extraer el origen del streaming server para rutas root-relative
  let streamingOrigin;
  try {
    streamingOrigin = new URL(finalBase).origin; // 'http://23.237.74.2'
  } catch {
    streamingOrigin = IPTV;
  }

  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http'))   abs = uri;
      else if (uri.startsWith('/')) abs = new URL(uri, streamingOrigin).href; // FIX: usa streaming server
      else                          abs = new URL(uri, finalBase).href;

      const { host, pathname } = new URL(abs);

      if (host === '23.237.74.2'        || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')     return '/xtream-media'      + pathname;
      if (host === '23.158.40.201:80'   || host === '23.158.40.201')     return '/xtream-vod-media'  + pathname;
      return '/xtream-chunks' + pathname;
    } catch {
      return uri;
    }
  }

  // Reescribir líneas de segmentos (no empiezan con #)
  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    return t ? toProxy(t) : line;
  });

  // Reescribir URIs dentro de EXT-X-KEY y EXT-X-MAP
  m3u8 = m3u8.replace(
    /(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm,
    (_, a, uri, b) => a + toProxy(uri) + b,
  );

  return m3u8;
}
