/**
 * netlify/edge-functions/hls-live.js
 *
 * Edge Function (Deno) — proxy HLS para canales en vivo (multiview + player principal).
 *
 * POR QUÉ Edge Function en lugar de Lambda (hls-proxy.js):
 *   - Las IPs de AWS Lambda son bloqueadas parcialmente por IPTV → cold start + CDN self-loop = 6-8s
 *   - Las Edge Functions corren en los nodos CDN de Netlify: sin cold start, ~0ms warm-up
 *   - Las IPs de CDN no están bloqueadas por IPTV (lo confirma vod-resolve.js que ya usa este mismo approach)
 *   - Fetch directo a IPTV → seguir el redirect → M3U8 real en ~200-400ms
 *   - Resultado: multiview estable, canales cargan en <1s en lugar de 6-8s
 *
 * Flujo:
 *   GET /api/hls-live?u={user}&p={pass}&id={stream_id}
 *   → Edge Function fetcha allinonestream.xyz:8080/live/{u}/{p}/{id}.m3u8
 *   → IPTV responde 302 → media server (23.237.74.2/...)
 *   → fetch sigue el redirect (redirect:'follow') → obtiene M3U8 real
 *   → Reescribe URLs de segmentos a rutas CDN proxy (netlify.toml)
 *   → Devuelve M3U8 al browser con headers CORS
 */

const IPTV = 'http://allinonestream.xyz:8080';

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
    else if (uri.startsWith('/'))     abs = new URL(uri, new URL(finalBase).origin).href;
    else                              abs = new URL(uri, finalBase).href;

    const { host, pathname, search } = new URL(abs);

    // Mapeo de hosts → rutas CDN proxy (debe coincidir con netlify.toml)
    // search preserva query params (?token=...) que algunos servidores de media requieren para autenticación
    const qs = pathname + search;
    if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + qs;
    if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + qs;
    if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + qs;
    // Cualquier otro host (incluido allinonestream.xyz) → /xtream-chunks
    return '/xtream-chunks' + qs;
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

  // Construir path según tipo de contenido
  const pathPrefix = type === 'movie' ? 'movie' : type === 'series' ? 'series' : 'live';
  const iptvUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.m3u8`;

  try {
    const controller = new AbortController();
    // 8s timeout — suficiente para que IPTV responda, más corto que el Lambda (~10-15s)
    const tid = setTimeout(() => controller.abort(), 8000);

    const resp = await fetch(iptvUrl, {
      method:   'GET',
      redirect: 'follow',   // Sigue el 302 de IPTV → servidor de media → M3U8 real
      headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      signal:   controller.signal,
    });
    clearTimeout(tid);

    if (!resp.ok) {
      return new Response(`Stream no disponible (${resp.status})`, { status: resp.status });
    }

    const text = await resp.text();
    if (!text || !text.includes('#EXTM3U')) {
      return new Response('El servidor no devolvió un stream HLS válido', { status: 502 });
    }

    // resp.url = URL final tras seguir redirects (ej. http://23.237.74.2/live/play/{token}/{id}.m3u8)
    // La usamos como base para resolver URIs relativas en el M3U8
    const finalUrl  = resp.url || iptvUrl;
    const finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);

    return new Response(rewriteM3U8(text, finalBase), {
      headers: {
        'Content-Type':                'application/vnd.apple.mpegurl; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control':               'no-cache, no-store, must-revalidate',
      },
    });
  } catch (e) {
    const isTimeout = e instanceof Error && e.name === 'AbortError';
    return new Response(
      isTimeout ? 'Timeout: el servidor IPTV no respondió a tiempo' : `Error de red: ${e.message}`,
      { status: 504 },
    );
  }
}

// Netlify autodescubre este archivo desde netlify/edge-functions/ y lo registra en /api/hls-live
export const config = { path: '/api/hls-live' };
