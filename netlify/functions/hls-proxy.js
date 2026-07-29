/**
 * hls-proxy.js — Netlify Function (v4)
 *
 * Fixes v4:
 *  1. Fase 1 usaba HEAD → IPTV rechaza HEAD al nivel TCP ("fetch failed").
 *     Cambio: GET+redirect:manual. IPTV devuelve 302 sin enviar body, Lambda
 *     captura la Location sin descargar nada. finalBase queda correctamente
 *     apuntando al streaming server real (ej. 216.106.177.68).
 *  2. 216.106.177.68 es el nuevo servidor de streaming (no estaba en el mapeo).
 *     Agregado a toProxy() → /xtream-stream-hls/.
 *  3. Fase 2: si Fase 1 fallo, se usa resp.url como backup de finalBase.
 *     (el diagnostico confirma que resp.url SI es la URL del streaming server
 *     cuando Lambda sigue el redirect desde Netlify CDN)
 *
 * Estrategia:
 *   Fase 1 — GET+redirect:manual a allinonestream.xyz:8080
 *     → IPTV responde 302 → Lambda captura Location (streaming server real).
 *     → finalBase queda correctamente seteado sin que Lambda descargue nada.
 *   Fase 2 — CDN self-loop via /xtream-live/
 *     → El CDN edge (no Lambda) contacta al streaming server.
 *     → resp.url es la URL real del streaming server (backup de finalBase).
 *     → Los segmentos van por CDN edge con el proxy CDN correcto.
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
    let gotFinalBase = false;

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
      } catch (e) { /* timeout */ }

    } else {
      // ── Fase 1: GET+redirect:manual — captura Location sin descargar body ──
      // FIX v4: HEAD era rechazado por IPTV al nivel TCP ("fetch failed").
      // GET+manual funciona: IPTV responde 302 inmediatamente, Lambda captura
      // la URL del streaming server sin seguir el redirect ni descargar nada.
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
        }
      } catch (e) { /* continua con finalBase por defecto */ }

      // ── Fase 2: CDN self-loop — CDN edge hace la peticion real ─────────────
      try {
        const resp2 = await fetchWithTimeout(
          `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
          { redirect: 'follow', headers: fetchHeaders },
          6000,
        );
        if (resp2.ok) {
          const text = await resp2.text();
          if (text && text.includes('#EXTM3U')) {
            m3u8 = text;
            // Backup: si Fase 1 fallo, usar resp.url como finalBase.
            // El diagnostico confirma que resp.url SI es la URL del streaming
            // server (Netlify CDN pasa el 302 a Lambda, que lo sigue).
            if (!gotFinalBase) {
              const respUrl = resp2.url || '';
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
 * Mapeo de servidores de streaming conocidos → ruta CDN:
 *   216.106.177.68     → /xtream-stream-hls/   (v4: nuevo servidor principal)
 *   23.237.74.2        → /xtream-live-relay/
 *   23.237.104.74:8080 → /xtream-media/
 *   23.158.40.201      → /xtream-vod-media/
 *   cualquier otro     → /xtream-chunks/ (via allinonestream.xyz:8080)
 *
 * CRITICO: rutas root-relative (empiezan con /) se resuelven contra
 * streamingOrigin (el servidor real, ej. 216.106.177.68), NO contra IPTV.
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
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay'  + pathname;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'       + pathname;
      if (host === '23.158.40.201:80'   || host === '23.158.40.201')      return '/xtream-vod-media'   + pathname;
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
