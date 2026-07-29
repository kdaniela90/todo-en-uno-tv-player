/**
 * hls-proxy.js — Netlify Function (v5)
 *
 * Mejora vs v4: Fast path en Fase 2.
 *
 * En v4, Fase 2 hacía un CDN self-loop vía /xtream-live/ → IPTV → streaming server,
 * lo que tomaba ~5-7s (IPTV hop incluido). Con 4 streams en multiview y timeout de 12s,
 * esto causaba lag y pantallas negras.
 *
 * En v5, si Fase 1 obtiene la URL del streaming server (Location header del 302),
 * Fase 2 va DIRECTAMENTE a ese servidor vía CDN proxy (/xtream-stream-hls/),
 * saltándose el salto por IPTV. Resultado: ~1-2s total en lugar de ~5-7s.
 *
 * Si Fase 1 falla (no hay Location), Fase 2 usa el fallback original (CDN self-loop
 * vía /xtream-live/ → IPTV).
 *
 * Estrategia:
 *   Fase 1 — GET+redirect:manual a allinonestream.xyz:8080
 *     → Captura el 302 Location (URL del streaming server real)
 *     → Sin descargar body — IPTV devuelve 302 inmediatamente
 *
 *   Fase 2a — Fast path (cuando Fase 1 OK):
 *     → Convierte Location URL → ruta CDN proxy mismo origen
 *     → Ej: http://216.106.177.68/live/play/TOKEN/id → /xtream-stream-hls/live/play/TOKEN/id
 *     → Lambda pide eso al CDN edge, que contacta 216.106.177.68 directamente
 *     → Latencia: ~1-2s
 *
 *   Fase 2b — Fallback (cuando Fase 1 falló):
 *     → CDN self-loop original: /xtream-live/ → IPTV → streaming server
 *     → Latencia: ~5-7s (igual que v4)
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

  /**
   * Convierte una URL absoluta del streaming server a una ruta CDN proxy.
   * Ejemplo: http://216.106.177.68/live/play/TOKEN/123 → /xtream-stream-hls/live/play/TOKEN/123
   */
  function streamingUrlToCdnPath(url) {
    try {
      const { host, pathname } = new URL(url);
      if (host === '216.106.177.68' || host === '216.106.177.68:80') return '/xtream-stream-hls' + pathname;
      if (host === '23.237.74.2'    || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74') return '/xtream-media'      + pathname;
      if (host === '23.158.40.201'  || host === '23.158.40.201:80')  return '/xtream-vod-media'  + pathname;
      return null;
    } catch {
      return null;
    }
  }

  try {
    let m3u8      = null;
    let finalBase = `${IPTV}/live/${u}/${p}/`;
    let gotFinalBase = false;

    if (isLocal) {
      // ── LOCAL: fetch directo desde Lambda ───────────────────────────────────
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
      // ── PRODUCCIÓN ──────────────────────────────────────────────────────────

      // Fase 1: GET+redirect:manual — capturar Location sin descargar body.
      // IPTV devuelve 302 inmediatamente → Lambda lee Location, no conecta a 216.106.177.68.
      // NOTA: IPTV rechaza HEAD a nivel TCP ("fetch failed"), por eso usamos GET+manual.
      let streamingDirectUrl = null;
      try {
        const resp1 = await fetchWithTimeout(
          `${IPTV}/live/${u}/${p}/${id}.m3u8`,
          { method: 'GET', redirect: 'manual', headers: fetchHeaders },
          4000,
        );
        const location = resp1.headers.get('location');
        if (location) {
          finalBase = location.substring(0, location.lastIndexOf('/') + 1);
          gotFinalBase = true;
          streamingDirectUrl = location;
        }
      } catch (e) { /* timeout o fallo de red → continúa con fallback */ }

      if (streamingDirectUrl) {
        // ── Fase 2a: Fast path — CDN proxy directo al streaming server ─────────
        // Evita el salto por IPTV: reduce latencia de ~6s a ~1-2s.
        const cdnPath = streamingUrlToCdnPath(streamingDirectUrl);
        if (cdnPath) {
          try {
            const resp2a = await fetchWithTimeout(
              `${siteBase}${cdnPath}`,
              { redirect: 'follow', headers: fetchHeaders },
              6000,
            );
            if (resp2a.ok) {
              const text = await resp2a.text();
              if (text && text.includes('#EXTM3U')) {
                m3u8 = text;
              }
            }
          } catch (e) { /* timeout → caer a Fase 2b */ }
        }
      }

      if (!m3u8) {
        // ── Fase 2b: Fallback — CDN self-loop vía IPTV (igual que v4) ──────────
        try {
          const resp2b = await fetchWithTimeout(
            `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
            { redirect: 'follow', headers: fetchHeaders },
            8000,
          );
          if (resp2b.ok) {
            const text = await resp2b.text();
            if (text && text.includes('#EXTM3U')) {
              m3u8 = text;
              if (!gotFinalBase) {
                const respUrl   = resp2b.url || '';
                const ourDomain = siteBase.replace('https://', '').replace('http://', '');
                if (respUrl && !respUrl.includes(ourDomain) && respUrl.startsWith('http')) {
                  finalBase = respUrl.substring(0, respUrl.lastIndexOf('/') + 1);
                }
              }
            }
          } else {
            return { statusCode: resp2b.status, body: `Stream unavailable (${resp2b.status})` };
          }
        } catch (e) {
          return { statusCode: 504, body: 'Stream timeout' };
        }
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
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  let streamingOrigin;
  try {
    streamingOrigin = new URL(finalBase).origin;
  } catch {
    streamingOrigin = IPTV;
  }

  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http'))   abs = uri;
      else if (uri.startsWith('/')) abs = new URL(uri, streamingOrigin).href;
      else                          abs = new URL(uri, finalBase).href;

      const { host, pathname } = new URL(abs);

      if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathname;
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + pathname;
      if (host === '23.158.40.201:80'   || host === '23.158.40.201')      return '/xtream-vod-media'  + pathname;
      return '/xtream-chunks' + pathname;
    } catch {
      return uri;
    }
  }

  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    return t ? toProxy(t) : line;
  });

  m3u8 = m3u8.replace(
    /(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm,
    (_, a, uri, b) => a + toProxy(uri) + b,
  );

  return m3u8;
}
