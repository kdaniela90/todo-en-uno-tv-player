/**
 * netlify/edge-functions/vod-resolve.js
 *
 * Edge Function (Deno) — resuelve la URL final de un VOD/serie y devuelve JSON al browser.
 *
 * CAMBIO vs. versión anterior:
 *   Antes: devolvía HTTP 302 → browser seguía chain de redirects → terminaba con http://
 *          (Mixed Content bloqueado) cuando el media server no estaba en el mapa de IPs.
 *
 *   Ahora: devuelve JSON {url | error} que el cliente JS interpreta antes de tocar <video>:
 *   - {url: "https://..."}  → URL HTTPS segura lista para videoEl.src
 *   - {error, code}         → 'auth' (401/403), 'notfound' (404), 'timeout', 'server'
 *
 * Flujo:
 *   1. GET con redirect:'follow' a IPTV → resp.url = URL final (todos los hops resueltos)
 *   2. Body cancelado inmediatamente — no se descarga el archivo
 *   3. Si IPTV devuelve 401/403/404 → JSON de error con código HTTP real
 *   4. Si IP final está en mapa → {url: "https://player.../xtream-.../path?token"}
 *   5. Si IP numérica desconocida → {url: "/api/vod-stream?url=..."} (Edge proxy con Range)
 *   6. Si hostname no numérico (improbable) → {error: 'unresolved'}
 *
 * Seguridad:
 *   - Hosts desconocidos se loguean SIN usuario ni contraseña
 *   - /api/vod-stream valida que solo acepte IPs numéricas (no hostnames arbitrarios)
 */

/** Mapea URL de media server conocido a ruta CDN proxy HTTPS (según netlify.toml). */
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

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json',
};

function jsonResp(data) {
  return new Response(JSON.stringify(data), { status: 200, headers: CORS_HEADERS });
}

export default async function handler(request, _context) {
  const url  = new URL(request.url);
  const u    = url.searchParams.get('u');
  const p    = url.searchParams.get('p');
  const id   = url.searchParams.get('id');
  const ext  = url.searchParams.get('ext')  || 'mp4';
  const type = url.searchParams.get('type') || 'movie';

  if (!u || !p || !id) {
    return new Response(
      JSON.stringify({ error: 'params', code: 400 }),
      { status: 400, headers: CORS_HEADERS }
    );
  }

  const siteBase   = 'https://player.todoenunotv.com';
  const IPTV       = 'http://allinonestream.xyz:8080';
  const pathPrefix = type === 'series' ? 'series' : 'movie';

  // URL exacta según la API Xtream: /movie/{u}/{p}/{id}.{ext} o /series/{u}/{p}/{id}.{ext}
  const iptvUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.${ext}`;

  const controller = new AbortController();
  // 8s timeout — suficiente para que IPTV responda y siga el redirect al media server
  const tid = setTimeout(() => controller.abort(), 8000);

  try {
    const resp = await fetch(iptvUrl, {
      method:   'GET',
      redirect: 'follow',   // Seguir TODOS los hops → resp.url = URL final del media server
      headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      signal:   controller.signal,
    });
    clearTimeout(tid);

    // Cancelar body inmediatamente — solo necesitamos resp.url y resp.status
    try { if (resp.body) resp.body.cancel(); } catch (_) {}

    // ── Error HTTP real de IPTV — diagnóstico verificable ───────────────────────
    if (resp.status === 401 || resp.status === 403) {
      return jsonResp({ error: 'auth', code: resp.status });
    }
    if (resp.status === 404) {
      return jsonResp({ error: 'notfound', code: 404 });
    }
    if (!resp.ok) {
      return jsonResp({ error: 'server', code: resp.status });
    }

    // ── URL final del media server (tras todos los redirects) ────────────────────
    const finalUrl = resp.url || iptvUrl;

    // IP conocida → CDN proxy HTTPS estable (misma IP, token en la ruta)
    const proxy = toMediaProxy(finalUrl);
    if (proxy) {
      return jsonResp({ url: siteBase + proxy });
    }

    // IP numérica no mapeada → /api/vod-stream (reenvía Range requests, no descarga completo)
    // Loguear el host SIN credenciales para diagnóstico y futura adición al mapa
    try {
      const { hostname, host } = new URL(finalUrl);
      if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(hostname)) {
        console.log(`[vod-resolve] IP no mapeada: ${host} — type=${type} id=${id}`);
        return jsonResp({ url: `/api/vod-stream?url=${encodeURIComponent(finalUrl)}` });
      }
      // Hostname no numérico: improbable en IPTV
      console.log(`[vod-resolve] hostname inesperado: ${hostname} — type=${type} id=${id}`);
    } catch (_) {}

    return jsonResp({ error: 'unresolved', code: 502 });

  } catch (e) {
    clearTimeout(tid);
    const isTimeout = e instanceof Error && e.name === 'AbortError';
    return jsonResp(isTimeout
      ? { error: 'timeout' }
      : { error: 'network', message: String(e.message || '').substring(0, 100) }
    );
  }
}

export const config = { path: '/api/vod-resolve' };
