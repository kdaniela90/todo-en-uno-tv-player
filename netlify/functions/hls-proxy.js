/**
 * hls-proxy.js — Netlify Function
 *
 * PROBLEMA: Las IPs de Netlify Lambda están bloqueadas por el servidor IPTV
 * (tanto en allinonestream.fans:443 vía Cloudflare WAF, como en :8080 vía NexonHost).
 *
 * SOLUCIÓN: Self-loop via Netlify CDN.
 * Las IPs del CDN de Netlify NO están bloqueadas. Entonces el Lambda
 * llama a su propio CDN redirect (/xtream-live/ y /xtream-media/) que actúa
 * como puente hacia el servidor IPTV.
 *
 * Flujo:
 *   1. Lambda → /xtream-live/u/p/id.m3u8  (CDN proxy, redirect:manual)
 *      CDN fetch → allinonestream.fans:8080/live/u/p/id.m3u8 → 302 Location: TOKEN_URL
 *   2. Lambda extrae TOKEN_PATH de la Location header
 *   3. Lambda → /xtream-media/live/play/TOKEN/id  (CDN proxy al media server)
 *      CDN fetch → 23.237.104.74:8080/live/play/TOKEN/id → m3u8 con /hls/... paths
 *   4. Lambda reescribe /hls/TOKEN/SEG.ts → /xtream-media/hls/TOKEN/SEG.ts
 *   5. Devuelve m3u8 modificado al browser
 *
 * Segmentos: browser pide /xtream-media/hls/TOKEN/SEG.ts → CDN → 23.237.104.74:8080
 *
 * Uso: /.netlify/functions/hls-proxy?u=USERNAME&p=PASSWORD&id=STREAM_ID
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};

  if (!u || !p || !id) {
    return { statusCode: 400, body: 'Missing params: u, p, id' };
  }

  // URL base del propio sitio — el Lambda se llama a sí mismo via CDN.
  // Netlify inyecta URL_BASE automáticamente; fallback al dominio de producción.
  const siteBase = process.env.URL || 'https://player.todoenunotv.com';

  try {
    // ── PASO 1: Obtener el token de sesión via CDN (/xtream-live/ → auth server) ──
    // CDN usa IPs de Netlify edge (no bloqueadas), no IPs de Lambda (bloqueadas).
    const cdnAuthUrl = `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`;

    const authResp = await fetch(cdnAuthUrl, {
      redirect: 'manual',           // NO seguir el 302 — necesitamos la Location header
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    });

    // Esperamos un 302 con Location al media server
    if (authResp.status !== 302) {
      const body = await authResp.text().catch(() => '');
      return {
        statusCode: authResp.status,
        body: `Auth step failed: HTTP ${authResp.status} from ${cdnAuthUrl} | body: ${body.slice(0, 200)}`,
      };
    }

    const location = authResp.headers.get('location') || '';
    if (!location) {
      return { statusCode: 502, body: 'Auth step: got 302 but no Location header' };
    }

    // location = "http://23.237.104.74:8080/live/play/TOKEN/id"
    // Extraer el path (/live/play/TOKEN/id) para construir la URL via CDN
    let tokenPath;
    try {
      tokenPath = new URL(location).pathname;
    } catch (_) {
      // Si no es URL absoluta, usar como path directamente
      tokenPath = location.startsWith('/') ? location : '/' + location;
    }

    // ── PASO 2: Obtener el m3u8 real via CDN (/xtream-media/ → media server) ──
    const cdnMediaUrl = `${siteBase}/xtream-media${tokenPath}`;

    const m3u8Resp = await fetch(cdnMediaUrl, {
      redirect: 'follow',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    });

    if (!m3u8Resp.ok) {
      const body = await m3u8Resp.text().catch(() => '');
      return {
        statusCode: m3u8Resp.status,
        body: `Media step failed: HTTP ${m3u8Resp.status} from ${cdnMediaUrl} | body: ${body.slice(0, 200)}`,
      };
    }

    let m3u8 = await m3u8Resp.text();

    if (!m3u8.includes('#EXTM3U')) {
      return {
        statusCode: 502,
        body: `Media step: response is not a valid m3u8. Content: ${m3u8.slice(0, 300)}`,
      };
    }

    // ── PASO 3: Reescribir paths de segmentos para que pasen por CDN ──────────
    // Los segmentos en el m3u8 son root-relative: /hls/TOKEN/SEG.ts
    // Los reescribimos a: /xtream-media/hls/TOKEN/SEG.ts
    // El CDN redirect /xtream-media/* → http://23.237.104.74:8080/:splat los sirve.
    m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
      const t = line.trim();
      if (!t) return line;

      // Ya reescrito — no tocar
      if (t.startsWith('/xtream')) return line;

      // URL absoluta al media server (http://23.x.x.x:8080/hls/...)
      if (t.match(/^https?:\/\/\d+\.\d+\.\d+\.\d+:\d+\/hls\//)) {
        return t.replace(/^https?:\/\/[^/]+\/hls\//, '/xtream-media/hls/');
      }

      // URL absoluta al media server (/live/play/...)
      if (t.match(/^https?:\/\/\d+\.\d+\.\d+\.\d+:\d+\/live\//)) {
        return t.replace(/^https?:\/\/[^/]+\/live\//, '/xtream-media/live/');
      }

      // URL absoluta a allinonestream.fans
      if (t.match(/^https?:\/\/allinonestream\.fans/i)) {
        return t
          .replace(/^https?:\/\/allinonestream\.fans[^/]*\/live\//i, '/xtream-live/')
          .replace(/^https?:\/\/allinonestream\.fans[^/]*\/hls\//i, '/xtream-media/hls/');
      }

      // Cualquier otra URL absoluta → proxy genérico via xtream-media
      if (t.startsWith('http')) {
        try {
          return '/xtream-media' + new URL(t).pathname;
        } catch (_) {
          return line;
        }
      }

      // Root-relative: /hls/TOKEN/SEG.ts → /xtream-media/hls/TOKEN/SEG.ts
      if (t.startsWith('/hls/')) return '/xtream-media' + t;

      // Root-relative: /live/... → /xtream-media/live/...
      if (t.startsWith('/live/')) return '/xtream-media' + t;

      // Relativo sin slash: podría ser nombre de segmento
      return `/xtream-media/hls/${t}`;
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
