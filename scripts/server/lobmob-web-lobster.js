#!/usr/bin/env node
/**
 * lobmob-web-lobster — per-lobster web dashboard sidecar.
 * Runs as a native k8s sidecar (init container with restartPolicy=Always).
 * Shows task info, status, and live log tail for the lobster container.
 */
const http = require('http');
const https = require('https');
const { readFileSync } = require('fs');

const PORT = 8080;
const NAMESPACE = 'lobmob';
const TASK_ID = process.env.TASK_ID || 'unknown';
const LOBSTER_TYPE = process.env.LOBSTER_TYPE || 'unknown';
const MY_POD_NAME = process.env.MY_POD_NAME || 'unknown';

// k8s service account
const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const SA_TOKEN_PATH = SA_DIR + '/token';
const SA_CA_PATH = SA_DIR + '/ca.crt';
const K8S_HOST = process.env.KUBERNETES_SERVICE_HOST || 'kubernetes.default.svc';
const K8S_PORT = process.env.KUBERNETES_SERVICE_PORT || '443';

const START_TIME = Date.now();

function k8sGet(path) {
  return new Promise((resolve, reject) => {
    let token, ca;
    try {
      token = readFileSync(SA_TOKEN_PATH, 'utf8').trim();
      ca = readFileSync(SA_CA_PATH);
    } catch (e) {
      reject(new Error('No k8s service account: ' + e.message));
      return;
    }
    const req = https.request({
      hostname: K8S_HOST,
      port: parseInt(K8S_PORT, 10),
      path: path,
      method: 'GET',
      headers: { 'Authorization': 'Bearer ' + token },
      ca: ca,
    }, (res) => {
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
    req.setTimeout(10000, () => { req.destroy(); reject(new Error('timeout')); });
    req.end();
  });
}

async function getPodStatus() {
  try {
    const pod = await k8sGet('/api/v1/namespaces/' + NAMESPACE + '/pods/' + MY_POD_NAME);
    const lobsterContainer = (pod.status.containerStatuses || []).find(c => c.name === 'lobster');
    let status = 'unknown';
    if (lobsterContainer) {
      if (lobsterContainer.state.running) status = 'running';
      else if (lobsterContainer.state.terminated) {
        status = lobsterContainer.state.terminated.exitCode === 0 ? 'succeeded' : 'failed';
      } else if (lobsterContainer.state.waiting) status = 'waiting';
    }
    return { status, phase: pod.status.phase };
  } catch (e) {
    return { status: 'unknown', error: e.message };
  }
}

async function getLogs(tailLines) {
  try {
    const data = await k8sGet(
      '/api/v1/namespaces/' + NAMESPACE + '/pods/' + MY_POD_NAME +
      '/log?container=lobster&tailLines=' + (tailLines || 50)
    );
    return typeof data === 'string' ? data : JSON.stringify(data);
  } catch (e) {
    return 'Error fetching logs: ' + e.message;
  }
}

function formatRuntime() {
  const ms = Date.now() - START_TIME;
  const mins = Math.floor(ms / 60000);
  if (mins >= 60) return Math.floor(mins / 60) + 'h' + (mins % 60) + 'm';
  return mins + 'm';
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const CSS = `
  :root {
    --bg: #0f1117; --surface: #1a1d27; --surface-hover: #222633;
    --border: #2a2e3d; --text: #e4e6ed; --text-muted: #8b8fa3;
    --accent: #e84142; --green: #34d399; --yellow: #fbbf24; --blue: #60a5fa;
    --radius: 12px;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg); color: var(--text); min-height: 100vh;
  }
  .container { max-width: 800px; margin: 0 auto; padding: 24px 20px; }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 20px 0; border-bottom: 1px solid var(--border); margin-bottom: 24px;
  }
  .logo { display: flex; align-items: center; gap: 12px; }
  .logo h1 { font-size: 20px; font-weight: 700; }
  .logo span { color: var(--accent); }
  .badge {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 6px 12px; border-radius: 20px; font-size: 12px; font-weight: 600;
    background: var(--surface); border: 1px solid var(--border);
  }
  .badge-green { color: var(--green); border-color: rgba(52,211,153,0.3); background: rgba(52,211,153,0.08); }
  .badge-yellow { color: var(--yellow); border-color: rgba(251,191,36,0.3); background: rgba(251,191,36,0.08); }
  .badge-red { color: var(--accent); border-color: rgba(232,65,66,0.3); background: rgba(232,65,66,0.15); }
  .dot { width: 6px; height: 6px; border-radius: 50%; }
  .dot-green { background: var(--green); box-shadow: 0 0 6px var(--green); }
  .dot-yellow { background: var(--yellow); }
  .dot-red { background: var(--accent); box-shadow: 0 0 6px var(--accent); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 16px;
  }
  .card-label { font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: var(--text-muted); margin-bottom: 6px; }
  .card-value { font-size: 22px; font-weight: 700; }
  .card-sub { font-size: 12px; color: var(--text-muted); margin-top: 4px; }
  .log-box {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 16px; font-family: 'JetBrains Mono', 'Fira Code', monospace; font-size: 12px;
    line-height: 1.6; white-space: pre-wrap; overflow-x: auto; color: var(--text-muted);
    max-height: 600px; overflow-y: auto;
  }
  .section { margin-bottom: 24px; }
  .section-title { font-size: 15px; font-weight: 600; margin-bottom: 12px; }
  footer {
    padding: 16px 0; border-top: 1px solid var(--border); margin-top: 32px;
    font-size: 12px; color: var(--text-muted);
  }
  .refresh-note { font-size: 12px; color: var(--text-muted); margin-top: 8px; }
`;

function statusBadge(status) {
  const map = {
    running: '<span class="badge badge-green"><span class="dot dot-green"></span>Running</span>',
    succeeded: '<span class="badge"><span class="dot dot-green"></span>Succeeded</span>',
    waiting: '<span class="badge badge-yellow"><span class="dot dot-yellow"></span>Waiting</span>',
    failed: '<span class="badge badge-red"><span class="dot dot-red"></span>Failed</span>',
  };
  return map[status] || '<span class="badge">' + esc(status) + '</span>';
}

function dashboardHtml(podStatus, logs) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>lobster — ${esc(LOBSTER_TYPE)} — ${esc(TASK_ID)}</title>
  <style>${CSS}</style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo">
        <span style="font-size:28px">&#x1F99E;</span>
        <h1>lob<span>ster</span></h1>
      </div>
      ${statusBadge(podStatus.status)}
    </header>

    <div class="grid">
      <div class="card">
        <div class="card-label">Task</div>
        <div class="card-value" style="font-size:16px">${esc(TASK_ID)}</div>
      </div>
      <div class="card">
        <div class="card-label">Type</div>
        <div class="card-value" style="font-size:16px">${esc(LOBSTER_TYPE)}</div>
      </div>
      <div class="card">
        <div class="card-label">Runtime</div>
        <div class="card-value">${formatRuntime()}</div>
      </div>
      <div class="card">
        <div class="card-label">Pod</div>
        <div class="card-value" style="font-size:13px">${esc(MY_POD_NAME)}</div>
      </div>
    </div>

    <div class="section">
      <div class="section-title">&#x1F4CB; Live Logs</div>
      <div class="log-box" id="logs">${esc(logs)}</div>
      <p class="refresh-note">Auto-refreshes every 10s · <a href="/api/logs" style="color:var(--blue);text-decoration:none">Raw</a> · <a href="/api/status" style="color:var(--blue);text-decoration:none">API</a></p>
    </div>

    <footer>lobmob lobster sidecar · port ${PORT}</footer>
  </div>
  <script>
    setInterval(async () => {
      try {
        const r = await fetch('/api/logs');
        if (!r.ok) return;
        const text = await r.text();
        document.getElementById('logs').textContent = text;
        document.getElementById('logs').scrollTop = document.getElementById('logs').scrollHeight;
      } catch {}
    }, 10000);
  </script>
</body>
</html>`;
}

const handler = async (req, res) => {
  const url = new URL(req.url, 'http://' + req.headers.host);

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', task: TASK_ID, type: LOBSTER_TYPE, pod: MY_POD_NAME }));
    return;
  }

  if (url.pathname === '/api/status') {
    const podStatus = await getPodStatus();
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    res.end(JSON.stringify({ task: TASK_ID, type: LOBSTER_TYPE, pod: MY_POD_NAME, runtime: formatRuntime(), ...podStatus }));
    return;
  }

  if (url.pathname === '/api/logs') {
    const tailLines = parseInt(url.searchParams.get('lines') || '50', 10);
    const logs = await getLogs(Math.min(tailLines, 500));
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-cache' });
    res.end(logs);
    return;
  }

  if (url.pathname === '/') {
    const podStatus = await getPodStatus();
    const logs = await getLogs(50);
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(dashboardHtml(podStatus, logs));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
};

const server = http.createServer(handler);
server.listen(PORT, '0.0.0.0', () => {
  console.log('lobmob-web-lobster listening on http://0.0.0.0:' + PORT + ' (task=' + TASK_ID + ', type=' + LOBSTER_TYPE + ')');
});
