# Web UI

Each component runs a lightweight Node.js web server as a subprocess or native sidecar.

## Dashboards

| Component | Port | Script | Purpose |
|---|---|---|---|
| Lobboss | 8080 | `lobmob-web.js` | Fleet status dashboard, session info |
| Lobwife | 8080 | `lobwife-web.js` | DB status, task list, sync daemon state |
| Lobster (sidecar) | 8080 | `lobmob-web-lobster.js` | Task progress, SSE event panel, inject textbox |

All dashboards use Node.js built-in `http` module (no dependencies). Lobboss and lobwife run the web server as a subprocess; lobster runs it as a native k8s sidecar container.

## Access

No public endpoints. Access via port-forwarding:

```bash
lobmob connect                    # lobboss dashboard -> localhost:8080
lobmob connect <job-name>         # lobster dashboard -> localhost:8080
lobmob attach <job-name>          # lobster SSE stream + inject (CLI, not browser)
```

Or manually:
```bash
kubectl -n lobmob port-forward svc/lobboss 8080:8080
kubectl -n lobmob port-forward svc/lobwife 8080:8080
kubectl -n lobmob port-forward pod/<lobster-pod> 8080:8080
```

## Lobster Web Sidecar

The lobster sidecar (`lobmob-web-lobster.js`) proxies to the IPC server running inside the lobster container on 127.0.0.1:8090:

| Path | Method | Description |
|---|---|---|
| `/` | GET | Task progress dashboard with SSE event panel and inject textbox |
| `/health` | GET | JSON health check (`{"status":"ok","task":"T1","type":"swe"}`) |
| `/api/events` | GET | SSE proxy — streams events from IPC server |
| `/api/inject` | POST | Inject proxy — sends operator guidance to the running agent |

### IPC Server (inside lobster container)

The `LobsterIPC` server (`src/lobster/ipc.py`) runs on 127.0.0.1:8090:

| Path | Method | Description |
|---|---|---|
| `/health` | GET | IPC health + SSE client count |
| `/events` | GET | SSE fan-out — `turn_start`, `turn_end`, `text`, `verify`, `inject`, `inject_abort`, `done`, `error` |
| `/inject` | POST | Inject operator message — sets the inject event flag, agent picks it up at next episode boundary |

## Health Checks

Lobboss and lobwife use HTTP readiness probes on their web server `/health` endpoints. The lobster sidecar provides health for the pod's readiness gate.
