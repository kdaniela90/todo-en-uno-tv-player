/**
 * hls-proxy.js — Netlify Function v7
 *
 * Obtiene el M3U8 de un canal en vivo y reescribe las URLs de segmentos
 * para que pasen por los proxies CDN del mismo origen.
 *
 * v7 vs v6:
 *   - Phase 1 y Phase 2 corren en PARALELO (no secuencial).
 *   - Elimina la latencia de 4s cuando Phase 1 falla (IPs Lambda bloqueadas).
 *   - Phase 1 timeout reducido a 1.5s (si no responde en 1.5s, IPs bloqueadas — esperar 4s era inútil).
 *   - Phase 2 CDN self-loop sigue siendo 8s.
 *   - Resultado total: response en ~500ms-2s en lugar de 4-12s.
 *
 * Estrategia:
 *   Phase 1 — GET+redirect:manual a IPTV (1.5s timeout, en paralelo con Phase 2)
 *     → Captura Location del 302 → guarda como finalBase para resolver segmentos relativos.
 *
 *   Phase 2 — CDN self-loop SIEMPRE (8s timeout, inicia al mismo tiempo que Phase 1)
 *     → CDN edge (IPs no bloqueadas) → IPTV → media server → M3U8 real.
 *
 *   rewriteSegments usa finalBase (de Phase 1 si llegó; fallback a IPTV si no).
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
      // ── PRODUCCIÓN: Phase 1 + Phase 2 en PARALELO ────────────────────────

      const phase1Promise = fetchWithTimeout(
        `${IPTV}/live/${u}/${p}/${id}.m3u8`,
        { method: 'GET', redirect: 'manual', headers: fetchHeaders },
        1500,  // 1.5s — si las IPs Lambda están bloqueadas, saberlo rápido
      ).then(r => {
        const loc = r.headers.get('location');
        return loc ? loc.substring(0, loc.lastIndexOf('/') + 1) : null;
      }).catch(() => null);  // timeout o error → null

      const phase2Promise = fetchWithTimeout(
        `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
        { redirect: 'follow', headers: fetchHeaders },
        8000,
      );

      // Esperar a que Phase 2 termine (es la fuente del M3U8)
      // Phase 1 puede completarse antes o después — tomamos lo que llegue
      let resp2;
      try {
        resp2 = await phase2Promise;
      } catch (e) {
        return { statusCode: 504, body: 'Stream timeout' };
      }

      if (!resp2.ok) {
        return { statusCode: resp2.status, body: `Stream unavailable (${resp2.status})` };
      }

      const text2 = await resp2.text();
      if (!text2 || !text2.includes('#EXTM3U')) {
        return { statusCode: 502, body: 'Invalid M3U8 response' };
      }
      m3u8 = text2;

      // Tomar finalBase de Phase 1: si completó mientras esperábamos Phase 2, la usamos.
      // Si aún está en curso, esperamos hasta 200ms más (no bloqueamos por más tiempo).
      const phase1Base = await Promise.race([
        phase1Promise,
        new Promise(resolve => setTimeout(() => resolve(null), 200)),
      ]);

      if (phase1Base) {
        finalBase = phase1Base;
      } else {
        // Phase 1 aún no terminó o falló — intentar inferir de resp2.url
        const respUrl   = resp2.url || '';
        const ourDomain = siteBase.replace('https://', '').replace('http://', '');
        if (respUrl && !respUrl.includes(ourDomain) && respUrl.startsWith('http')) {
          finalBase = respUrl.substring(0, respUrl.lastIndexOf('/') + 1);
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
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathname;
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
