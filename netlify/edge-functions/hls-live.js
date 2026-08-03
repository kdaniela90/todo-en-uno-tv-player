/**
 * netlify/edge-functions/hls-live.js
 *
 * Edge Function (Deno) — proxy HLS para canales en vivo (multiview + player principal).
 *
 * Flujo:
 *   GET /api/hls-live?u={user}&p={pass}&id={stream_id}[&type=live|movie|series]
 *   → Edge Function fetcha allinonestream.xyz:8080/{live|movie|series}/{u}/{p}/{id}.m3u8
 *   → IPTV responde 302 → media server → fetch sigue (redirect:'follow') → M3U8 real
 *   → Si el M3U8 es un MASTER playlist (#EXT-X-STREAM-INF):
 *       Seleccionar variante de mayor bandwidth y fetchearla internamente (secuencial,
 *       no en paralelo) → devolver el M3U8 de media directamente al browser.
 *       RAZÓN: sin esto el browser haría una segunda petición al media server para obtener
 *       la variante, lo que crea una 2ª sesión IPTV simultánea → canal en negro cuando
 *       el proveedor tiene límite max_connections=1.
 *   → Si el M3U8 es ya un media playlist: reescribir URLs de segmentos a CDN proxy.
 *   → Devolver M3U8 al browser con headers CORS.
 */

const IPTV = 'http://allinonestream.xyz:8080';

/**
 * Convierte una URL de segmento/playlist (que apunta a un servidor de media)
 * a la ruta CDN proxy equivalente definida en netlify.toml.
 */
function toProxy(uri, finalBase) {
  if (!uri || uri.startsWith('/xtream') || uri.startsWith('data:') || uri.startsWith('blob:')) return uri;
  try {
    let abs;
    if (uri.startsWith('http'))       abs = uri;
    else if (uri.startsWith('/'))     abs = new URL(uri, new URL(finalBase).origin).href;
    else                              abs = new URL(uri, finalBase).href;

    const { host, pathname, search } = new URL(abs);
    const qs = pathname + search;

    // Mapeo de hosts → rutas CDN proxy (debe coincidir con netlify.toml)
    if (host === '216.106.177.68'     || host === '216.106.177.68:80')  return '/xtream-stream-hls' + qs;
    if (host === '23.237.74.2'        || host === '23.237.74.2:80')     return '/xtream-live-relay' + qs;
    if (host === '23.237.104.74:8080' || host === '23.237.104.74')      return '/xtream-media'      + qs;
    if (host === '23.158.40.201'      || host === '23.158.40.201:80')   return '/xtream-vod-media'  + qs;
    // Cualquier otro host → /xtream-chunks (fallback)
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

/**
 * Si el M3U8 es un master playlist, retorna la URL absoluta de la variante
 * con mayor bandwidth. Retorna null si no es master o no hay variantes válidas.
 */
function pickBestVariant(masterText, baseUrl) {
  let bestBw = -1, bestUrl = null;
  const lines = masterText.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const bwMatch = line.match(/BANDWIDTH=(\d+)/i);
    const bw = bwMatch ? parseInt(bwMatch[1], 10) : 0;
    // La siguiente línea no-comentario es la URL de la variante
    let j = i + 1;
    while (j < lines.length && lines[j].trim().startsWith('#')) j++;
    const varLine = (lines[j] || '').trim();
    if (varLine && bw >= bestBw) {
      bestBw = bw;
      try {
        bestUrl = varLine.startsWith('http') ? varLine : new URL(varLine, baseUrl).href;
      } catch {}
    }
  }
  return bestUrl;
}

const HLS_HEADERS = {
  'Content-Type':                'application/vnd.apple.mpegurl; charset=utf-8',
  'Access-Control-Allow-Origin': '*',
  'Cache-Control':               'no-cache, no-store, must-revalidate',
};

export default async function handler(request, _context) {
  const url  = new URL(request.url);
  const u    = url.searchParams.get('u');
  const p    = url.searchParams.get('p');
  const id   = url.searchParams.get('id');
  const type = url.searchParams.get('type') || 'live'; // live | movie | series

  if (!u || !p || !id) {
    return new Response('Parámetros faltantes: u, p, id', { status: 400 });
  }

  const pathPrefix = type === 'movie' ? 'movie' : type === 'series' ? 'series' : 'live';
  const iptvUrl = `${IPTV}/${pathPrefix}/${u}/${p}/${id}.m3u8`;

  try {
    // ── Paso 1: obtener M3U8 desde IPTV (con redirect:'follow') ─────────────────
    const ctrl1 = new AbortController();
    const tid1  = setTimeout(() => ctrl1.abort(), 8000);

    const resp = await fetch(iptvUrl, {
      method:   'GET',
      redirect: 'follow',
      headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
      signal:   ctrl1.signal,
    });
    clearTimeout(tid1);

    if (!resp.ok) {
      return new Response(`Stream no disponible (${resp.status})`, { status: resp.status });
    }

    const text = await resp.text();
    if (!text || !text.includes('#EXTM3U')) {
      return new Response('El servidor no devolvió un stream HLS válido', { status: 502 });
    }

    const finalUrl  = resp.url || iptvUrl;
    const finalBase = finalUrl.substring(0, finalUrl.lastIndexOf('/') + 1);

    // ── Paso 2: detectar master playlist y resolver variante internamente ────────
    // Sin esto, el browser hace una 2ª petición al media server para la variante
    // → 2 sesiones IPTV simultáneas → canal bloqueado cuando max_connections=1.
    if (text.includes('#EXT-X-STREAM-INF')) {
      const variantUrl = pickBestVariant(text, finalBase);
      if (variantUrl) {
        try {
          const ctrl2 = new AbortController();
          const tid2  = setTimeout(() => ctrl2.abort(), 5000);

          const varResp = await fetch(variantUrl, {
            method:   'GET',
            redirect: 'follow',
            headers:  { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' },
            signal:   ctrl2.signal,
          });
          clearTimeout(tid2);

          if (varResp.ok) {
            const varText = await varResp.text();
            if (varText && varText.includes('#EXTM3U')) {
              const varFinalUrl  = varResp.url || variantUrl;
              const varFinalBase = varFinalUrl.substring(0, varFinalUrl.lastIndexOf('/') + 1);
              return new Response(rewriteM3U8(varText, varFinalBase), { headers: HLS_HEADERS });
            }
          }
          clearTimeout(tid2);
        } catch (_) {
          // Si la variante falla, caer al master reescrito (HLS.js lo gestiona)
        }
      }
    }

    // ── Paso 3: M3U8 de media (no es master) o fallback ─────────────────────────
    return new Response(rewriteM3U8(text, finalBase), { headers: HLS_HEADERS });

  } catch (e) {
    const isTimeout = e instanceof Error && e.name === 'AbortError';
    return new Response(
      isTimeout ? 'Timeout: el servidor IPTV no respondió a tiempo' : `Error de red: ${e.message}`,
      { status: 504 },
    );
  }
}

export const config = { path: '/api/hls-live' };
