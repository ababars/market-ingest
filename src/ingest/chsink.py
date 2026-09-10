"""Batched, back-pressured writer into ClickHouse over the HTTP interface.

Deliberately dependency-light: JSONEachRow over plain HTTP is enough, and one
less native protocol library is one less thing to debug at 3am.

Two properties matter more than throughput here:

1. A collector must never die because the database is briefly unavailable.
   Rows queue in memory; if the queue fills we drop the OLDEST rows and count
   the loss, because an OOM-killed collector loses everything, not just a
   window. Dropping is visible in ops.stream_health.insert_errors.

2. Batches are per-table. ClickHouse hates many small inserts (each one is a
   part that has to be merged later), so we buffer to batch_max_rows or
   batch_max_seconds, whichever comes first.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import deque
from typing import Any

import aiohttp

log = logging.getLogger(__name__)


class ClickHouseSink:
    def __init__(
        self,
        url: str,
        user: str,
        password: str,
        *,
        batch_max_rows: int = 5000,
        batch_max_seconds: float = 2.0,
        queue_max_rows: int = 400_000,
    ) -> None:
        self._url = url.rstrip("/")
        self._auth = aiohttp.BasicAuth(user, password)
        self._batch_max_rows = batch_max_rows
        self._batch_max_seconds = batch_max_seconds
        self._queue_max_rows = queue_max_rows

        self._queues: dict[str, deque[dict[str, Any]]] = {}
        self._session: aiohttp.ClientSession | None = None
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()

        self.dropped_rows = 0
        self.insert_errors = 0
        self.inserted_rows = 0

    # ------------------------------------------------------------------ api

    def write(self, table: str, row: dict[str, Any]) -> None:
        """Queue one row. Never blocks, never raises."""
        q = self._queues.get(table)
        if q is None:
            q = self._queues[table] = deque()
        q.append(row)
        if len(q) > self._queue_max_rows:
            # Oldest first: recent data is what monitoring and live views need.
            overflow = len(q) - self._queue_max_rows
            for _ in range(overflow):
                q.popleft()
            self.dropped_rows += overflow
            log.error("sink queue overflow on %s, dropped %d rows", table, overflow)

    def queued_rows(self) -> int:
        """Rows waiting to be inserted. Growth here is the earliest visible
        sign that ClickHouse is struggling, well before anything errors."""
        return sum(len(q) for q in self._queues.values())

    async def start(self) -> None:
        timeout = aiohttp.ClientTimeout(total=30)
        self._session = aiohttp.ClientSession(timeout=timeout, auth=self._auth)
        self._task = asyncio.create_task(self._run(), name="ch-sink")

    async def stop(self) -> None:
        self._stop.set()
        if self._task:
            await self._task
        if self._session:
            await self._session.close()

    async def ping(self) -> None:
        """Fail fast at startup rather than discovering the problem under load."""
        assert self._session is not None
        async with self._session.get(f"{self._url}/ping") as r:
            r.raise_for_status()

    # -------------------------------------------------------------- internals

    async def _run(self) -> None:
        last_flush = time.monotonic()
        while not self._stop.is_set():
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=0.25)
            except asyncio.TimeoutError:
                pass
            now = time.monotonic()
            due_by_time = (now - last_flush) >= self._batch_max_seconds
            for table in list(self._queues):
                q = self._queues[table]
                if not q:
                    continue
                if due_by_time or len(q) >= self._batch_max_rows:
                    await self._flush(table, q)
            if due_by_time:
                last_flush = now
        # drain what we can on the way out
        for table in list(self._queues):
            q = self._queues[table]
            while q:
                if not await self._flush(table, q):
                    break

    async def _flush(self, table: str, q: deque) -> bool:
        assert self._session is not None
        n = min(len(q), self._batch_max_rows)
        rows = [q.popleft() for _ in range(n)]
        body = "\n".join(json.dumps(r, separators=(",", ":")) for r in rows)
        params = {"query": f"INSERT INTO {table} FORMAT JSONEachRow"}
        try:
            async with self._session.post(self._url, params=params, data=body.encode()) as r:
                if r.status != 200:
                    text = (await r.text())[:400]
                    raise RuntimeError(f"HTTP {r.status}: {text}")
            self.inserted_rows += n
            return True
        except Exception as exc:  # noqa: BLE001 - a sink must not propagate
            self.insert_errors += 1
            # Put them back at the FRONT so ordering survives a transient failure.
            q.extendleft(reversed(rows))
            log.warning("insert into %s failed (%d rows requeued): %s", table, n, exc)
            await asyncio.sleep(1.0)
            return False
