#!/usr/bin/env node
const http = require('http');

const PORT = 8080;
const DAEMON_PORT = 8081;
const DAEMON_HOST = '127.0.0.1';

// ---------------------------------------------------------------------------
// Daemon API proxy
// ---------------------------------------------------------------------------

function daemonGet(path) {
  return new Promise((resolve, reject) => {
    const req = http.get({
      hostname: DAEMON_HOST,
      port: DAEMON_PORT,
      path: path,
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
  });
}

function daemonRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const headers = {};
    let bodyStr;
    if (body) {
      bodyStr = typeof body === 'string' ? body : JSON.stringify(body);
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(bodyStr);
    }
    const req = http.request({
      hostname: DAEMON_HOST,
      port: DAEMON_PORT,
      path: path,
      method: method,
      headers: headers,
      timeout: 10000,
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

function daemonPost(path, body) {
  return daemonRequest('POST', path, body);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
  if (h > 0) return h + 'h ' + m + 'm';
  return m + 'm';
}

function timeAgo(isoStr) {
  if (!isoStr) return 'never';
  const ms = Date.now() - new Date(isoStr).getTime();
  const s = Math.floor(ms / 1000);
  if (s < 60) return s + 's ago';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  return h + 'h ' + (m % 60) + 'm ago';
}

function timeUntil(isoStr) {
  if (!isoStr) return '-';
  const ms = new Date(isoStr).getTime() - Date.now();
  if (ms < 0) return 'now';
  const s = Math.floor(ms / 1000);
  if (s < 60) return 'in ' + s + 's';
  const m = Math.floor(s / 60);
  if (m < 60) return 'in ' + m + 'm';
  const h = Math.floor(m / 60);
  return 'in ' + h + 'h ' + (m % 60) + 'm';
}

// ---------------------------------------------------------------------------
// Styles (shared with lobboss dashboard)
// ---------------------------------------------------------------------------

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
    --red: #f87171;
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
  .logo h1 { font-size: 24px; font-weight: 700; letter-spacing: -0.5px; }
  .logo span { color: var(--accent); }
  .badge {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 12px; border-radius: 20px; font-size: 12px; font-weight: 600;
    background: var(--surface); border: 1px solid var(--border);
  }
  .badge-green { color: var(--green); border-color: rgba(52, 211, 153, 0.3); background: rgba(52, 211, 153, 0.08); }
  .badge-yellow { color: var(--yellow); border-color: rgba(251, 191, 36, 0.3); background: rgba(251, 191, 36, 0.08); }
  .badge-red { color: var(--red); border-color: rgba(248, 113, 113, 0.3); background: rgba(248, 113, 113, 0.08); }
  .badge-blue { color: var(--blue); border-color: rgba(96, 165, 250, 0.3); background: rgba(96, 165, 250, 0.08); }
  .badge-muted { color: var(--text-muted); }
  .dot { width: 6px; height: 6px; border-radius: 50%; display: inline-block; }
  .dot-green { background: var(--green); box-shadow: 0 0 6px var(--green); }
  .dot-yellow { background: var(--yellow); }
  .dot-red { background: var(--red); box-shadow: 0 0 6px var(--red); }
  .dot-blue { background: var(--blue); box-shadow: 0 0 6px var(--blue); }
  .dot-muted { background: var(--text-muted); }
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
  .fleet-table td { padding: 12px 16px; border-bottom: 1px solid var(--border); font-size: 14px; vertical-align: middle; }
  .fleet-table tr:hover td { background: var(--surface-hover); }
  .fleet-table-wrap {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); overflow: hidden;
  }
  .btn {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 14px; border-radius: 6px; font-size: 12px; font-weight: 500;
    text-decoration: none; transition: all 0.2s; cursor: pointer; border: none;
  }
  .btn-trigger { background: rgba(96, 165, 250, 0.15); color: var(--blue); border: 1px solid rgba(96, 165, 250, 0.3); }
  .btn-trigger:hover { background: rgba(96, 165, 250, 0.25); }
  .btn-toggle { background: rgba(251, 191, 36, 0.15); color: var(--yellow); border: 1px solid rgba(251, 191, 36, 0.3); }
  .btn-toggle:hover { background: rgba(251, 191, 36, 0.25); }
  .btn-ghost { background: transparent; color: var(--text-muted); border: 1px solid var(--border); }
  .btn-ghost:hover { background: var(--surface); color: var(--text); }
  footer {
    padding: 20px 0; border-top: 1px solid var(--border); margin-top: 40px;
    display: flex; justify-content: space-between; align-items: center;
    font-size: 12px; color: var(--text-muted);
  }
  .output-box {
    background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 16px; margin-top: 16px; font-family: 'JetBrains Mono', 'Fira Code', monospace;
    font-size: 12px; color: var(--text-muted); white-space: pre-wrap; word-break: break-all;
    max-height: 400px; overflow-y: auto;
  }
  .refresh-note { font-size: 12px; color: var(--text-muted); }
  @media (max-width: 640px) {
    .grid { grid-template-columns: 1fr; }
    header { flex-direction: column; gap: 12px; align-items: flex-start; }
    .card-value { font-size: 22px; }
    .fleet-table { font-size: 13px; }
    .fleet-table th, .fleet-table td { padding: 8px 12px; }
  }
`;

// ---------------------------------------------------------------------------
// HTML builders
// ---------------------------------------------------------------------------

function statusBadge(status, running) {
  if (running) return '<span class="badge badge-blue"><span class="dot dot-blue"></span>Running</span>';
  const map = {
    success: '<span class="badge badge-green"><span class="dot dot-green"></span>Success</span>',
    failed: '<span class="badge badge-red"><span class="dot dot-red"></span>Failed</span>',
    timeout: '<span class="badge badge-red"><span class="dot dot-red"></span>Timeout</span>',
    error: '<span class="badge badge-red"><span class="dot dot-red"></span>Error</span>',
    disabled: '<span class="badge badge-muted"><span class="dot dot-muted"></span>Disabled</span>',
  };
  return map[status] || '<span class="badge badge-muted">Pending</span>';
}

function dashboardHtml(data) {
  const jobs = data.jobs || {};
  const broker = data.broker || {};
  const names = Object.keys(jobs);
  const running = names.filter(n => jobs[n].running).length;
  const healthy = names.filter(n => jobs[n].last_status === 'success').length;
  const failed = names.filter(n => ['failed', 'timeout', 'error'].includes(jobs[n].last_status)).length;
  const uptime = data.uptime ? formatUptime(data.uptime) : '-';

  const rows = names.map(name => {
    const j = jobs[name];
    const badge = j.enabled ? statusBadge(j.last_status, j.running) : statusBadge('disabled', false);
    const toggleLabel = j.enabled ? 'Disable' : 'Enable';
    const toggleAction = j.enabled ? 'disable' : 'enable';
    return `
<tr>
  <td style="font-weight:500"><a href="/jobs/${esc(name)}" style="color:var(--text);text-decoration:none">${esc(name)}</a></td>
  <td style="color:var(--text-muted);font-family:monospace;font-size:12px">${esc(j.schedule)}</td>
  <td>${badge}</td>
  <td style="color:var(--text-muted)">${timeAgo(j.last_run)}</td>
  <td style="color:var(--text-muted)">${j.last_duration != null ? j.last_duration + 's' : '-'}</td>
  <td style="color:var(--text-muted)">${timeUntil(j.next_run)}</td>
  <td>
    <button class="btn btn-trigger" onclick="triggerJob('${esc(name)}')">Trigger</button>
    <button class="btn btn-toggle" onclick="toggleJob('${esc(name)}','${toggleAction}')">${toggleLabel}</button>
  </td>
</tr>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobwife — Cron Dashboard</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo">
        <h1>lob<span>wife</span></h1>
      </div>
      <div style="display:flex;gap:8px">
        <span class="badge badge-green"><span class="dot dot-green"></span>Online</span>
      </div>
    </header>

    <div class="grid">
      <div class="card">
        <div class="card-label">Jobs</div>
        <div class="card-value">${names.length}</div>
        <div class="card-sub">${running} running</div>
      </div>
      <div class="card">
        <div class="card-label">Healthy</div>
        <div class="card-value" style="color:var(--green)">${healthy}</div>
        <div class="card-sub">${failed} failed</div>
      </div>
      <div class="card">
        <div class="card-label">Uptime</div>
        <div class="card-value">${uptime}</div>
        <div class="card-sub">daemon process</div>
      </div>
      <div class="card">
        <div class="card-label">Token Broker</div>
        <div class="card-value" style="font-size:18px;color:${broker.enabled ? 'var(--green)' : 'var(--text-muted)'}">${broker.enabled ? 'Active' : 'Disabled'}</div>
        <div class="card-sub">${broker.active_tasks || 0} tasks, ${broker.total_tokens_issued || 0} tokens issued</div>
      </div>
    </div>

    <div class="section">
      <div class="section-title">Scheduled Jobs</div>
      <div class="fleet-table-wrap">
        <table class="fleet-table">
          <thead><tr><th>Job</th><th>Schedule</th><th>Status</th><th>Last Run</th><th>Duration</th><th>Next Run</th><th>Actions</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
      <p class="refresh-note" style="margin-top:12px">Auto-refreshes every 10s &middot; <a href="/api/status" style="color:var(--blue);text-decoration:none">API</a></p>
    </div>

    <footer>
      <span>lobwife cron service</span>
      <span>port ${PORT}</span>
    </footer>
  </div>
  <script>
    async function triggerJob(name) {
      try {
        const r = await fetch('/api/jobs/' + name + '/trigger', { method: 'POST' });
        const d = await r.json();
        if (r.ok) location.reload();
        else alert(d.message || 'Failed');
      } catch (e) { alert('Error: ' + e.message); }
    }
    async function toggleJob(name, action) {
      try {
        const r = await fetch('/api/jobs/' + name + '/' + action, { method: 'POST' });
        const d = await r.json();
        if (r.ok) location.reload();
        else alert(d.message || 'Failed');
      } catch (e) { alert('Error: ' + e.message); }
    }
    setInterval(() => location.reload(), 10000);
  </script>
</body>
</html>`;
}

function jobDetailHtml(job) {
  const badge = job.enabled ? statusBadge(job.last_status, job.running) : statusBadge('disabled', false);
  const output = job.last_output || 'No output yet';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobwife — ${esc(job.name)}</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo">
        <h1>lob<span>wife</span></h1>
      </div>
      <a href="/" class="btn btn-ghost">Back</a>
    </header>

    <div class="section">
      <div class="section-title">${esc(job.name)}</div>
      <p style="color:var(--text-muted);margin-bottom:16px">${esc(job.description)}</p>

      <div class="grid">
        <div class="card">
          <div class="card-label">Status</div>
          <div style="margin-top:8px">${badge}</div>
        </div>
        <div class="card">
          <div class="card-label">Schedule</div>
          <div class="card-value" style="font-size:18px;font-family:monospace">${esc(job.schedule)}</div>
        </div>
        <div class="card">
          <div class="card-label">Runs</div>
          <div class="card-value">${job.run_count}</div>
          <div class="card-sub">${job.fail_count} failed</div>
        </div>
        <div class="card">
          <div class="card-label">Last Duration</div>
          <div class="card-value">${job.last_duration != null ? job.last_duration + 's' : '-'}</div>
        </div>
      </div>

      <div style="display:flex;gap:8px;margin-bottom:16px">
        <div><strong style="font-size:13px;color:var(--text-muted)">Script:</strong> <code style="color:var(--blue)">${esc(job.script)}</code></div>
        <div style="margin-left:24px"><strong style="font-size:13px;color:var(--text-muted)">Last run:</strong> ${timeAgo(job.last_run)}</div>
        <div style="margin-left:24px"><strong style="font-size:13px;color:var(--text-muted)">Next run:</strong> ${timeUntil(job.next_run)}</div>
      </div>

      <div style="display:flex;gap:8px;margin-bottom:16px">
        <button class="btn btn-trigger" onclick="triggerJob('${esc(job.name)}')">Trigger Now</button>
        <button class="btn btn-toggle" onclick="toggleJob('${esc(job.name)}','${job.enabled ? 'disable' : 'enable'}')">${job.enabled ? 'Disable' : 'Enable'}</button>
      </div>

      <div class="section-title">Last Output</div>
      <div class="output-box">${esc(output)}</div>
    </div>

    <footer>
      <span>lobwife cron service</span>
      <a href="/" style="color:var(--blue);text-decoration:none">Dashboard</a>
    </footer>
  </div>
  <script>
    async function triggerJob(name) {
      try {
        const r = await fetch('/api/jobs/' + name + '/trigger', { method: 'POST' });
        if (r.ok) setTimeout(() => location.reload(), 1000);
        else alert('Failed');
      } catch (e) { alert('Error: ' + e.message); }
    }
    async function toggleJob(name, action) {
      try {
        const r = await fetch('/api/jobs/' + name + '/' + action, { method: 'POST' });
        if (r.ok) location.reload();
        else alert('Failed');
      } catch (e) { alert('Error: ' + e.message); }
    }
    setInterval(() => location.reload(), 10000);
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
  <title>lobwife — 404</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container" style="display:flex;align-items:center;justify-content:center;min-height:80vh">
    <div style="text-align:center">
      <h2 style="margin-bottom:8px">Page Not Found</h2>
      <p style="color:var(--text-muted);margin-bottom:24px">Nothing scheduled here.</p>
      <a href="/" class="btn btn-ghost">Back to Dashboard</a>
    </div>
  </div>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

const handler = async (req, res) => {
  const url = new URL(req.url, 'http://' + req.headers.host);

  try {
    // Health check (proxied from daemon)
    if (url.pathname === '/health') {
      try {
        const data = await daemonGet('/health');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data));
      } catch (e) {
        res.writeHead(503, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'error', message: 'daemon unreachable: ' + e.message }));
      }
      return;
    }

    // API proxy — pass through to daemon (GET, POST, DELETE)
    if (url.pathname.startsWith('/api/')) {
      try {
        let data;
        if (req.method === 'POST') {
          // Read request body and forward
          const body = await new Promise((resolve) => {
            let b = '';
            req.on('data', (c) => b += c);
            req.on('end', () => { try { resolve(JSON.parse(b)); } catch { resolve(b || undefined); } });
          });
          data = await daemonPost(url.pathname, body);
        } else if (req.method === 'DELETE') {
          data = await daemonRequest('DELETE', url.pathname);
        } else {
          data = await daemonGet(url.pathname);
        }
        const statusCode = typeof data === 'object' && data.error ? (data.error.includes('not registered') ? 403 : 404) : 200;
        res.writeHead(statusCode, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
        res.end(JSON.stringify(data));
      } catch (e) {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'daemon unreachable: ' + e.message }));
      }
      return;
    }

    // Job detail page
    const jobMatch = url.pathname.match(/^\/jobs\/([a-z0-9-]+)$/);
    if (jobMatch) {
      try {
        const job = await daemonGet('/api/jobs/' + jobMatch[1]);
        if (job.error) {
          res.writeHead(404, { 'Content-Type': 'text/html' });
          res.end(notFoundHtml());
        } else {
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(jobDetailHtml(job));
        }
      } catch (e) {
        res.writeHead(502, { 'Content-Type': 'text/html' });
        res.end('<p>Daemon unreachable: ' + esc(e.message) + '</p>');
      }
      return;
    }

    // Dashboard
    if (url.pathname === '/') {
      try {
        const data = await daemonGet('/api/status');
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(dashboardHtml(data));
      } catch (e) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(dashboardHtml({ jobs: {}, uptime: 0, error: e.message }));
      }
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/html' });
    res.end(notFoundHtml());
  } catch (e) {
    console.error('Request error:', e);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: e.message }));
  }
};

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = http.createServer(handler);

server.listen(PORT, '0.0.0.0', () => {
  console.log('lobwife-web listening on http://0.0.0.0:' + PORT);
});
