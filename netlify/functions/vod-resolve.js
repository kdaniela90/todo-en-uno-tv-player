/**
 * vod-resolve.js — Netlify Function (v2)
 *
 * Resuelve la URL de streaming de un VOD/serie y redirige el navegador.
 *
 * Problema: el servidor IPTV devuelve 302 a un media server con token de sesion.
 * Si Netlify CDN pasa ese 302 al browser → URL HTTP → Mixed Content bloqueado.
 * Solucion: resolver los redirects server-side y redirigir via proxy CDN HTTPS.
 *
 * Estrategia (3 intentos):
 *   1 — HEAD directo al IPTV (redirect:manual): captura el 302 con token.
 *   2 — CDN self-loop (redirect:follow): Lambda sigue la cadena hasta el media server.
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
      if (host === '23.237.74.2'        || host === '23.237.74.2:80')    return '/xtream-live-relay' + pathWithQuery;
      if (host === '23.237.104.74:8080' || host === '23.237.104.74')     return '/xtream-media'      + pathWithQuery;
      if (host === '23.158.40.201'      || host === '23.158.40.201:80')  return '/xtream-vod-media'  + pathWithQuery;
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

  // Intento 1: HEAD directo al IPTV (redirect:manual)
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
            headers: { 'Location': `${siteBase}${proxyPath}`, 'Cache-Control': 'no-cache' },
            body: '',
          };
        }
      }
    }
  } catch (e) { /* continuar */ }

  // Intento 2: CDN self-loop con redirect:follow
  try {
    const resp = await fetchWithTimeout(
      `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      { method: 'HEAD', redirect: 'follow', headers: fetchHeaders },
      8000,
    );
    const finalUrl = resp.url || '';
    if (finalUrl && !finalUrl.includes(siteBase.replace('https://', '').replace('http://', ''))) {
      const proxyPath = toMediaProxy(finalUrl);
      if (proxyPath) {
        return {
          statusCode: 302,
          headers: { 'Location': `${siteBase}${proxyPath}`, 'Cache-Control': 'no-cache' },
          body: '',
        };
      }
    }
  } catch (e) { /* continuar */ }

  // Intento 3: Fallback proxy CDN directo
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
