/**
 * hls-proxy.js — Netlify Function
 *
 * Obtiene el .m3u8 del servidor IPTV (HTTP) y reescribe los URLs de los
 * segmentos para que pasen por el proxy Netlify (/xtream-live/*).
 * Así el navegador nunca hace peticiones HTTP directas (mixed-content).
 *
 * Uso: /.netlify/functions/hls-proxy?u=USERNAME&p=PASSWORD&id=STREAM_ID
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};

  if (!u || !p || !id) {
    return { statusCode: 400, body: 'Missing params: u, p, id' };
  }

  const origin = 'http://allinonestream.fans:8080';
  const m3u8Url = `${origin}/live/${u}/${p}/${id}.m3u8`;

  try {
    const resp = await fetch(m3u8Url, {
      headers: { 'User-Agent': 'Mozilla/5.0' },
    });

    if (!resp.ok) {
      return { statusCode: resp.status, body: `Upstream error: ${resp.status}` };
    }

    let m3u8 = await resp.text();

    // 1. Reescribir URLs absolutas del servidor IPTV → proxy Netlify
    //    http://allinonestream.fans:8080/live/u/p/seg.ts → /xtream-live/u/p/seg.ts
    m3u8 = m3u8.replace(
      /https?:\/\/allinonestream\.fans:\d+\/live\//gi,
      '/xtream-live/'
    );

    // 2. Reescribir paths relativos en líneas de segmento (líneas que no empiezan con #)
    //    Ejemplo: "1234.ts" → "/xtream-live/USER/PASS/1234.ts"
    m3u8 = m3u8.replace(/^(?!#)([^\r\n]+)$/gm, (line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('http')) return line;     // ya es absoluto (fue reescrito arriba)
      if (trimmed.startsWith('/xtream')) return line;  // ya reescrito
      if (trimmed.startsWith('/live/')) {
        // Path absoluto en el servidor: /live/u/p/seg.ts → /xtream-live/u/p/seg.ts
        return '/xtream-live' + trimmed.slice('/live'.length);
      }
      // Path relativo: seg.ts → /xtream-live/u/p/seg.ts
      return `/xtream-live/${u}/${p}/${trimmed}`;
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
