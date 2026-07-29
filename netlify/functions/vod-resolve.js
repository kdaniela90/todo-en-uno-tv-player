/**
 * vod-resolve.js — Netlify Function (v4)
 *
 * Fix v4: Elimina Intento 1 (Lambda→IPTV directo).
 *
 * Problema v3: Intento 1 hacía GET+redirect:manual desde Lambda a IPTV.
 * IPTV generaba un token ligado a la IP de Lambda (igual que el bug de
 * hls-proxy v5 con live streams). Al redirigir al browser a un CDN proxy
 * con ese token, el media server recibía la petición desde la IP de CDN edge
 * (distinta a Lambda) → rechazaba el token → 403 → "No se pudo cargar el video".
 *
 * Solución: ir directo al CDN self-loop (Intento 1 en v4 = Intento 2 en v3).
 * El CDN edge contacta a IPTV con su propia IP → token ligado a IP de CDN edge →
 * el browser pide el video a través del mismo CDN edge → IPs coinciden → funciona.
 *
 * Estrategia:
 *   1 — CDN self-loop GET+redirect:follow + Range:bytes=0-0
 *       Lambda pide /${cdnPrefix}/u/p/id.ext al CDN → CDN edge contacta IPTV
 *       → IPTV devuelve 302 → CDN pasa 302 a Lambda → Lambda sigue redirect
 *       → resp.url = URL del media server con token CDN-edge-IP-bound
 *       → redirigir al browser a CDN proxy de esa URL
 *   2 — Fallback: redirect directo al CDN self-loop (browser sigue el redirect)
 *       No necesita que Lambda descargue nada — el browser hace todo el trabajo.
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

  function toMediaProxy(url) {
    try {
      const { host, pathname, search } = new URL(url);
      const pathWithQuery = pathname + (search || '');
      if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathWithQuery;
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay'  + pathWithQuery;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'       + pathWithQuery;
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'   + pathWithQuery;
      // Host desconocido: null → no redirigir con token potencialmente inválido
      return null;
    } catch {
      return null;
    }
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

  // ── Intento 1: CDN self-loop GET+redirect:follow ─────────────────────────────
  // El CDN edge contacta a IPTV con su propia IP → token ligado a IP de CDN edge.
  // Lambda sigue el redirect y obtiene resp.url (URL final del media server).
  // Range:bytes=0-0 para evitar descargar el archivo completo (solo nos importa resp.url).
  // Nota: algunos media servers ignoran Range y responden con 200 + body completo;
  // en ese caso fetchWithTimeout corta a los 8s antes de que Lambda agote su límite.
  try {
    const resp = await fetchWithTimeout(
      `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      {
        method: 'GET',
        redirect: 'follow',
        headers: { ...fetchHeaders, 'Range': 'bytes=0-0' },
      },
      8000,
    );
    const finalUrl = resp.url || '';
    const ourDomain = siteBase.replace('https://', '').replace('http://', '');
    if (finalUrl && !finalUrl.includes(ourDomain) && finalUrl.startsWith('http')) {
      const proxyPath = toMediaProxy(finalUrl);
      if (proxyPath) {
        return {
          statusCode: 302,
          headers: { 'Location': `${siteBase}${proxyPath}`, 'Cache-Control': 'no-cache' },
          body: '',
        };
      }
    }
  } catch (e) { /* timeout o error de red → fallback */ }

  // ── Intento 2: Fallback — redirect directo al CDN self-loop ──────────────────
  // El browser sigue el redirect a /xtream-vod/u/p/id.ext.
  // Netlify CDN proxia al IPTV → IPTV devuelve 302 al media server →
  // Netlify (status=200 force=true) sirve el video directamente al browser.
  // El token es generado por la IP del CDN edge que contactó al IPTV,
  // y el browser pide el video al mismo CDN → IPs coinciden → funciona.
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
