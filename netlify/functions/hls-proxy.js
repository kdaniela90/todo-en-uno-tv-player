/**
 * hls-proxy.js — Netlify Function v6
 *
 * Obtiene el M3U8 de un canal en vivo y reescribe las URLs de segmentos
 * para que pasen por los proxies CDN del mismo origen.
 *
 * Cambios vs versiones anteriores:
 *   - v4: Intento 1 (Lambda→IPTV direct) + Intento 2 (CDN self-loop)
 *         Problema: Intento 1 siempre falla (IPs Lambda bloqueadas) y
 *         agrega 5s de latencia antes del CDN self-loop.
 *   - v5/v6: Elimina Intento 1. Usa CDN self-loop siempre.
 *         Fase 1 (GET+redirect:manual) solo para capturar finalBase
 *         y mejorar la reescritura de segmentos (4s timeout rápido).
 *         Agrega 216.106.177.68 → /xtream-stream-hls en rewriteSegments.
 *
 * Estrategia:
 *   Fase 1 — GET+redirect:manual a IPTV (4s timeout, sin descargar body)
 *     → Captura Location del 302 → guarda como finalBase para segmentos
 *     → Si falla, finalBase queda apuntando a IPTV (funciona igual)
 *
 *   Fase 2 — CDN self-loop SIEMPRE (8s timeout)
 *     → ${siteBase}/xtream-live/u/p/id.m3u8 → CDN → IPTV → media server
 *     → CDN edge usa IPs no bloqueadas → obtiene M3U8 real
 *
 * Rutas CDN para segmentos (netlify.toml):
 *   216.106.177.68        → /xtream-stream-hls/
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
      // ── LOCAL: fetch directo desde Lambda ──────────────────────────────────
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
      // ── PRODUCCIÓN ────────────────────────────────────────────────────────

      // Fase 1: GET+redirect:manual — capturar Location para finalBase.
      // Solo nos interesa el header Location (no el body del video).
      // IPTV devuelve 302 inmediatamente, sin descargar contenido.
      try {
        const resp1 = await fetchWithTimeout(
          `${IPTV}/live/${u}/${p}/${id}.m3u8`,
          { method: 'GET', redirect: 'manual', headers: fetchHeaders },
          4000,
        );
        const location = resp1.headers.get('location');
        if (location) {
          finalBase = location.substring(0, location.lastIndexOf('/') + 1);
        }
      } catch (e) { /* timeout o red → finalBase queda apuntando a IPTV (OK) */ }

      // Fase 2: CDN self-loop SIEMPRE — el CDN edge (IPs no bloqueadas)
      // contacta IPTV y sigue el redirect al media server real.
      try {
        const resp2 = await fetchWithTimeout(
          `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
          { redirect: 'follow', headers: fetchHeaders },
          8000,
        );
        if (resp2.ok) {
          const text = await resp2.text();
          if (text && text.includes('#EXTM3U')) {
            m3u8 = text;
            // Si Fase 1 no dio finalBase, intentar obtenerla de resp2.url
            if (!finalBase || finalBase === `${IPTV}/live/${u}/${p}/`) {
              const respUrl   = resp2.url || '';
              const ourDomain = siteBase.replace('https://', '').replace('http://', '');
              if (respUrl && !respUrl.includes(ourDomain) && respUrl.startsWith('http')) {
                finalBase = respUrl.substring(0, respUrl.lastIndexOf('/') + 1);
              }
            }
          }
        } else {
          return { statusCode: resp2.status, body: `Stream unavailable (${resp2.status})` };
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
 * el STREAMING SERVER REAL (finalBase, ej. http://216.106.177.68/live/play/TOKEN/)
 * y NO contra IPTV (allinonestream.xyz:8080).
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  // Extraer el origen del streaming server para rutas root-relative
  let streamingOrigin;
  try {
    streamingOrigin = new URL(finalBase).origin; // ej: 'http://216.106.177.68'
  } catch {
    streamingOrigin = IPTV;
  }

  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http'))   abs = uri;
      else if (uri.startsWith('/')) abs = new URL(uri, streamingOrigin).href; // root-relative → streaming server
      else                          abs = new URL(uri, finalBase).href;

      const { host, pathname } = new URL(abs);

      if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathname;
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + pathname;
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathname;
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
