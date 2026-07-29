/**
 * vod-resolve.js — Netlify Function (v3)
 *
 * Fix v3:
 *  1. Intento 1 usaba HEAD → IPTV rechaza HEAD al nivel TCP ("fetch failed").
 *     Cambio: GET+redirect:manual. IPTV devuelve 302 sin enviar body del archivo,
 *     Lambda captura Location (URL del media server con token) sin descargar nada.
 *  2. Intento 2 cambia de HEAD a GET+redirect:follow + Range:bytes=0-0
 *     para que Lambda pueda obtener resp.url (streaming server) incluso si
 *     el IPTV rechaza HEAD.
 *  3. 216.106.177.68 agregado a toMediaProxy() (nuevo servidor de streaming).
 *
 * Estrategia:
 *   1 — GET+redirect:manual directo al IPTV: captura 302+Location sin descargar.
 *   2 — CDN self-loop GET+redirect:follow + Range: extrae resp.url del media server.
 *   3 — Fallback /xtream-vod/ (puede fallar con Mixed Content, ultimo recurso).
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
      return '/xtream-chunks' + pathWithQuery;
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

  // ── Intento 1: GET+redirect:manual directo al IPTV ──────────────────────────
  // FIX v3: HEAD era rechazado por IPTV al nivel TCP. GET+manual funciona:
  // IPTV responde 302 inmediatamente, Lambda lee el header Location sin seguir
  // el redirect ni descargar el archivo de video.
  try {
    const resp = await fetchWithTimeout(
      `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'GET', redirect: 'manual', headers: fetchHeaders },
      5000,
    );
    if (resp.status === 302) {
      const location = resp.headers.get('location') || '';
      if (location) {
        const proxyPath = toMediaProxy(location);
        if (proxyPath) {
          return {
            statusCode: 302,
            headers: { 'Location': `${siteBase}${proxyPath}`, 'Cache-Control': 'no-cache' },
            body: '',
          };
        }
      }
    }
    // status 200 → IPTV sirve directo sin redirect → continuar
  } catch (e) { /* continuar con CDN self-loop */ }

  // ── Intento 2: CDN self-loop GET+redirect:follow ─────────────────────────────
  // Lambda pide el archivo via CDN → Netlify CDN lo proxia al IPTV → IPTV devuelve
  // 302 → Netlify pasa el 302 a Lambda → Lambda (redirect:follow) lo sigue hasta
  // el media server. resp.url contiene la URL final del media server.
  // Range:bytes=0-0 limita el body descargado a 1 byte (solo nos importa resp.url).
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
    if (finalUrl && !finalUrl.includes(ourDomain)) {
      const proxyPath = toMediaProxy(finalUrl);
      if (proxyPath) {
        return {
          statusCode: 302,
          headers: { 'Location': `${siteBase}${proxyPath}`, 'Cache-Control': 'no-cache' },
          body: '',
        };
      }
    }
  } catch (e) { /* continuar con fallback */ }

  // ── Intento 3: Fallback proxy CDN directo ────────────────────────────────────
  // Ultimo recurso. Puede fallar con Mixed Content si IPTV devuelve 302 HTTP
  // al browser. Funciona si el IPTV sirve el archivo directamente (status 200).
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
