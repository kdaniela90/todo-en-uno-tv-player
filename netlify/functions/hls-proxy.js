/**
 * hls-proxy.js — Netlify Function (v2)
 *
 * FIX: Resuelve el error 403 en fragmentos HLS causado por IP-binding.
 *
 * Problema original:
 *   - Intento 1 hacía fetch con redirect:'follow' → Lambda IP (AWS) conectaba a
 *     23.237.74.2 y quedaba registrada como IP de sesión.
 *   - Los segmentos .ts se servían vía redirecciones del CDN Netlify (IP diferente).
 *   - El servidor IPTV veía una IP distinta en los segmentos → 403.
 *
 * Solución (estrategia dos fases en producción):
 *   Fase 1 — HEAD con redirect:'manual' a allinonestream.xyz:8080
 *     → Obtenemos la URL de Location (streaming server real) sin que Lambda
 *       conecte a 23.237.74.2. Usamos ese URL solo para resolver paths relativos.
 *   Fase 2 — CDN self-loop: Lambda pide el M3U8 a través del CDN de Netlify
 *     (/xtream-live/...) → el CDN edge es quien contacta a 23.237.74.2.
 *     Los segmentos también van por CDN edge (mismos redirects) → misma IP → sin 403.
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
    let finalBase = `${IPTV}/live/${u}/${p}/`; // fallback; se actualiza en Fase 1

    // ══════════════════════════════════════════════════════════════════════════
    // ENTORNO LOCAL: sin CDN disponible → fallback al fetch directo de Lambda
    // (puede tener IP-binding en local dev, pero es aceptable para desarrollo)
    // ══════════════════════════════════════════════════════════════════════════
    if (isLocal) {
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
      } catch (e) { /* timeout o error de red */ }

    } else {
      // ════════════════════════════════════════════════════════════════════════
      // PRODUCCIÓN — Estrategia dos fases para evitar IP-binding
      // ════════════════════════════════════════════════════════════════════════

      // ── Fase 1: HEAD sin seguir redirect ────────────────────────────────────
      // Lambda toca SOLO allinonestream.xyz:8080 (sin body, sin sesión de media).
      // Leemos la cabecera Location para saber la URL real del streaming server.
      // Esa URL la usamos como base para resolver segmentos con paths relativos.
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
      } catch (e) {
        // Si falla, usamos el finalBase por defecto (allinonestream.xyz/live/u/p/)
      }

      // ── Fase 2: CDN self-loop para obtener el M3U8 ──────────────────────────
      // Lambda hace fetch a su propio dominio vía /xtream-live/... → el CDN edge
      // de Netlify hace la petición real a allinonestream.xyz → sigue el 302 a
      // 23.237.74.2. La IP del CDN edge queda registrada.
      // Los segmentos también van por CDN edge (/xtream-live-relay/, /xtream-media/,
      // etc.) → misma clase de IP → sin 403.
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
            // NO usamos resp.url aquí: en el contexto de Lambda, resp.url es la
            // URL del CDN de Netlify, NO la del streaming server real. Usamos el
            // finalBase obtenido en Fase 1.
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
 * Reescribe URLs de segmentos/.m3u8 anidados para que pasen por los proxies CDN.
 * El host del URL determina qué ruta CDN usar:
 *   23.237.74.2        → /xtream-live-relay/
 *   23.237.104.74:8080 → /xtream-media/
 *   23.158.40.201      → /xtream-vod-media/
 *   cualquier otro     → /xtream-chunks/ (→ allinonestream.xyz:8080)
 */
function rewriteSegments(m3u8, finalBase, IPTV) {
  function toProxy(uri) {
    if (!uri || uri.startsWith('/xtream')) return uri;
    try {
      let abs;
      if (uri.startsWith('http'))       abs = uri;
      else if (uri.startsWith('/'))     abs = new URL(uri, IPTV).href;
      else                              abs = new URL(uri, finalBase).href;

      const { host, pathname } = new URL(abs);

      if (host === '23.237.74.2'     || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')  return '/xtream-media'      + pathname;
      if (host === '23.158.40.201:80'   || host === '23.158.40.201')  return '/xtream-vod-media'  + pathname;
      return '/xtream-chunks' + pathname;
    } catch {
      return uri;
    }
  }

  // Reescribir líneas que son URLs de segmentos (no empiezan con #)
  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    return t ? toProxy(t) : line;
  });

  // Reescribir URIs dentro de tags EXT-X-KEY y EXT-X-MAP
  m3u8 = m3u8.replace(
    /(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm,
    (_, a, uri, b) => a + toProxy(uri) + b,
  );

  return m3u8;
}
