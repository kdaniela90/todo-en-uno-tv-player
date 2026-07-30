/**
 * vod-resolve.js — Netlify Function v6
 *
 * Resuelve la URL de streaming de un VOD/serie y redirige el navegador
 * a una ruta CDN estable para que las Range Requests funcionen correctamente.
 *
 * Problema raíz:
 *   IPTV responde a /movie/u/p/id.ext con 302 → media server con token de sesión.
 *   El token debe estar en la URL FINAL que el navegador usa para todas las
 *   Range Requests (seek). Si el navegador termina en /xtream-vod/ (proxy CDN
 *   que contacta IPTV en cada request), se genera un token nuevo cada vez → falla.
 *
 * Estrategia v6:
 *   Fase 1  — GET+redirect:manual directo a IPTV (4s, Lambda → IPTV)
 *     → Captura Location del 302 → toMediaProxy → 302 al browser a /xtream-vod-media/TOKEN.
 *     → Falla si IPs de Lambda están bloqueadas por IPTV.
 *
 *   Fase 1b — CDN self-loop con Range:bytes=0-0 (6s, Lambda → CDN → IPTV → media server)
 *     → CDN edge (IP no bloqueada) contacta IPTV → sigue el 302 → media server.
 *     → Con redirect:follow en Lambda, resp.url revela la URL final:
 *       • Si CDN pasa el 302 a Lambda → resp.url = media server → capturamos token.
 *       • Si CDN absorbe el 302 internamente → resp.url = nuestro dominio →
 *         el CDN ya maneja la cadena correctamente → Fase 2 también funcionará.
 *     → Range:bytes=0-0 evita descargar el video completo (solo 1 byte).
 *
 *   Fase 2 (fallback) — CDN proxy directo
 *     → Browser → /xtream-vod/ → CDN → IPTV → (CDN sigue el 302 o stream directo).
 *     → SIEMPRE HTTPS para evitar Mixed Content.
 *     → Puede tener problemas de token en Range Requests si CDN no absorbe el 302.
 *
 * NUNCA redirigimos a URLs HTTP puras (causaría Mixed Content en browser HTTPS).
 * Local: redirect 302 directo a IPTV.
 */
exports.handler = async (event) => {
  const { u, p, id, ext = 'mp4', type = 'movie' } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const isLocal  = siteBase.includes('localhost') || siteBase.includes('127.0.0.1');
  const IPTV     = 'http://allinonestream.xyz:8080';

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
      if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathQ;
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathQ;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + pathQ;
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathQ;
      return null; // Host desconocido → no redirigir a HTTP puro
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

  // ── FASE 1: GET+redirect:manual directo a IPTV (4s timeout) ─────────────────
  // GET funciona donde HEAD es rechazado a nivel TCP por IPTV.
  // redirect:manual captura el 302 sin descargar el cuerpo del video.
  try {
    const resp1 = await fetchWithTimeout(
      `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'GET', redirect: 'manual', headers: fetchHeaders },
      4000,
    );
    const loc1 = resp1.headers.get('location') || '';
    if (loc1) {
      const proxy1 = toMediaProxy(loc1);
      if (proxy1) {
        // Token capturado — redirigir browser a URL estable (todas las Range Requests usan el mismo token)
        return {
          statusCode: 302,
          headers: { 'Location': `${siteBase}${proxy1}`, 'Cache-Control': 'no-cache' },
          body: '',
        };
      }
      // Host desconocido en Location → NUNCA redirigir a HTTP (Mixed Content) → Fase 1b
    }
    // 200 directo de IPTV (sin token) → Fase 1b
  } catch (_) {
    // Timeout o IPs Lambda bloqueadas → Fase 1b
  }

  // ── FASE 1b: CDN self-loop con Range:bytes=0-0 (6s timeout) ─────────────────
  // Lambda llama al propio CDN → CDN edge (IP no bloqueada) contacta IPTV.
  // redirect:follow para que Lambda siga todos los redirects y resp.url sea la URL final.
  // Range:bytes=0-0 limita la descarga a 1 byte (evita traer el video entero a Lambda).
  try {
    const resp1b = await fetchWithTimeout(
      `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      {
        method: 'GET',
        redirect: 'follow',
        headers: { ...fetchHeaders, 'Range': 'bytes=0-0' },
      },
      6000,
    );
    const finalUrl = resp1b.url || '';
    const ourHost  = siteBase.replace(/^https?:\/\//, '');
    // Si resp.url salió de nuestro dominio → Lambda siguió redirect al media server → token!
    if (finalUrl && !finalUrl.includes(ourHost) && finalUrl.startsWith('http')) {
      const proxy1b = toMediaProxy(finalUrl);
      if (proxy1b) {
        return {
          statusCode: 302,
          headers: { 'Location': `${siteBase}${proxy1b}`, 'Cache-Control': 'no-cache' },
          body: '',
        };
      }
      // Host desconocido en finalUrl → Fase 2
    }
    // resp.url sigue siendo nuestro dominio → CDN manejó la cadena internamente → Fase 2 OK
  } catch (_) {
    // Timeout o error → Fase 2
  }

  // ── FASE 2: CDN proxy (fallback) ─────────────────────────────────────────────
  // Browser va directo a /xtream-vod/ → CDN → IPTV → (CDN sigue el 302 o stream directo).
  // SIEMPRE usamos siteBase (HTTPS) — nunca URLs HTTP puras (evita Mixed Content).
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
