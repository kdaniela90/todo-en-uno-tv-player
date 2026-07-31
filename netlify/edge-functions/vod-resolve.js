/**
 * netlify/edge-functions/vod-resolve.js
 *
 * Edge Function (Deno) — resuelve la URL de un VOD/serie y redirige al browser.
 *
 * POR QUÉ Edge Function en lugar de Lambda:
 *   Las IPs de AWS Lambda son frecuentemente bloqueadas por IPTV.
 *   Las Edge Functions corren en los mismos nodos CDN que ya hacen proxy
 *   de /xtream-vod/, /xtream-live/, etc. — IPs que IPTV ya acepta.
 *   Phase 1 (captura directa del token) funciona de forma confiable.
 *
 * Flujo:
 *   Phase 1 — GET+redirect:manual directo a IPTV (5s timeout)
 *     → Captura Location del 302 → convierte a ruta CDN estable → 302 al browser.
 *     → Browser usa esa URL fija en TODOS los Range Requests → seek funciona.
 *
 *   Phase 2 (fallback) — redirect a CDN proxy genérico.
 *     → CDN sigue la cadena completa en cada Range Request.
 *     → Seek puede fallar si IPTV rota tokens por Request, pero la reproducción lineal funciona.
 */

/** Mapea URL de media server a ruta CDN proxy (según netlify.toml). */
function toMediaProxy(rawUrl) {
  try {
    const { host, pathname, search } = new URL(rawUrl);
    const pathQ = pathname + (search || '');
    if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathQ;
    if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathQ;
    if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + pathQ;
    if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathQ;
    return null;
  } catch {
    return null;
  }
}

export default async function handler(request, context) {
  const url  = new URL(request.url);
  const u    = url.searchParams.get('u');
  const p    = url.searchParams.get('p');
  const id   = url.searchParams.get('id');
  const ext  = url.searchParams.get('ext')  || 'mp4';
  const type = url.searchParams.get('type') || 'movie';

  if (!u || !p || !id) {
    return new Response('Missing params: u, p, id', { status: 400 });
  }

  const siteBase   = 'https://player.todoenunotv.com';
  const IPTV       = 'http://allinonestream.xyz:8080';
  const pathPrefix = type === 'series' ? 'series' : 'movie';
  const cdnPrefix  = type === 'series' ? 'xtream-series' : 'xtream-vod';

  const iptvUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`;

  // ── Phase 1: GET+redirect:manual directo a IPTV ─────────────────────────────
  try {
    const controller = new AbortController();
    const tid = setTimeout(() => controller.abort(), 5000);

    const resp = await fetch(iptvUrl, {
      method: 'GET',
      redirect: 'manual',
      headers: { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      signal: controller.signal,
    });
    clearTimeout(tid);

    const loc = resp.headers.get('location') || '';
    if (loc) {
      const proxy = toMediaProxy(loc);
      if (proxy) {
        // Token capturado — URL estable para todos los Range Requests
        return Response.redirect(`${siteBase}${proxy}`, 302);
      }
    }
  } catch (_) {
    // Timeout o error de red → Phase 2
  }

  // ── Phase 2: CDN proxy genérico (fallback siempre HTTPS) ────────────────────
  return Response.redirect(`${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`, 302);
}

export const config = { path: '/api/vod-resolve' };
