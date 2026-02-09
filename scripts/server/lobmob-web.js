#!/usr/bin/env node
const http = require('http');
const https = require('https');
const { readFileSync, writeFileSync, existsSync } = require('fs');
const { execSync } = require('child_process');

const CERT_DIR = '/etc/lobmob/certs';
const CERT_FILE = CERT_DIR + '/cert.pem';
const KEY_FILE = CERT_DIR + '/key.pem';
const HAS_CERTS = existsSync(CERT_FILE) && existsSync(KEY_FILE);
const PORT = HAS_CERTS ? 443 : 8080;
const ENV_FILE = '/etc/lobmob/secrets.env';
const WEB_ENV = '/etc/lobmob/web.env';

function loadEnv(path) {
  if (!existsSync(path)) return {};
  const env = {};
  readFileSync(path, 'utf8').split('\n').forEach(line => {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) env[m[1]] = m[2];
  });
  return env;
}

function updateEnvVar(path, key, value) {
  if (!existsSync(path)) { writeFileSync(path, `${key}=${value}\n`); return; }
  let content = readFileSync(path, 'utf8');
  const re = new RegExp(`^${key}=.*$`, 'm');
  if (re.test(content)) {
    content = content.replace(re, `${key}=${value}`);
  } else {
    content += `\n${key}=${value}`;
  }
  writeFileSync(path, content);
}

function httpsPost(url, params, headers = {}) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(params).toString();
    const parsed = new URL(url);
    const req = https.request({
hostname: parsed.hostname, path: parsed.pathname,
method: 'POST',
headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': body.length, ...headers }
    }, res => {
let data = '';
res.on('data', c => data += c);
res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function fleetStatus() {
  try {
    const out = execSync('lobmob-fleet-status 2>/dev/null || echo "unavailable"', { timeout: 10000 }).toString();
    return out;
  } catch { return 'unavailable'; }
}

function fleetStatusJson() {
  try {
    const raw = execSync('lobmob-fleet-status --json 2>/dev/null', { timeout: 10000 }).toString();
    return JSON.parse(raw);
  } catch {
    // Fall back to parsing text output
    const text = fleetStatus();
    return { raw: text, parsed: false };
  }
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

const CSS = `
  :root {
    --bg: #0f1117;
    --surface: #1a1d27;
    --surface-hover: #222633;
    --border: #2a2e3d;
    --text: #e4e6ed;
    --text-muted: #8b8fa3;
    --accent: #e84142;
    --accent-glow: rgba(232, 65, 66, 0.15);
    --green: #34d399;
    --yellow: #fbbf24;
    --blue: #60a5fa;
    --radius: 12px;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
  }
  .container { max-width: 960px; margin: 0 auto; padding: 24px 20px; }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 20px 0; border-bottom: 1px solid var(--border); margin-bottom: 32px;
  }
  .logo { display: flex; align-items: center; gap: 12px; }
  .logo-icon { font-size: 36px; }
  .logo h1 { font-size: 24px; font-weight: 700; letter-spacing: -0.5px; }
  .logo span { color: var(--accent); }
  .header-actions { display: flex; gap: 8px; }
  .badge {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 12px; border-radius: 20px; font-size: 12px; font-weight: 600;
    background: var(--surface); border: 1px solid var(--border);
  }
  .badge-green { color: var(--green); border-color: rgba(52, 211, 153, 0.3); background: rgba(52, 211, 153, 0.08); }
  .badge-yellow { color: var(--yellow); border-color: rgba(251, 191, 36, 0.3); background: rgba(251, 191, 36, 0.08); }
  .badge-red { color: var(--accent); border-color: rgba(232, 65, 66, 0.3); background: var(--accent-glow); }
  .dot { width: 6px; height: 6px; border-radius: 50%; }
  .dot-green { background: var(--green); box-shadow: 0 0 6px var(--green); }
  .dot-yellow { background: var(--yellow); }
  .dot-red { background: var(--accent); box-shadow: 0 0 6px var(--accent); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 20px; transition: border-color 0.2s;
  }
  .card:hover { border-color: rgba(228, 230, 237, 0.15); }
  .card-label { font-size: 12px; text-transform: uppercase; letter-spacing: 1px; color: var(--text-muted); margin-bottom: 8px; }
  .card-value { font-size: 28px; font-weight: 700; }
  .card-sub { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
  .section { margin-bottom: 32px; }
  .section-title { font-size: 16px; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; gap: 8px; }
  .fleet-table { width: 100%; border-collapse: collapse; }
  .fleet-table th {
    text-align: left; padding: 10px 16px; font-size: 11px; text-transform: uppercase;
    letter-spacing: 1px; color: var(--text-muted); border-bottom: 1px solid var(--border);
    background: var(--surface);
  }
  .fleet-table td { padding: 12px 16px; border-bottom: 1px solid var(--border); font-size: 14px; }
  .fleet-table tr:hover td { background: var(--surface-hover); }
  .fleet-table-wrap {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); overflow: hidden;
  }
  .status-raw {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 20px; font-family: 'JetBrains Mono', 'Fira Code', monospace; font-size: 13px;
    line-height: 1.6; white-space: pre-wrap; overflow-x: auto; color: var(--text-muted);
  }
  .btn {
    display: inline-flex; align-items: center; gap: 8px;
    padding: 10px 20px; border-radius: 8px; font-size: 14px; font-weight: 500;
    text-decoration: none; transition: all 0.2s; cursor: pointer; border: none;
  }
  .btn-primary { background: var(--accent); color: white; }
  .btn-primary:hover { background: #d13536; box-shadow: 0 4px 12px var(--accent-glow); }
  .btn-ghost { background: transparent; color: var(--text-muted); border: 1px solid var(--border); }
  .btn-ghost:hover { background: var(--surface); color: var(--text); }
  footer {
    padding: 20px 0; border-top: 1px solid var(--border); margin-top: 40px;
    display: flex; justify-content: space-between; align-items: center;
    font-size: 12px; color: var(--text-muted);
  }
  .refresh-note { font-size: 12px; color: var(--text-muted); display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .btn-refresh {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 4px 12px; border-radius: 6px; font-size: 12px; font-weight: 500;
    background: var(--surface); border: 1px solid var(--border); color: var(--text-muted);
    cursor: pointer; transition: all 0.2s;
  }
  .btn-refresh:hover { background: var(--surface-hover); color: var(--text); border-color: rgba(228,230,237,0.15); }
  .btn-refresh:active { transform: scale(0.97); }
  .btn-refresh.spinning svg { animation: spin 0.8s linear infinite; }
  @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
  .loading { animation: pulse 1.5s ease-in-out infinite; }
  @media (max-width: 640px) {
    .grid { grid-template-columns: 1fr; }
    header { flex-direction: column; gap: 12px; align-items: flex-start; }
    .card-value { font-size: 22px; }
    .fleet-table { font-size: 13px; }
    .fleet-table th, .fleet-table td { padding: 8px 12px; }
  }
`;

function parseLobsters(raw) {
  // Try to parse fleet-status text into structured data
  const lines = raw.split('\\n').filter(l => l.trim());
  const lobsters = [];
  let current = null;
  for (const line of lines) {
    // Look for lobster entries like "lobster-xxx  active  10.13.37.x"
    const m = line.match(/^\\s*(lobster-\\S+|lobboss)\\s+(active|sleeping|standby|offline|provisioning|error)\\s*(.*)/i);
    if (m) {
current = { name: m[1], status: m[2].toLowerCase(), info: m[3].trim() };
lobsters.push(current);
    }
  }
  return lobsters;
}

function statusBadge(status) {
  const map = {
    active: '<span class="badge badge-green"><span class="dot dot-green"></span>Active</span>',
    sleeping: '<span class="badge"><span class="dot dot-yellow"></span>Sleeping</span>',
    standby: '<span class="badge badge-yellow"><span class="dot dot-yellow"></span>Standby</span>',
    offline: '<span class="badge"><span class="dot"></span>Offline</span>',
    provisioning: '<span class="badge badge-yellow"><span class="dot dot-yellow"></span>Provisioning</span>',
    error: '<span class="badge badge-red"><span class="dot dot-red"></span>Error</span>',
  };
  return map[status] || `<span class="badge">${status}</span>`;
}

function dashboardHtml(statusText) {
  const esc = (s) => s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const lobsters = parseLobsters(statusText);
  const uptime = formatUptime(process.uptime());
  const activeCount = lobsters.filter(l => l.status === 'active').length;
  const totalCount = lobsters.length;

  let fleetSection;
  if (lobsters.length > 0) {
    const rows = lobsters.map(l => `
<tr>
  <td style="font-weight:500">${esc(l.name)}</td>
  <td>${statusBadge(l.status)}</td>
  <td style="color:var(--text-muted)">${esc(l.info)}</td>
</tr>`).join('');
    fleetSection = `
<div class="fleet-table-wrap">
  <table class="fleet-table">
    <thead><tr><th>Name</th><th>Status</th><th>Details</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>
</div>`;
  } else {
    fleetSection = `<div class="status-raw" id="fleet-raw">${esc(statusText)}</div>`;
  }

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobmob — Fleet Dashboard</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container">
    <header>
<div class="logo">
  <span class="logo-icon">🦞</span>
  <h1>lob<span>mob</span></h1>
</div>
<div class="header-actions">
  <span class="badge badge-green"><span class="dot dot-green"></span>Online</span>
</div>
    </header>

    <div class="grid">
<div class="card">
  <div class="card-label">Fleet Size</div>
  <div class="card-value">${totalCount || '—'}</div>
  <div class="card-sub">${activeCount} active</div>
</div>
<div class="card">
  <div class="card-label">Uptime</div>
  <div class="card-value">${uptime}</div>
  <div class="card-sub">lobboss process</div>
</div>
<div class="card">
  <div class="card-label">Server</div>
  <div class="card-value" style="font-size:18px">lobboss</div>
  <div class="card-sub">WireGuard mesh</div>
</div>
    </div>

    <div class="section">
<div class="section-title">🦞 Fleet Status</div>
${fleetSection}
<div class="refresh-note" style="margin-top:12px">
  <span id="last-updated">Last updated: just now</span>
  <button class="btn-refresh" id="refresh-btn" onclick="manualRefresh()" title="Refresh now">
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M2.5 22v-6h6M2 11.5a10 10 0 0 1 18.8-4.3M22 12.5a10 10 0 0 1-18.8 4.2"/></svg>
    Refresh
  </button>
  <span>·</span>
  <span>Auto-refreshes every 30s</span>
  <span>·</span>
  <a href="/api/status" style="color:var(--blue);text-decoration:none">API</a>
</div>
    </div>

    <div class="section">
<div class="section-title">⚡ Quick Actions</div>
<div style="display:flex;gap:10px;flex-wrap:wrap">
  <a href="/oauth/digitalocean" class="btn btn-primary">Connect DigitalOcean</a>
  <a href="/health" class="btn btn-ghost">Health Check</a>
</div>
    </div>

    <footer>
<span>lobmob fleet management</span>
<span>port ${PORT}</span>
    </footer>
  </div>
  <script>
    let lastUpdatedAt = Date.now();

    function updateTimestamp() {
      const el = document.getElementById('last-updated');
      if (!el) return;
      const ago = Math.round((Date.now() - lastUpdatedAt) / 1000);
      if (ago < 5) el.textContent = 'Last updated: just now';
      else if (ago < 60) el.textContent = 'Last updated: ' + ago + 's ago';
      else el.textContent = 'Last updated: ' + Math.floor(ago / 60) + 'm ago';
    }

    async function doRefresh() {
      try {
        const r = await fetch('/api/status');
        if (!r.ok) return;
        lastUpdatedAt = Date.now();
        location.reload();
      } catch {}
    }

    async function manualRefresh() {
      const btn = document.getElementById('refresh-btn');
      if (btn) btn.classList.add('spinning');
      await doRefresh();
    }

    setInterval(updateTimestamp, 5000);
    setInterval(doRefresh, 30000);
  </script>
</body>
</html>`;
}

function oauthSuccessHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobmob — OAuth Complete</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container" style="display:flex;align-items:center;justify-content:center;min-height:80vh">
    <div style="text-align:center">
<div style="font-size:64px;margin-bottom:16px">✅</div>
<h2 style="margin-bottom:8px">DigitalOcean Connected</h2>
<p style="color:var(--text-muted);margin-bottom:24px">OAuth tokens have been stored. You can close this tab.</p>
<a href="/" class="btn btn-ghost">← Back to Dashboard</a>
    </div>
  </div>
</body>
</html>`;
}

function notFoundHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobmob — 404</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container" style="display:flex;align-items:center;justify-content:center;min-height:80vh">
    <div style="text-align:center">
<div style="font-size:64px;margin-bottom:16px">🦞</div>
<h2 style="margin-bottom:8px">Page Not Found</h2>
<p style="color:var(--text-muted);margin-bottom:24px">This lobster wandered off.</p>
<a href="/" class="btn btn-primary">← Back to Dashboard</a>
    </div>
  </div>
</body>
</html>`;
}

const handler = async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
    return;
  }

  if (url.pathname === '/api/status') {
    const data = fleetStatusJson();
    data.uptime = process.uptime();
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    res.end(JSON.stringify(data));
    return;
  }

  if (url.pathname === '/oauth/digitalocean') {
    const webEnv = loadEnv(WEB_ENV);
    const clientId = webEnv.DO_OAUTH_CLIENT_ID;
    if (!clientId) {
res.writeHead(500); res.end('DO_OAUTH_CLIENT_ID not configured in web.env'); return;
    }
    const proto = HAS_CERTS ? "https" : "http";
    const callbackUrl = proto + "://" + req.headers.host + "/oauth/digitalocean/callback";
    const authUrl = `https://cloud.digitalocean.com/v1/oauth/authorize?response_type=code&client_id=${clientId}&redirect_uri=${encodeURIComponent(callbackUrl)}&scope=read+write`;
    res.writeHead(302, { Location: authUrl });
    res.end();
    return;
  }

  if (url.pathname === '/oauth/digitalocean/callback') {
    const code = url.searchParams.get('code');
    if (!code) { res.writeHead(400); res.end('Missing code parameter'); return; }
    const webEnv = loadEnv(WEB_ENV);
    const proto = HAS_CERTS ? "https" : "http";
    const callbackUrl = proto + "://" + req.headers.host + "/oauth/digitalocean/callback";
    try {
const tokenRes = await httpsPost('https://cloud.digitalocean.com/v1/oauth/token', {
  grant_type: 'authorization_code',
  code,
  client_id: webEnv.DO_OAUTH_CLIENT_ID,
  client_secret: webEnv.DO_OAUTH_CLIENT_SECRET,
  redirect_uri: callbackUrl
});
const data = JSON.parse(tokenRes.body);
if (data.access_token) {
  updateEnvVar(ENV_FILE, 'DO_OAUTH_TOKEN', data.access_token);
  updateEnvVar(ENV_FILE, 'DO_OAUTH_REFRESH', data.refresh_token);
  res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(oauthSuccessHtml());
} else {
  res.writeHead(500); res.end('Token exchange failed: ' + tokenRes.body);
}
    } catch (e) {
res.writeHead(500); res.end('Error: ' + e.message);
    }
    return;
  }

  if (url.pathname === '/') {
    const status = fleetStatus();
    res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(dashboardHtml(status));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/html' }); res.end(notFoundHtml());
};

const server = HAS_CERTS
  ? https.createServer({ cert: readFileSync(CERT_FILE), key: readFileSync(KEY_FILE) }, handler)
  : http.createServer(handler);

server.listen(PORT, '0.0.0.0', () => {
  const proto = HAS_CERTS ? "https" : "http";
  console.log(`lobmob-web listening on ${proto}://0.0.0.0:${PORT}`);
});
