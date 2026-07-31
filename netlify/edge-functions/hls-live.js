/**
 * netlify/edge-functions/hls-live.js
 *
 * Edge Function (Deno) — proxy HLS para canales en vivo, películas y series.
 *
 * PROBLEMA IDENTIFICADO (2025-07):
 *   Las Edge Functions tienen IPs propias (distintas a las del CDN proxy).
 *   IPTV bloquea las IPs de Edge Functions pero acepta las IPs del CDN.
 *   Evidencia: login funciona (usa /xtream-api/ → CDN IPs), live falla (fetch directo → Edge IPs).
 *
 * SOLUCIÓN — CDN self-loop:
 *   En lugar de fetchear IPTV directamente, usamos el CDN proxy /xtream-chunks/
 *   (que allinonestream.xyz comparte con todos los hosts desconocidos en _makeHlsLoader).
 *   El CDN sale con sus IPs propias → IPTV acepta la petición → M3U8 real.
 *
 * Flujo actualizado:
 *   GET /api/hls-live?u={user}&p={pass}&id={stream_id}[&type=live|movie|series]
 *   → Edge Function fetcha /xtream-chunks/{live|movie|series}/{u}/{p}/{id}.m3u8
 *     (CDN proxy → allinonestream.xyz:8080 usando IPs del CDN, no del Edge)
 *   → Si CDN pasa el 302: capturamos Location del media server → finalBase real
 *   → Si CDN absorbe el 302: recibimos M3U8 directamente → finalBase estimado
 *   → Reescribimos URLs de segmentos a rutas CDN proxy (netlify.toml)
 *   → Devolvemos M3U8 al browser con headers CORS
 */

const IPTV = 'http://allinonestream.xyz:8080';
const SITE = 'https://player.todoenunotv.com';

/**
 * Convierte una URL de segmento/playlist (que apunta a un servidor de media)
 * a la ruta CDN proxy equivalente definida en netlify.toml.
 * Así el browser pide los segmentos al mismo origen (HTTPS) sin Mixed Content.
 */
function toProxy(uri, finalBase) {
  if (!uri || uri.startsWith('/xtream') || uri.startsWith('data:') || uri.startsWith('blob:')) return uri;
  try {
    let abs;
    if (uri.startsWith('http'))       abs = uri;
    else if (uri.startsWith('/'))     abs = new URL(uri, IPTV).href;
    else                              abs = new URL(uri, finalBase).href;

    const { host, pathname } = new URL(abs);

    // Si ya apunta a nuestro propio dominio (CDN self-loop), retornar la pathname tal cual
    if (host === 'player.todoenunotv.com') return pathname + (new URL(abs).search || '');

    // Mapeo de hosts de media server → rutas CDN proxy (debe coincidir con netlify.toml)
    if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + pathname;
    if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + pathname;
    if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + pathname;
    // Cualquier otro host (incluido allinonestream.xyz) → /xtream-chunks
    return '/xtream-chunks' + pathname;
  } catch {
    return uri;
  }
}

/**
 * Reescribe todas las URIs dentro del M3U8:
 * - Líneas de segmentos (no empiezan con #)
 * - URI= en directivas #EXT-X-KEY y #EXT-X-MAP (encriptación, init segment)
 */
function rewriteM3U8(m3u8, finalBase) {
  m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
    const t = line.trim();
    return t ? toProxy(t, finalBase) : line;
  });
  m3u8 = m3u8.replace(
    /(#EXT-X-(?:KEY|MAP)[^\r\n]*URI=")([^"]+)(")/gm,
    (_, a, uri, b) => a + toProxy(uri, finalBase) + b,
  );
  return m3u8;
}

export default async function handler(request, _context) {
  const url  = new URL(request.url);
  const u    = url.searchParams.get('u');
  const p    = url.searchParams.get('p');
  const id   = url.searchParams.get('id');
  const type = url.searchParams.get('type') || 'live'; // live | movie | series

  if (!u || !p || !id) {
    return new Response('Parámetros faltantes: u, p, id', { status: 400 });
  }

  // Construir path según el tipo de contenido
  let pathPrefix;
  if (type === 'movie')       pathPrefix = 'movie';
  else if (type === 'series') pathPrefix = 'series';
  else                        pathPrefix = 'live';

  // CDN self-loop: fetchear vía /xtream-chunks/ para usar IPs del CDN (no del Edge Function)
  // /xtream-chunks/ está configurado en netlify.toml para proxear a allinonestream.xyz:8080
  const cdnProxyUrl = `${SITE}/xtream-chunks/${pathPrefix}/${u}/${p}/${id}.m3u8`;
  // URL base de IPTV para resolver URIs relativas en caso de que CDN absorba el redirect
  const iptvBase = `${IPTV}/${pathPrefix}/${u}/${p}/`;

  const controller = new AbortController();
  // 12s timeout total — cubre dos fetches si el CDN pasa el redirect
  const tid = setTimeout(() => controller.abort(), 12000);

  try {
    // ── Paso 1: Fetch vía CDN proxy con redirect:manual ──────────────────────
    // Si el CDN pasa el 302 de IPTV → recibimos Location del media server → finalBase real
    // Si el CDN absorbe el 302 internamente → recibimos 200 con el M3U8 directamente
    const resp1 = await fetch(cdnProxyUrl, {
      method:   'GET',
      redirect: 'manual',
      headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      signal:   controller.signal,
    });

    let text, finalBase;

    if (resp1.status >= 300 && resp1.status < 400) {
      // CDN pasó el redirect → capturar la URL real del media server
      const loc = resp1.headers.get('location') || '';
      if (!loc) {
        clearTimeout(tid);
        return new Response('Redirect de IPTV sin Location header', { status: 502 });
      }

      // finalBase = URL del media server → base correcta para segmentos relativos
      finalBase = loc.substring(0, loc.lastIndexOf('/') + 1);

      // ── Paso 2: Fetch del M3U8 real desde el media server vía CDN proxy ──
      const mediaProxyPath = toProxy(loc, iptvBase);
      const resp2 = await fetch(SITE + mediaProxyPath, {
        method:   'GET',
        redirect: 'follow',
        headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
        signal:   controller.signal,
      });
      clearTimeout(tid);

      if (!resp2.ok) {
        return new Response(`Media server error (${resp2.status})`, { status: resp2.status });
      }
      text = await resp2.text();

    } else if (resp1.status === 200) {
      // CDN absorbió el redirect y ya nos devolvió el M3U8
      text = await resp1.text();
      clearTimeout(tid);
      // finalBase estimado: IPTV path base (segmentos relativos → /xtream-chunks/ → IPTV)
      finalBase = iptvBase;

    } else {
      clearTimeout(tid);
      return new Response(`Stream no disponible (${resp1.status})`, { status: resp1.status });
    }

    if (!text || !text.includes('#EXTM3U')) {
      return new Response('El servidor no devolvió un stream HLS válido', { status: 502 });
    }

    return new Response(rewriteM3U8(text, finalBase), {
      headers: {
        'Content-Type':                'application/vnd.apple.mpegurl; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control':               'no-cache, no-store, must-revalidate',
      },
    });

  } catch (e) {
    clearTimeout(tid);
    const isTimeout = e instanceof Error && e.name === 'AbortError';
    return new Response(
      isTimeout ? 'Timeout: el servidor IPTV no respondió a tiempo' : `Error de red: ${e.message}`,
      { status: 504 },
    );
  }
}

// Netlify autodescubre este archivo desde netlify/edge-functions/ y lo registra en /api/hls-live
export const config = { path: '/api/hls-live' };
