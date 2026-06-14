/**
 * hls-proxy.js — Netlify Function
 *
 * Obtiene el .m3u8 del servidor IPTV via HTTPS (Cloudflare-fronted, cert válido)
 * y sigue el 302 interno al media server.  Reescribe los paths de segmentos
 * para que el browser los pida a través del redirect CDN de Netlify.
 *
 * Arquitectura descubierta (2026-06-15):
 *   • https://allinonestream.fans/live/u/p/id.m3u8
 *       → 302 → http://23.237.104.74:8080/live/play/SESSION_TOKEN/id
 *       → m3u8 con segmentos root-relative: /hls/TOKEN/SEGMENT.ts
 *   • Segmentos en http://23.237.104.74:8080/hls/TOKEN/SEGMENT.ts (HTTP 200 con tokens frescos)
 *   • Tokens son tiempo-limitados (~30 s), NO vinculados a IP
 *
 * Reescritura:
 *   /hls/TOKEN/SEG.ts          → /xtream-media/hls/TOKEN/SEG.ts
 *   http://23.x.x.x:8080/hls/ → /xtream-media/hls/
 *   http://allinone…/live/     → /xtream-live/
 *
 * Uso: /.netlify/functions/hls-proxy?u=USERNAME&p=PASSWORD&id=STREAM_ID
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};

  if (!u || !p || !id) {
    return { statusCode: 400, body: 'Missing params: u, p, id' };
  }

  // HTTP puerto 8080 → va DIRECTO al servidor NexonHost, BYPASEANDO Cloudflare WAF.
  // Cloudflare bloqueaba IPs de Netlify Lambda en el puerto 443 (HTTPS).
  // Puerto 8080 no tiene WAF → el Lambda puede conectar.
  // El servidor hace 302 al media server; fetch lo sigue automáticamente.
  const m3u8Url = `http://allinonestream.fans:8080/live/${u}/${p}/${id}.m3u8`;

  try {
    const resp = await fetch(m3u8Url, {
      redirect: 'follow',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    });

    if (!resp.ok) {
      return {
        statusCode: resp.status,
        body: `Upstream error: ${resp.status} for ${m3u8Url}`,
      };
    }

    let m3u8 = await resp.text();

    // ── Reescribir líneas de contenido (todo lo que no empiece con #) ──────────
    m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
      const t = line.trim();
      if (!t) return line;

      // Paths ya reescritos → no tocar
      if (t.startsWith('/xtream')) return line;

      // URL absoluta al media server (http://23.x.x.x:8080/hls/...)
      if (t.match(/^https?:\/\/\d+\.\d+\.\d+\.\d+:\d+\/hls\//)) {
        return t.replace(/^https?:\/\/[^/]+\/hls\//, '/xtream-media/hls/');
      }

      // URL absoluta al servidor principal (http://allinonestream.fans:.../live/...)
      if (t.match(/^https?:\/\/allinonestream\.fans/i)) {
        return t
          .replace(/^https?:\/\/allinonestream\.fans[^/]*\/live\//i, '/xtream-live/')
          .replace(/^https?:\/\/allinonestream\.fans[^/]*\/hls\//i, '/xtream-media/hls/');
      }

      // Cualquier otra URL absoluta http:// desconocida → proxy genérico
      if (t.startsWith('http')) {
        // Extraer path y redirigir via xtream-media (asume que es el media server)
        try {
          const url = new URL(t);
          return '/xtream-media' + url.pathname;
        } catch (_) {
          return line;
        }
      }

      // Root-relative: /hls/TOKEN/SEG.ts → /xtream-media/hls/TOKEN/SEG.ts
      if (t.startsWith('/hls/')) return '/xtream-media' + t;

      // Root-relative: /live/... → /xtream-live/...
      if (t.startsWith('/live/')) return '/xtream-live' + t.slice('/live'.length);

      // Relative sin slash: seg.ts → asumir pertenece al path /live/
      return `/xtream-live/${u}/${p}/${t}`;
    });

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
      },
      body: m3u8,
    };
  } catch (err) {
    return {
      statusCode: 500,
      body: `Proxy error: ${err.message}`,
    };
  }
};
