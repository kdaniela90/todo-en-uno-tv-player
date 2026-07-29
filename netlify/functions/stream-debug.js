/**
 * stream-debug.js — Netlify Function (TEMPORAL - solo para diagnóstico)
 * Uso: /.netlify/functions/stream-debug?u=USER&p=PASS
 * Auto-descubre un canal y prueba cada paso del proceso de streaming.
 */
exports.handler = async (event) => {
  const { u, p, id: forcedId } = event.queryStringParameters || {};
  if (!u || !p) return { statusCode: 400, body: 'Missing params: u, p' };

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

  // Paso 0: Verificar autenticación y obtener un canal de prueba
  let testId = forcedId || null;
  try {
    const authUrl = `${IPTV}/player_api.php?username=${u}&password=${p}`;
    const r = await fetchWithTimeout(authUrl, { headers: fetchHeaders }, 6000);
    if (r.ok) {
      const data = await r.json();
      report.steps.auth = {
        ok: true,
        status: r.status,
        auth: data.user_info?.auth,
        expDate: data.user_info?.exp_date
          ? new Date(data.user_info.exp_date * 1000).toISOString()
          : null,
        activeConnections: data.user_info?.active_cons,
        maxConnections: data.user_info?.max_connections,
      };

      if (!testId) {
        // Auto-descubrir un canal
        try {
          const chUrl = `${IPTV}/player_api.php?username=${u}&password=${p}&action=get_live_streams`;
          const cr = await fetchWithTimeout(chUrl, { headers: fetchHeaders }, 8000);
          if (cr.ok) {
            const channels = await cr.json();
            if (Array.isArray(channels) && channels.length > 0) {
              const ch = channels[0];
              testId = String(ch.stream_id);
              report.steps.auto_channel = {
                ok: true,
                totalChannels: channels.length,
                testChannel: { id: testId, name: ch.name, category_id: ch.category_id },
              };
            }
          }
        } catch (e) {
          report.steps.auto_channel = { ok: false, error: e.message };
        }
      }
    } else {
      report.steps.auth = { ok: false, status: r.status, error: 'Auth failed' };
    }
  } catch (e) {
    report.steps.auth = { ok: false, error: e.message };
  }

  if (!testId) {
    report.error = 'No se pudo obtener un canal de prueba. Verifica usuario/contraseña.';
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify(report, null, 2),
    };
  }

  report.testId = testId;

  // Paso 1: HEAD directo al IPTV (Phase 1 del hls-proxy v3)
  try {
    const r = await fetchWithTimeout(
      `${IPTV}/live/${u}/${p}/${testId}.m3u8`,
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

  // Paso 2: GET directo con redirect:follow (como v1 - para comparar)
  try {
    const r = await fetchWithTimeout(
      `${IPTV}/live/${u}/${p}/${testId}.m3u8`,
      { redirect: 'follow', headers: fetchHeaders },
      5000,
    );
    const text = r.ok ? await r.text() : null;
    report.steps.direct_fetch = {
      ok: r.ok,
      status: r.status,
      respUrl: r.url,
      isM3U8: text ? text.includes('#EXTM3U') : false,
      firstLines: text ? text.split('\n').slice(0, 10).join('\n') : null,
    };
  } catch (e) {
    report.steps.direct_fetch = { ok: false, error: e.message };
  }

  // Paso 3: CDN self-loop via /xtream-live/ (Phase 2 del hls-proxy v3)
  try {
    const r = await fetchWithTimeout(
      `${siteBase}/xtream-live/${u}/${p}/${testId}.m3u8`,
      { redirect: 'follow', headers: fetchHeaders },
      7000,
    );
    const text = r.ok ? await r.text() : null;
    report.steps.cdn_selfloop = {
      ok: r.ok,
      status: r.status,
      respUrl: r.url,
      isM3U8: text ? text.includes('#EXTM3U') : false,
      firstLines: text ? text.split('\n').slice(0, 10).join('\n') : null,
    };
  } catch (e) {
    report.steps.cdn_selfloop = { ok: false, error: e.message };
  }

  // Paso 4: Probar el hls-proxy completo
  try {
    const r = await fetchWithTimeout(
      `${siteBase}/.netlify/functions/hls-proxy?u=${u}&p=${p}&id=${testId}`,
      { headers: fetchHeaders },
      10000,
    );
    const text = r.ok ? await r.text() : null;
    report.steps.hls_proxy_full = {
      ok: r.ok,
      status: r.status,
      isM3U8: text ? text.includes('#EXTM3U') : false,
      firstLines: text ? text.split('\n').slice(0, 12).join('\n') : null,
    };
  } catch (e) {
    report.steps.hls_proxy_full = { ok: false, error: e.message };
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
