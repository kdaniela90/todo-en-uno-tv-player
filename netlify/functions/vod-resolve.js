/**
 * vod-resolve.js — Netlify Function v5
 *
 * Resuelve la URL de streaming de un VOD/serie y redirige el navegador.
 *
 * El servidor IPTV responde a /movie/u/p/id.ext con un 302 redirect a un
 * servidor de media (ej. 23.158.40.201) con un token de sesión.
 *
 * Problema v3: usábamos HEAD desde Lambda. IPTV rechaza HEAD a nivel TCP
 * ("fetch failed") igual que con live streams, y cuando sí responde, el
 * token queda vinculado a la IP de Lambda — no a la IP del CDN edge.
 *
 * Solución v5:
 *   Fase 1 — GET+redirect:manual directamente a IPTV (4s timeout)
 *     → Captura el 302 Location sin descargar el cuerpo del video.
 *     → Si IPTV responde → convertir Location a ruta CDN → 302 al browser.
 *
 *   Fase 2 — Fallback CDN self-loop
 *     → Browser va a /xtream-vod/ o /xtream-series/ → CDN → IPTV.
 *     → Funciona si el CDN sigue el 302 de IPTV hasta el media server.
 *
 * Local: redirect 302 directo al servidor IPTV.
 */
exports.handler = async (event) => {
  const { u, p, id, ext = 'mp4', type = 'movie' } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV = 'http://allinonestream.xyz:8080';

  const pathPrefix = type === 'series' ? 'series' : 'movie';
  const cdnPrefix  = type === 'series' ? 'xtream-series' : 'xtream-vod';

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

  /** Convierte URL absoluta de media server a ruta CDN proxy. */
  function toMediaProxy(url) {
    try {
      const { host, pathname, search } = new URL(url);
      const pathQ = pathname + (search || '');
      if (host === '216.106.177.68' || host === '216.106.177.68:80') return '/xtream-stream-hls' + pathQ;
      if (host === '23.237.74.2'    || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathQ;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74') return '/xtream-media'      + pathQ;
      if (host === '23.158.40.201'  || host === '23.158.40.201:80')  return '/xtream-vod-media'  + pathQ;
      return null; // host desconocido → fallback CDN self-loop
    } catch { return null; }
  }

  if (isLocal) {
    return {
      statusCode: 302,
      headers: {
        'Location': `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`,
        'Cache-Control': 'no-cache',
      },
      body: '',
    };
  }

  // ── FASE 1: GET+redirect:manual → capturar 302 Location de IPTV ────────────
  // GET funciona donde HEAD es rechazado a nivel TCP.
  // redirect:manual captura el 302 sin descargar el cuerpo del video.
  try {
    const resp = await fetchWithTimeout(
      `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'GET', redirect: 'manual', headers: fetchHeaders },
      4000,
    );
    const location = resp.headers.get('location') || '';
    if (location) {
      const proxyPath = toMediaProxy(location);
      if (proxyPath) {
        return {
          statusCode: 302,
          headers: {
            'Location': `${siteBase}${proxyPath}`,
            'Cache-Control': 'no-cache',
          },
          body: '',
        };
      }
      // Host desconocido en Location → redirigir directo (sin proxy)
      return {
        statusCode: 302,
        headers: { 'Location': location, 'Cache-Control': 'no-cache' },
        body: '',
      };
    }
    // Si IPTV responde 200 directo (sin token), caer al fallback CDN
  } catch (e) {
    // Timeout o IPs Lambda bloqueadas → fallback CDN
  }

  // ── FASE 2 (fallback): CDN self-loop ────────────────────────────────────────
  // El browser va a /xtream-vod/ → CDN proxies → IPTV → media server.
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
