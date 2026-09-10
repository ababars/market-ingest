"""Fire-and-forget StatsD client for Netdata's built-in receiver.

Netdata listens on UDP 8125 and turns whatever it receives into charts, so the
collector can publish its own throughput next to the host's CPU and disk
without adding a metrics service to the box.

Two properties are non-negotiable here:

1. Instrumentation must never be able to break collection. Every send is
   wrapped, the socket is UDP (no connection to lose), and a full send buffer
   is silently dropped rather than blocking the event loop. Metrics about lost
   data are worth less than the data.

2. Counters are accumulated in memory and flushed on a timer, not sent per
   event. mark_price alone produces ~750 rows a second; a datagram each would
   be pure waste for a number Netdata is going to rate-average anyway.
"""

from __future__ import annotations

import asyncio
import logging
import socket

log = logging.getLogger(__name__)


class Statsd:
    def __init__(self, host: str = "127.0.0.1", port: int = 8125,
                 prefix: str = "market_ingest", enabled: bool = True) -> None:
        self.prefix = prefix.rstrip(".")
        self.enabled = enabled
        self._addr = (host, port)
        self._sock: socket.socket | None = None
        self._counters: dict[str, float] = {}
        self._gauges: dict[str, float] = {}
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()
        self.send_errors = 0

    # ------------------------------------------------------------------ api

    def incr(self, name: str, value: float = 1) -> None:
        if self.enabled:
            self._counters[name] = self._counters.get(name, 0) + value

    def prime(self, *names: str) -> None:
        """Register counters that should be reported even while they are zero.

        A chart only exists once Netdata has seen the metric, and an alarm only
        attaches to a chart that exists. Left unprimed, the gap counter would
        create its chart at the moment of the first gap - arming the alarm
        exactly one incident too late.
        """
        if self.enabled:
            for n in names:
                self._counters.setdefault(n, 0)

    def gauge(self, name: str, value: float) -> None:
        if self.enabled:
            self._gauges[name] = value

    async def start(self) -> None:
        if not self.enabled:
            log.info("statsd disabled")
            return
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setblocking(False)
        self._task = asyncio.create_task(self._run(), name="statsd")
        log.info("statsd -> %s:%d prefix=%s", *self._addr, self.prefix)

    async def stop(self) -> None:
        self._stop.set()
        if self._task:
            await self._task
        if self._sock:
            self._sock.close()

    # ------------------------------------------------------------ internals

    async def _run(self) -> None:
        while not self._stop.is_set():
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=1.0)
            except asyncio.TimeoutError:
                pass
            self._flush()
        self._flush()

    def _flush(self) -> None:
        if not self._sock:
            return
        lines: list[str] = []
        for name in list(self._counters):
            value = self._counters[name]
            lines.append(f"{self.prefix}.{name}:{value:g}|c")
            # Zero rather than delete: a counter that stops being reported
            # leaves a hole in the chart, and "nothing happened" is a fact
            # worth plotting.
            self._counters[name] = 0
        for name, value in self._gauges.items():
            lines.append(f"{self.prefix}.{name}:{value:g}|g")
        # Gauges are NOT cleared: a gauge that stops being sent leaves a gap in
        # the chart, and "queue depth stayed at zero" is a real observation.
        if not lines:
            return
        # One datagram per ~1200 bytes: comfortably under any sane MTU, and
        # StatsD accepts newline-separated metrics in a single packet.
        buf: list[str] = []
        size = 0
        for line in lines:
            if size + len(line) > 1200:
                self._send("\n".join(buf)); buf, size = [], 0
            buf.append(line); size += len(line) + 1
        if buf:
            self._send("\n".join(buf))

    def _send(self, payload: str) -> None:
        try:
            self._sock.sendto(payload.encode(), self._addr)  # type: ignore[union-attr]
        except BlockingIOError:
            self.send_errors += 1   # kernel buffer full; drop, never block
        except Exception as exc:  # noqa: BLE001
            self.send_errors += 1
            if self.send_errors in (1, 100, 1000):
                log.warning("statsd send failed (%d so far): %s", self.send_errors, exc)


class NullStatsd(Statsd):
    """Used when metrics are switched off, so call sites need no conditionals."""

    def __init__(self) -> None:
        super().__init__(enabled=False)
