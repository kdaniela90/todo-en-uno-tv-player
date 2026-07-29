/**
 * stream-debug.js — Netlify Function (TEMPORAL)
 * Uso: /.netlify/functions/stream-debug?u=USER&p=PASS
 * Prueba canales de distintas categorías para diagnosticar qué funciona.
 */
exports.handler = async (event) => {
  const { u, p, id: forcedId } = event.queryStringParameters || {};
  if (!u || !p) return { statusCode: 400, body: 'Missing params: u, p' };

  const siteBase = process.env.URL || 'https://player.todoenunotv.com';
  const IPTV = 'http://allinonestream.xyz:8080';
  const headers = { 'User-Agent': 'Mozilla/5.0', 'Accept': '*/*' };

  function fetchT(url, opts, ms = 5000) {
    return Promise.race([
      fetch(url, opts),
      new Promise((_, rej) => setTimeout(() => rej(new Error('timeout_' + ms + 'ms')), ms)),
    ]);
  }

  const report = {
    timestamp: new Date().toISOString(),
    siteBase,
    steps: {},
  };

  // Auth + obtener canales variados
  let channels = [];
  try {
    const r = await fetchT(`${IPTV}/player_api.php?username=${u}&password=${p}`, { headers }, 6000);
    const data = await r.json();
    report.auth = {
      ok: data.user_info?.auth === 1,
      expDate: data.user_info?.exp_date ? new Date(data.user_info.exp_date * 1000).toISOString().split('T')[0] : null,
    };
  } catch (e) { report.auth = { ok: false, error: e.message }; }

  // Obtener lista de canales y seleccionar uno de distintas categorías
  try {
    const r = await fetchT(`${IPTV}/player_api.php?username=${u}&password=${p}&action=get_live_streams`, { headers }, 10000);
    const all = await r.json();
    if (Array.isArray(all)) {
      // Si se pasó un ID específico, usarlo; si no, buscar canales de distintas categorías
      if (forcedId) {
        const ch = all.find(c => String(c.stream_id) === forcedId);
        channels = ch ? [ch] : [{ stream_id: forcedId, name: 'Canal manual', category_id: '?' }];
      } else {
        // Seleccionar el primer canal de hasta 4 categorías distintas
        const seen = new Set();
        for (const ch of all) {
          if (!seen.has(ch.category_id) && seen.size < 4) {
            seen.add(ch.category_id);
            channels.push(ch);
          }
        }
      }
    }
  } catch (e) { report.channelError = e.message; }

  report.testChannels = channels.map(c => ({ id: c.stream_id, name: c.name, cat: c.category_id }));

  // Probar cada canal
  const results = [];
  for (const ch of channels) {
    const cid = String(ch.stream_id);
    const result = { id: cid, name: ch.name, cat: ch.category_id };

    // Prueba directa (redirect:manual) - solo mira si el server responde
    try {
      const r = await fetchT(
        `${IPTV}/live/${u}/${p}/${cid}.m3u8`,
        { method: 'HEAD', redirect: 'manual', headers },
        4000,
      );
      result.direct_head = { status: r.status, location: r.headers.get('location') };
    } catch (e) { result.direct_head = { error: e.message }; }

    // Prueba via CDN proxy
    try {
      const r = await fetchT(
        `${siteBase}/xtream-live/${u}/${p}/${cid}.m3u8`,
        { method: 'HEAD', redirect: 'manual', headers },
        5000,
      );
      result.cdn_head = { status: r.status, location: r.headers.get('location') };
    } catch (e) { result.cdn_head = { error: e.message }; }

    // Prueba hls-proxy completo solo si alguna de las anteriores funcionó
    const headOk = result.direct_head?.status || result.cdn_head?.status;
    if (headOk) {
      try {
        const r = await fetchT(
          `${siteBase}/.netlify/functions/hls-proxy?u=${u}&p=${p}&id=${cid}`,
          { headers },
          8000,
        );
        const text = r.ok ? await r.text() : null;
        result.hls_proxy = {
          status: r.status,
          isM3U8: text?.includes('#EXTM3U') || false,
          preview: text?.split('\n').slice(0, 6).join('\n'),
        };
      } catch (e) { result.hls_proxy = { error: e.message }; }
    }

    results.push(result);
    // Pausa breve entre canales para no sobrecargar
    await new Promise(res => setTimeout(res, 200));
  }

  report.channelTests = results;
  report.summary = {
    anyDirectWorks: results.some(r => r.direct_head?.status),
    anyCdnWorks: results.some(r => r.cdn_head?.status),
    recommendation: results.some(r => r.direct_head?.status)
      ? 'Acceso directo OK — el problema es de reescritura de URLs en el M3U8'
      : results.some(r => r.cdn_head?.status)
        ? 'Solo CDN funciona — usar CDN self-loop sin Phase 1'
        : 'NINGUNA ruta funciona — el proveedor IPTV bloquea IPs cloud para streaming',
  };

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache' },
    body: JSON.stringify(report, null, 2),
  };
};
