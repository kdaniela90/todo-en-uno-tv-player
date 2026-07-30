/**
 * netlify/edge-functions/vod-resolve.js
 *
 * Edge Function (Deno) — reemplaza la Lambda Function para resolver VOD.
 *
 * POR QUÉ Edge Function en lugar de Lambda:
 *   Las IPs de AWS Lambda (us-east-1) son frecuentemente bloqueadas por los
 *   servidores IPTV. Las Edge Functions de Netlify corren en los mismos nodos
 *   CDN que ya hacen proxy de /xtream-vod/, /xtream-live/, etc. → mismas IPs
 *   que IPTV ya acepta → Phase 1 (captura del token) funciona de forma confiable.
 *
 * Flujo:
 *   Phase 1 — GET+redirect:manual directo a IPTV (5s)
 *     → Captura Location del 302 → convierte a ruta CDN estable
 *     → 302 al browser → browser usa esa URL fija para TODOS los Range Requests
 *     → El token es estable → el seek funciona correctamente.
 *
 *   Phase 2 (fallback) — redirect a CDN proxy genérico
 *     → CDN sigue la cadena de redirects en cada Range Request
 *     → Puede fallar el seek si el proveedor rota tokens, pero es mejor que nada.
 */

/** Convierte URL de media server a ruta CDN proxy (según netlify.toml). */
function toMediaProxy(rawUrl) {
  try {
    const { host, pathname, search } = new URL(rawUrl);
    const pathQ = pathname + (search || '');
    if (host === '216.106.177.68'      || host === '216.106.177.68:80')  return '/xtream-stream-hls' + pathQ;
    if (host === '23.237.74.2'         || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathQ;
    if (host === '23.237.104.74:8080'  || host === '23.237.104.74')      return '/xtream-media'      + pathQ;
    if (host === '23.158.40.201'       || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathQ;
    return null; // Host desconocido → no redirigir a HTTP puro (Mixed Content)
  } catch {
    return null;
  }
}

export default async function handler(request, context) {
  const url = new URL(request.url);
  const u   = url.searchParams.get('u');
  const p   = url.searchParams.get('p');
  const id  = url.searchParams.get('id');
  const ext = url.searchParams.get('ext') || 'mp4';
  const type = url.searchParams.get('type') || 'movie';

  if (!u || !p || !id) {
    return new Response('Missing params: u, p, id', { status: 400 });
  }

  const siteBase   = 'https://player.todoenunotv.com';
  const IPTV       = 'http://allinonestream.xyz:8080';
  const pathPrefix = type === 'series' ? 'series' : 'movie';
  const cdnPrefix  = type === 'series' ? 'xtream-series' : 'xtream-vod';

  const iptвUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`;

  // ── Phase 1: GET+redirect:manual directo a IPTV ─────────────────────────────
  // Edge Function corre en IPs CDN → no bloqueadas por IPTV → captura el token.
  try {
    const controller = new AbortController();
    const tid = setTimeout(() => controller.abort(), 5000);

    const resp = await fetch(iptвUrl, {
      method: 'GET',
      redirect: 'manual',   // Solo el header Location, sin descargar el video
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Accept': '*/*',
      },
      signal: controller.signal,
    });
    clearTimeout(tid);

    const loc = resp.headers.get('location') || '';
    if (loc) {
      const proxy = toMediaProxy(loc);
      if (proxy) {
        // Token capturado — browser usará esta URL estable para todos los Range Requests
        return Response.redirect(`${siteBase}${proxy}`, 302);
      }
    }
    // 200 directo (sin token) o host desconocido → Phase 2
  } catch (_) {
    // Timeout o error de red → Phase 2
  }

  // ── Phase 2: CDN proxy genérico (fallback) ───────────────────────────────────
  // El CDN sigue la cadena IPTV→302→media server en cada Range Request.
  // Puede haber problemas de seek si el token rota, pero funciona para reproducción lineal.
  return Response.redirect(`${siteBase}/${cdnPrefix}/${u}/${p}/${id}.${ext}`, 302);
}

// Ruta donde Netlify sirve esta Edge Function
export const config = { path: '/api/vod-resolve' };
