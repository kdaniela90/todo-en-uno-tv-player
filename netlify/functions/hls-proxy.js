/**
 * hls-proxy.js — Netlify Function (v6)
 *
 * Regresa a la estrategia probada de v4 (CDN self-loop siempre),
 * manteniendo Phase 1 solo para obtener finalBase correcto.
 *
 * v5 intentó un "fast path" directo al streaming server, pero el token
 * del Location header está vinculado a la IP de Lambda. El edge CDN
 * (distinta IP) es rechazado → timeout 6s → no queda tiempo para fallback
 * dentro del límite de Lambda (10s).
 *
 * Estrategia v6:
 *   Fase 1 — GET+redirect:manual a allinonestream.xyz:8080 (timeout 4s)
 *     → Captura Location para obtener finalBase (URL del streaming server real)
 *     → Sin descargar body
 *   Fase 2 — CDN self-loop: /xtream-live/ → Netlify CDN edge → IPTV → streaming server
 *     → Igual que v4. El CDN edge genera su propio token con IPTV.
 *     → finalBase de Fase 1 asegura que los segmentos se resuelvan correctamente.
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

      // Fase 1: GET+redirect:manual — capturar Location para saber el finalBase.
      // IPTV devuelve 302 inmediatamente → Lambda lee el header, no conecta al streaming server.
      // NOTA: IPTV rechaza HEAD a nivel TCP, por eso usamos GET+manual.
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
      } catch (e) { /* timeout o fallo → usa finalBase por defecto (IPTV) */ }

      // Fase 2: CDN self-loop — el edge de Netlify hace la petición a IPTV,
      // recibe el 302, lo sigue hasta el streaming server y descarga el m3u8.
      // El token que genera IPTV queda vinculado a la IP del edge CDN, que
      // también servirá los segmentos → sin IP-binding issues.
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
            // Si Fase 1 no dio Location, intentar obtener finalBase de resp2.url
            // (aunque resp2.url es la URL del CDN, no del streaming server)
            if (finalBase === `${IPTV}/live/${u}/${p}/`) {
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
 * Rutas root-relative (empiezan con /) se resuelven contra el streaming server real
 * (finalBase), NO contra IPTV, para evitar Mixed Content y redirecciones al browser.
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
