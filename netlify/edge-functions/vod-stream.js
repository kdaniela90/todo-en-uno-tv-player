/**
 * netlify/edge-functions/vod-stream.js
 *
 * Edge Function (Deno) — proxy de streaming para servidores de media de IPTV
 * cuyo IP no está en el mapeo estático de netlify.toml.
 *
 * POR QUÉ existe esto:
 *   Netlify CDN proxy (status=200 en netlify.toml) NO sigue los redirects 302 del
 *   servidor destino — los pasa al browser como están. Si IPTV devuelve un 302 a
 *   una URL http:// (servidor de media), el browser la bloquea como Mixed Content
 *   y el video falla con MEDIA_ERR_SRC_NOT_FOUND (código 4).
 *
 *   vod-resolve.js captura la URL final del media server (con redirect:follow).
 *   Si ese IP no tiene una ruta CDN conocida → redirige aquí.
 *   Este Edge Function proxea la respuesta (incluyendo Range requests para seeking)
 *   desde HTTPS, eliminando el problema de Mixed Content.
 *
 * Flujo:
 *   GET /api/vod-stream?url={encodedMediaUrl}
 *   → Valida que la URL sea un IP numérico (media servers de IPTV siempre son IPs)
 *   → Fetcha el contenido del media server, reenviando el header Range si existe
 *   → Devuelve la respuesta con Content-Type correcto y headers CORS
 *
 * Seguridad:
 *   - Solo acepta URLs con hostname = IP numérico puro (sin hostnames arbitrarios)
 *   - No expone credenciales de IPTV (la URL del media server usa tokens, no user/pass)
 */

const NUMERIC_IP_RE = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/;

/** Mapeo de extensión → Content-Type para cuando el servidor devuelve octet-stream */
const EXT_TYPE = {
  mp4: 'video/mp4', m4v: 'video/mp4', mov: 'video/quicktime',
  mkv: 'video/x-matroska', avi: 'video/x-msvideo',
  ts: 'video/mp2t', m2ts: 'video/mp2t',
  webm: 'video/webm',
};

export default async function handler(request, _context) {
  const url = new URL(request.url);
  const target = url.searchParams.get('url');

  if (!target) {
    return new Response('Parámetro url requerido', { status: 400 });
  }

  let targetUrl;
  try {
    targetUrl = new URL(target);
  } catch {
    return new Response('URL inválida', { status: 400 });
  }

  // Seguridad: solo IPs numéricas (los media servers de IPTV nunca son hostnames)
  if (!NUMERIC_IP_RE.test(targetUrl.hostname)) {
    return new Response('Host no permitido', { status: 403 });
  }

  const controller = new AbortController();
  // 30s timeout — suficiente para que el media server inicie la respuesta
  const tid = setTimeout(() => controller.abort(), 30000);

  try {
    const fetchHeaders = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' };
    const rangeHeader = request.headers.get('Range');
    if (rangeHeader) fetchHeaders['Range'] = rangeHeader;

    const resp = await fetch(target, {
      method:   'GET',
      redirect: 'follow',
      headers:  fetchHeaders,
      signal:   controller.signal,
    });
    clearTimeout(tid);

    const outHeaders = new Headers();

    // Content-Type: usar el del servidor; si es genérico, inferir de la extensión
    let ct = resp.headers.get('Content-Type') || '';
    if (!ct.startsWith('video/') && !ct.startsWith('audio/')) {
      const ext = targetUrl.pathname.split('.').pop()?.toLowerCase() || '';
      ct = EXT_TYPE[ext] || 'video/mp4';
    }
    outHeaders.set('Content-Type', ct);
    outHeaders.set('Accept-Ranges', 'bytes');
    outHeaders.set('Access-Control-Allow-Origin', '*');
    outHeaders.set('Cache-Control', 'no-cache, no-store');

    const cr = resp.headers.get('Content-Range');
    if (cr) outHeaders.set('Content-Range', cr);
    const cl = resp.headers.get('Content-Length');
    if (cl) outHeaders.set('Content-Length', cl);

    return new Response(resp.body, {
      status:  resp.status,
      headers: outHeaders,
    });

  } catch (e) {
    clearTimeout(tid);
    const isTimeout = e instanceof Error && e.name === 'AbortError';
    return new Response(
      isTimeout ? 'Timeout al conectar con el servidor de media' : `Error: ${e.message}`,
      { status: 504 },
    );
  }
}

export const config = { path: '/api/vod-stream' };
