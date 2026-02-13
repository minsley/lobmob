#!/usr/bin/env node
const http = require('http');
const https = require('https');
const { readFileSync, existsSync } = require('fs');

const PORT = 8080;
const NAMESPACE = 'lobmob';
const HEALTH_FILE = '/tmp/health/status.json';

// k8s service account credentials (mounted automatically in pods)
const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const SA_TOKEN_PATH = SA_DIR + '/token';
const SA_CA_PATH = SA_DIR + '/ca.crt';
const K8S_HOST = process.env.KUBERNETES_SERVICE_HOST || 'kubernetes.default.svc';
const K8S_PORT = process.env.KUBERNETES_SERVICE_PORT || '443';

function k8sGet(path) {
  return new Promise((resolve, reject) => {
    let token, ca;
    try {
      token = readFileSync(SA_TOKEN_PATH, 'utf8').trim();
      ca = readFileSync(SA_CA_PATH);
    } catch (e) {
      reject(new Error('Not running in k8s (no service account): ' + e.message));
      return;
    }
    const options = {
      hostname: K8S_HOST,
      port: parseInt(K8S_PORT, 10),
      path: path,
      method: 'GET',
      headers: { 'Authorization': 'Bearer ' + token },
      ca: ca,
    };
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(data)); } catch { resolve(data); }
        } else {
          reject(new Error('k8s API ' + res.statusCode + ': ' + data.slice(0, 200)));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(10000, () => { req.destroy(); reject(new Error('k8s API timeout')); });
    req.end();
  });
}

async function getFleetData() {
  const result = { jobs: [], stats: { total: 0, running: 0, succeeded: 0, failed: 0, pending: 0 } };

  let jobs, pods;
  try {
    [jobs, pods] = await Promise.all([
      k8sGet('/apis/batch/v1/namespaces/' + NAMESPACE + '/jobs?labelSelector=app.kubernetes.io/name=lobster'),
      k8sGet('/api/v1/namespaces/' + NAMESPACE + '/pods?labelSelector=app.kubernetes.io/name=lobster'),
    ]);
  } catch (e) {
    result.error = e.message;
    return result;
  }

  // Index pods by job-name label
  const podsByJob = {};
  for (const pod of (pods.items || [])) {
    const jobName = (pod.metadata.labels || {})['job-name'];
    if (jobName) {
      if (!podsByJob[jobName]) podsByJob[jobName] = [];
      podsByJob[jobName].push(pod);
    }
  }

  for (const job of (jobs.items || [])) {
    const name = job.metadata.name;
    const labels = job.metadata.labels || {};
    const taskId = labels['lobmob.io/task-id'] || '?';
    const lobsterType = labels['lobmob.io/lobster-type'] || '?';

    let status;
    if (job.status.succeeded > 0) status = 'succeeded';
    else if (job.status.failed > 0) status = 'failed';
    else if (job.status.active > 0) status = 'running';
    else status = 'pending';

    result.stats[status] = (result.stats[status] || 0) + 1;
    result.stats.total++;

    // Age
    let age = '';
    if (job.metadata.creationTimestamp) {
      const ms = Date.now() - new Date(job.metadata.creationTimestamp).getTime();
      const mins = Math.floor(ms / 60000);
      if (mins >= 60) age = Math.floor(mins / 60) + 'h' + (mins % 60) + 'm';
      else age = mins + 'm';
    }

    // Logs for running/failed pods
    let logs = '';
    if ((status === 'running' || status === 'failed') && podsByJob[name]) {
      const pod = podsByJob[name][0];
      try {
        const logData = await k8sGet('/api/v1/namespaces/' + NAMESPACE + '/pods/' + pod.metadata.name + '/log?container=lobster&tailLines=5');
        if (typeof logData === 'string') logs = logData.trim().slice(-500);
        else logs = JSON.stringify(logData).slice(-500);
      } catch { /* ignore log errors */ }
    }

    result.jobs.push({ name, taskId, type: lobsterType, status, age, logs });
  }

  return result;
}

function readHealthStatus() {
  try {
    if (existsSync(HEALTH_FILE)) {
      return JSON.parse(readFileSync(HEALTH_FILE, 'utf8'));
    }
  } catch { /* ignore */ }
  return null;
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
  if (h > 0) return h + 'h ' + m + 'm';
  return m + 'm';
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
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
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
  .logs-cell {
    font-family: 'JetBrains Mono', 'Fira Code', monospace; font-size: 11px;
    color: var(--text-muted); white-space: pre-wrap; max-width: 300px;
    overflow: hidden; text-overflow: ellipsis;
  }
  .btn {
    display: inline-flex; align-items: center; gap: 8px;
    padding: 10px 20px; border-radius: 8px; font-size: 14px; font-weight: 500;
    text-decoration: none; transition: all 0.2s; cursor: pointer; border: none;
  }
  .btn-ghost { background: transparent; color: var(--text-muted); border: 1px solid var(--border); }
  .btn-ghost:hover { background: var(--surface); color: var(--text); }
  footer {
    padding: 20px 0; border-top: 1px solid var(--border); margin-top: 40px;
    display: flex; justify-content: space-between; align-items: center;
    font-size: 12px; color: var(--text-muted);
  }
  .health-grid { display: flex; gap: 12px; flex-wrap: wrap; }
  .health-item {
    display: flex; align-items: center; gap: 6px;
    padding: 8px 14px; border-radius: 8px;
    background: var(--surface); border: 1px solid var(--border); font-size: 13px;
  }
  .refresh-note { font-size: 12px; color: var(--text-muted); }
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

function statusBadge(status) {
  const map = {
    running: '<span class="badge badge-green"><span class="dot dot-green"></span>Running</span>',
    succeeded: '<span class="badge"><span class="dot dot-green"></span>Succeeded</span>',
    pending: '<span class="badge badge-yellow"><span class="dot dot-yellow"></span>Pending</span>',
    failed: '<span class="badge badge-red"><span class="dot dot-red"></span>Failed</span>',
  };
  return map[status] || '<span class="badge">' + status + '</span>';
}

function healthDot(ok) {
  return ok
    ? '<span class="dot dot-green"></span>'
    : '<span class="dot dot-red"></span>';
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function dashboardHtml(fleet, health) {
  const uptime = formatUptime(process.uptime());
  const s = fleet.stats;

  // Health status card
  let healthSection = '';
  if (health) {
    healthSection = `
      <div class="card">
        <div class="card-label">Health</div>
        <div class="health-grid">
          <span class="health-item">${healthDot(health.anthropic)}Anthropic</span>
          <span class="health-item">${healthDot(health.github)}GitHub</span>
          <span class="health-item">${healthDot(health.discord)}Discord</span>
        </div>
        <div class="card-sub">${health.checked_at ? 'Checked ' + new Date(health.checked_at).toLocaleTimeString() : ''}</div>
      </div>`;
  }

  // Fleet table
  let fleetSection;
  if (fleet.jobs.length > 0) {
    const rows = fleet.jobs.map(j => `
<tr>
  <td style="font-weight:500">${esc(j.name)}</td>
  <td>${esc(j.type)}</td>
  <td>${esc(j.taskId)}</td>
  <td>${statusBadge(j.status)}</td>
  <td style="color:var(--text-muted)">${esc(j.age)}</td>
  <td class="logs-cell">${j.logs ? esc(j.logs) : '<span style="color:var(--text-muted)">—</span>'}</td>
</tr>`).join('');
    fleetSection = `
<div class="fleet-table-wrap">
  <table class="fleet-table">
    <thead><tr><th>Name</th><th>Type</th><th>Task</th><th>Status</th><th>Age</th><th>Logs</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>
</div>`;
  } else if (fleet.error) {
    fleetSection = '<div class="card"><div class="card-sub">Error fetching fleet data: ' + esc(fleet.error) + '</div></div>';
  } else {
    fleetSection = '<div class="card"><div class="card-sub">No active lobster jobs</div></div>';
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
        <span class="logo-icon">&#x1F99E;</span>
        <h1>lob<span>mob</span></h1>
      </div>
      <div class="header-actions">
        <span class="badge badge-green"><span class="dot dot-green"></span>Online</span>
      </div>
    </header>

    <div class="grid">
      <div class="card">
        <div class="card-label">Fleet Size</div>
        <div class="card-value">${s.total || '—'}</div>
        <div class="card-sub">${s.running} running</div>
      </div>
      <div class="card">
        <div class="card-label">Uptime</div>
        <div class="card-value">${uptime}</div>
        <div class="card-sub">lobboss process</div>
      </div>
      <div class="card">
        <div class="card-label">Server</div>
        <div class="card-value" style="font-size:18px">lobboss</div>
        <div class="card-sub">Kubernetes</div>
      </div>
      ${healthSection}
    </div>

    <div class="section">
      <div class="section-title">&#x1F99E; Fleet Status</div>
      ${fleetSection}
      <p class="refresh-note" style="margin-top:12px">Auto-refreshes every 30s · <a href="/api/status" style="color:var(--blue);text-decoration:none">API</a></p>
    </div>

    <div class="section">
      <div class="section-title">&#x26A1; Quick Actions</div>
      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <a href="/health" class="btn btn-ghost">Health Check</a>
      </div>
    </div>

    <footer>
      <span>lobmob fleet management</span>
      <span>port ${PORT}</span>
    </footer>
  </div>
  <script>
    setInterval(async () => {
      try {
        const r = await fetch('/api/status');
        if (!r.ok) return;
        location.reload();
      } catch {}
    }, 30000);
  </script>
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
      <div style="font-size:64px;margin-bottom:16px">&#x1F99E;</div>
      <h2 style="margin-bottom:8px">Page Not Found</h2>
      <p style="color:var(--text-muted);margin-bottom:24px">This lobster wandered off.</p>
      <a href="/" class="btn btn-ghost">&#x2190; Back to Dashboard</a>
    </div>
  </div>
</body>
</html>`;
}

const handler = async (req, res) => {
  const url = new URL(req.url, 'http://' + req.headers.host);

  if (url.pathname === '/health') {
    const health = readHealthStatus();
    let k8sOk = false;
    try {
      await k8sGet('/api/v1/namespaces/' + NAMESPACE);
      k8sOk = true;
    } catch { /* ignore */ }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime(), k8s: k8sOk, health: health }));
    return;
  }

  if (url.pathname === '/api/status') {
    const fleet = await getFleetData();
    fleet.uptime = process.uptime();
    fleet.health = readHealthStatus();
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    res.end(JSON.stringify(fleet));
    return;
  }

  if (url.pathname === '/') {
    const fleet = await getFleetData();
    const health = readHealthStatus();
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(dashboardHtml(fleet, health));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/html' });
  res.end(notFoundHtml());
};

const server = http.createServer(handler);

server.listen(PORT, '0.0.0.0', () => {
  console.log('lobmob-web listening on http://0.0.0.0:' + PORT);
});
