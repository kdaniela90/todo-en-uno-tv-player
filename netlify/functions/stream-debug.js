/**
 * stream-debug.js — Netlify Function (TEMPORAL - solo para diagnóstico)
 * Uso: /.netlify/functions/stream-debug?u=USER&p=PASS&id=CHANNEL_ID
 * Devuelve JSON con el estado de cada paso del proceso de streaming.
 */
exports.handler = async (event) => {
  const { u, p, id } = event.queryStringParameters || {};
  if (!u || !p || !id) return { statusCode: 400, body: 'Missing params: u, p, id' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const IPTV = 'http://allinonestream.xyz:8080';
  const report = { timestamp: new Date().toISOString(), siteBase, steps: {} };

  const fetchHeaders = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*', 'Connection': 'keep-alive' };

  function fetchWithTimeout(url, opts, ms) {
    return Promise.race([
      fetch(url, opts),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout_' + ms + 'ms')), ms)),
    ]);
  }

  // Paso 1: HEAD directo al IPTV
  try {
    const r = await fetchWithTimeout(
      `${IPTV}/live/${u}/${p}/${id}.m3u8`,
      { method: 'HEAD', redirect: 'manual', headers: fetchHeaders },
      4000,
    );
    const location = r.headers.get('location');
    report.steps.phase1_head = {
      ok: true,
      status: r.status,
      location: location || null,
      finalBase: location ? location.substring(0, location.lastIndexOf('/') + 1) : null,
    };
  } catch (e) {
    report.steps.phase1_head = { ok: false, error: e.message };
  }

  // Paso 2: GET directo al IPTV con redirect:follow (como v1)
  try {
    const r = await fetchWithTimeout(
      `${IPTV}/live/${u}/${p}/${id}.m3u8`,
      { redirect: 'follow', headers: fetchHeaders },
      5000,
    );
    const text = r.ok ? await r.text() : null;
    report.steps.direct_fetch = {
      ok: r.ok,
      status: r.status,
      respUrl: r.url,
      isM3U8: text ? text.includes('#EXTM3U') : false,
      firstLines: text ? text.split('\n').slice(0, 8).join('\n') : null,
    };
  } catch (e) {
    report.steps.direct_fetch = { ok: false, error: e.message };
  }

  // Paso 3: CDN self-loop via /xtream-live/
  try {
    const r = await fetchWithTimeout(
      `${siteBase}/xtream-live/${u}/${p}/${id}.m3u8`,
      { redirect: 'follow', headers: fetchHeaders },
      7000,
    );
    const text = r.ok ? await r.text() : null;
    report.steps.cdn_selfloop = {
      ok: r.ok,
      status: r.status,
      respUrl: r.url,
      isM3U8: text ? text.includes('#EXTM3U') : false,
      firstLines: text ? text.split('\n').slice(0, 8).join('\n') : null,
    };
  } catch (e) {
    report.steps.cdn_selfloop = { ok: false, error: e.message };
  }

  // Paso 4: Verificar proxy CDN /xtream-live-relay/ (acceso directo a 23.237.74.2)
  try {
    const r = await fetchWithTimeout(
      `${siteBase}/xtream-live-relay/live/${u}/${p}/${id}.m3u8`,
      { method: 'HEAD', redirect: 'manual', headers: fetchHeaders },
      4000,
    );
    report.steps.live_relay_probe = {
      ok: true,
      status: r.status,
      location: r.headers.get('location'),
    };
  } catch (e) {
    report.steps.live_relay_probe = { ok: false, error: e.message };
  }

  return {
    statusCode: 200,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-cache',
    },
    body: JSON.stringify(report, null, 2),
  };
};
