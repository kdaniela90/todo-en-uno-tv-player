/**
 * vod-resolve.js — Netlify Function (v2)
 *
 * Resuelve la URL de streaming de un VOD/serie y redirige el navegador.
 *
 * Problema original:
 *   El servidor IPTV devuelve 302 a un media server (23.158.40.201) con token
 *   de sesión. Si Netlify CDN pasa ese 302 al browser → URL HTTP → Mixed Content.
 *   Solución: resolver la cadena de redirects server-side (Lambda) y redirigir
 *   al browser via proxy CDN HTTPS (/xtream-vod-media/) que ya conocemos.
 *
 * Estrategia (3 intentos):
 *   Intento 1 — HEAD directo al IPTV (redirect:manual):
 *     Lambda toca solo allinonestream.xyz:8080. Si devuelve 302 con token,
 *     capturamos la Location y redirigimos browser a /xtream-vod-media/{path+token}.
 *   Intento 2 — CDN self-loop (redirect:follow):
 *     Lambda llama a ${siteBase}/xtream-vod/ → Netlify CDN proxia a IPTV.
 *     IPTV devuelve 302 → Netlify pasa el 302 a Lambda → Lambda lo sigue hasta
 *     la URL final del media server. resp.url contiene esa URL real.
 *     Convertimos al proxy CDN correcto y redirigimos el browser.
 *   Intento 3 — Fallback directo /xtream-vod/:
 *     Puede fallar con Mixed Content si el IPTV usa tokens one-time-use,
 *     pero funciona si el servidor sirve el archivo directamente (sin 302).
 *
 * Local: redirect 302 directo al servidor IPTV.
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

  /**
   * Convierte una URL absoluta de media server a la ruta de proxy CDN correcta.
   * Incluye el query string (tokens de sesión) en la ruta.
   */
  function toMediaProxy(url) {
    try {
      const { host, pathname, search } = new URL(url);
      const pathWithQuery = pathname + (search || '');
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathWithQuery;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')     return '/xtream-media'      + pathWithQuery;
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')  return '/xtream-vod-media'  + pathWithQuery;
      return '/xtream-chunks' + pathWithQuery;
    } catch {
      return null;
    }
  }

  // ── ENTORNO LOCAL ─────────────────────────────────────────────────────────
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

  // ── MODO PRODUCCIÓN ────────────────────────────────────────────────────────

  // ── Intento 1: HEAD directo al IPTV (redirect:manual) ───────────────────
  // Lambda toca solo allinonestream.xyz:8080. Si devuelve 302, capturamos
  // la URL del media server con token y la mapeamos al proxy CDN correcto.
  try {
    const resp = await fetchWithTimeout(
      `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'HEAD', redirect: 'manual', headers: fetchHeaders },
      5000,
    );
    if (resp.status === 302) {
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
      }
    }
    // status 200 → servidor sirve directo sin token → continuar con CDN self-loop
  } catch (e) {
    // Lambda IPs bloqueadas o timeout → continuar con CDN self-loop
  }

  // ── Intento 2: CDN self-loop con redirect:follow ─────────────────────────
  // Lambda llama a /xtream-vod/ → Netlify CDN → IPTV → 302.
  // Netlify pasa el 302 a Lambda (no lo sigue él) → fetch con redirect:follow
  // lo sigue directamente hasta el media server. resp.url es la URL final.
  // Convertimos resp.url al proxy CDN correcto y redirigimos el browser.
  try {
    const resp = await fetchWithTimeout(
      `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'HEAD', redirect: 'follow', headers: fetchHeaders },
      8000,
    );
    const finalUrl = resp.url || '';
    // Si resp.url NO es nuestro propio dominio, es la URL real del media server
    if (finalUrl && !finalUrl.includes(siteBase.replace('https://', '').replace('http://', ''))) {
      const proxyPath = toMediaProxy(finalUrl);
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
    }
  } catch (e) {
    // CDN self-loop falló → fallback
  }

  // ── Intento 3 — Fallback: proxy CDN directo ──────────────────────────────
  // Puede fallar con Mixed Content si el IPTV usa tokens (Netlify pasa el 302
  // al browser → URL HTTP → Mixed Content). Funciona si el servidor sirve
  // directo (status 200) sin redirigir. Último recurso.
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
