"""LobsterIPC — aiohttp server for live event streaming and operator injection.

Listens on 127.0.0.1:8090 (localhost only). Access via the Node.js sidecar
proxy at :8080 or through kubectl port-forward.

Endpoints:
  GET  /events  -> SSE stream of agent events (per-client queue fan-out)
  POST /inject  -> queue an operator message + signal episode interrupt
  GET  /health  -> {"status": "ok", "sse_clients": N}
"""

import asyncio
import json
import logging
import time

from aiohttp import web

logger = logging.getLogger("lobster.ipc")

HOST = "127.0.0.1"
PORT = 8090


class LobsterIPC:
    def __init__(
        self,
        event_queue: asyncio.Queue,
        inject_queue: asyncio.Queue,
        inject_event: asyncio.Event,
    ) -> None:
        self._event_queue = event_queue
        self._inject_queue = inject_queue
        self._inject_event = inject_event
        self._clients: set[asyncio.Queue] = set()
        self._runner: web.AppRunner | None = None
        self._broadcast_task: asyncio.Task | None = None

    async def start(self) -> None:
        app = web.Application()
        app.router.add_get("/events", self._handle_sse)
        app.router.add_post("/inject", self._handle_inject)
        app.router.add_get("/health", self._handle_health)

        self._runner = web.AppRunner(app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, HOST, PORT)
        await site.start()

        self._broadcast_task = asyncio.create_task(self._broadcast_loop())
        logger.info("LobsterIPC listening on %s:%d", HOST, PORT)

    async def stop(self) -> None:
        if self._broadcast_task:
            self._broadcast_task.cancel()
            try:
                await self._broadcast_task
            except asyncio.CancelledError:
                pass

        # Close any open SSE connections
        for client_queue in list(self._clients):
            try:
                client_queue.put_nowait(None)  # sentinel to close stream
            except asyncio.QueueFull:
                pass
        self._clients.clear()

        if self._runner:
            await self._runner.cleanup()
        logger.info("LobsterIPC stopped")

    async def _broadcast_loop(self) -> None:
        """Drain event_queue and fan out to all SSE clients.

        Always drains the queue even when no clients are connected to
        prevent queue saturation. Per-client queues are bounded; slow
        clients get events dropped rather than blocking the loop.
        """
        while True:
            event = await self._event_queue.get()
            for client_queue in list(self._clients):
                try:
                    client_queue.put_nowait(event)
                except asyncio.QueueFull:
                    logger.debug("Dropping event for slow SSE client")

    async def _handle_sse(self, request: web.Request) -> web.StreamResponse:
        """SSE endpoint — streams events to connected clients."""
        resp = web.StreamResponse(headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        })
        await resp.prepare(request)

        client_queue: asyncio.Queue = asyncio.Queue(maxsize=100)
        self._clients.add(client_queue)
        logger.debug("SSE client connected (total: %d)", len(self._clients))

        try:
            while True:
                event = await client_queue.get()
                if event is None:
                    break  # stop sentinel from shutdown
                data = json.dumps(event)
                await resp.write(f"data: {data}\n\n".encode())
        except (ConnectionResetError, asyncio.CancelledError):
            pass
        finally:
            self._clients.discard(client_queue)
            logger.debug("SSE client disconnected (total: %d)", len(self._clients))

        return resp

    async def _handle_inject(self, request: web.Request) -> web.Response:
        """Inject an operator message and interrupt the current episode."""
        try:
            body = await request.json()
        except Exception:
            return web.Response(
                status=400,
                content_type="application/json",
                text=json.dumps({"error": "Invalid JSON body"}),
            )

        message = body.get("message", "").strip()
        if not message:
            return web.Response(
                status=400,
                content_type="application/json",
                text=json.dumps({"error": "message field required"}),
            )

        try:
            self._inject_queue.put_nowait(message)
        except asyncio.QueueFull:
            return web.Response(
                status=429,
                content_type="application/json",
                text=json.dumps({"error": "Inject queue full"}),
            )

        # Signal the episode loop to interrupt at the next tool boundary
        self._inject_event.set()

        # Echo to event stream so attached clients see it immediately
        try:
            self._event_queue.put_nowait({
                "type": "inject_received",
                "ts": time.time(),
                "message": message,
            })
        except asyncio.QueueFull:
            pass

        return web.Response(
            status=202,
            content_type="application/json",
            text=json.dumps({
                "status": "queued",
                "interrupt": True,
                "message": message,
            }),
        )

    async def _handle_health(self, request: web.Request) -> web.Response:
        return web.Response(
            content_type="application/json",
            text=json.dumps({
                "status": "ok",
                "sse_clients": len(self._clients),
            }),
        )
