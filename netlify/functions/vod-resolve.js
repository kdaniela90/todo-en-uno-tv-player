/**
 * vod-resolve.js — Netlify Function
 *
 * Resuelve la URL de streaming de un VOD/serie y redirige el navegador.
 *
 * El servidor IPTV puede devolver 302 a un servidor de media distinto
 * (23.158.40.201) con un token de sesión. Para que las Range Requests del
 * video (seek) funcionen, hay que resolver el token UNA vez y redirigir el
 * navegador a esa URL fija, no al proxy genérico que re-generaría un token
 * diferente en cada Range Request.
 *
 * Estrategia:
 *   1. HEAD request directo al servidor IPTV para capturar el 302.
 *   2. Si hay 302 → redirigir al browser vía /xtream-vod-media/ (estable).
 *   3. Si no hay 302 (server sirve directo) o si Lambda IPs están bloqueadas
 *      → fallback: redirigir al proxy CDN /xtream-vod/ o /xtream-series/.
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
    'Accept': '*/*',
    'Connection': 'keep-alive',
  };

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

  // Intentar resolver el 302 directamente desde la función (5 s timeout).
  // Si el servidor IPTV devuelve 302 al media server con token, capturamos
  // ese token y lo pasamos al browser vía /xtream-vod-media/ (URL estable
  // para todas las Range Requests del video).
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 5000);

  try {
    const directUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`;
    const resp = await fetch(directUrl, {
      method: 'HEAD',
      redirect: 'manual',
      headers: fetchHeaders,
      signal: controller.signal,
    });
    clearTimeout(timeoutId);

    if (resp.status === 302) {
      const location = resp.headers.get('location') || '';
      if (location) {
        let tokenPath;
        try { tokenPath = new URL(location).pathname; }
        catch { tokenPath = location.startsWith('/') ? location : '/' + location; }
        return {
          statusCode: 302,
          headers: {
            'Location': `${siteBase}/xtream-vod-media${tokenPath}`,
            'Cache-Control': 'no-cache',
          },
          body: '',
        };
      }
    }
    // resp.status 200 → servidor sirve directo, sin token → fallback CDN
  } catch (e) {
    clearTimeout(timeoutId);
    // Lambda IPs bloqueadas o timeout → fallback CDN
  }

  // ── FALLBACK: proxy CDN (funciona si IPTV no usa tokens one-time-use) ──
  return {
    statusCode: 302,
    headers: {
      'Location': `${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`,
      'Cache-Control': 'no-cache',
    },
    body: '',
  };
};
