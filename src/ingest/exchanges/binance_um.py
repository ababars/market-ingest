"""Binance USDⓈ-M futures collector.

Endpoint note, learned the hard way: on 2026-04-23 Binance split the futures
WebSocket into /public, /market and /private, and retired the legacy /ws/ path
for everything under /market. The old URLs still ACCEPT the connection and
still ACCEPT the subscription - they simply never send a message. So
`wss://fstream.binance.com/ws/btcusdt@aggTrade` looks healthy and delivers
nothing, forever. Streams below are therefore addressed as:

    /market/ws/<stream>   aggTrade, markPrice, forceOrder, kline, ticker
    /public/ws/<stream>   bookTicker, depth

That failure mode - an open socket that is silently empty - is also why every
stream here runs under a stall watchdog rather than trusting "connected".
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import time

import aiohttp
import websockets

from ..health import (
    SequenceTracker,
    StreamStats,
    ch_ts,
    connection_event,
    new_session_id,
    now_ms,
)

log = logging.getLogger(__name__)

WS_MARKET = "wss://fstream.binance.com/market"
REST = "https://fapi.binance.com"
EXCHANGE = "binance_um"

# Fields we model explicitly. Anything else the exchange sends is preserved
# verbatim in `extra` - Binance added `nq` and `ap` in the 2026 COIN-M merge,
# and an archive that drops unknown fields loses them permanently.
KNOWN_MARK = {"e", "E", "s", "p", "i", "P", "r", "T"}
KNOWN_AGG = {"e", "E", "s", "a", "p", "q", "f", "l", "T", "m", "M"}
KNOWN_FORCE = {"s", "S", "o", "f", "q", "p", "ap", "X", "l", "z", "T"}


def _extra(payload: dict, known: set[str]) -> str:
    rest = {k: v for k, v in payload.items() if k not in known}
    return json.dumps(rest, separators=(",", ":")) if rest else ""


class BinanceUM:
    def __init__(self, cfg: dict, sink, *, focus: list[str]) -> None:
        self.sink = sink
        self.cfg = cfg
        self.focus = {s.upper() for s in focus}
        self.session_id = new_session_id()
        self.stall = cfg.get("stall_seconds", {})
        self.reconnect_after = cfg.get("reconnect_after_hours", 23) * 3600

        self.seq = SequenceTracker()
        self.stats: dict[str, StreamStats] = {}
        # last mark-price observation per non-focus symbol, flushed once a minute
        self._pending_mark: dict[str, dict] = {}
        self._pending_minute: int = 0

    # ------------------------------------------------------------------ util

    def _stat(self, stream: str) -> StreamStats:
        st = self.stats.get(stream)
        if st is None:
            st = self.stats[stream] = StreamStats(
                exchange=EXCHANGE, connector=EXCHANGE, stream=stream,
                session_id=self.session_id,
            )
        return st

    def _event(self, stream: str, event: str, detail: str = "") -> None:
        self.sink.write(
            "ops.connection_events",
            connection_event(
                exchange=EXCHANGE, connector=EXCHANGE, stream=stream,
                session_id=self.session_id, event=event, detail=detail,
            ),
        )

    def _roll_health(self) -> None:
        minute = int(time.time() // 60)
        for st in self.stats.values():
            row = st.roll(minute)
            if row:
                row["insert_errors"] = self.sink.insert_errors
                self.sink.write("ops.stream_health", row)

    # ------------------------------------------------------------ ws plumbing

    async def _ws_loop(self, stream: str, url: str, handle) -> None:
        """Connect, consume, and never give up. Backoff is exponential with
        jitter so that a Binance-side outage does not turn our reconnects into
        a self-inflicted IP ban."""
        attempt = 0
        while True:
            started = time.monotonic()
            st = self._stat(stream)
            try:
                self._event(stream, "start", url)
                async with websockets.connect(
                    url, open_timeout=20, ping_interval=20, ping_timeout=20,
                    max_size=16 * 1024 * 1024,
                ) as ws:
                    attempt = 0
                    st.last_msg_monotonic = time.monotonic()
                    self._event(stream, "open")
                    log.info("%s connected", stream)
                    await self._consume(ws, stream, st, handle, started)
            except asyncio.CancelledError:
                self._event(stream, "stop")
                raise
            except Exception as exc:  # noqa: BLE001
                self._event(stream, "error", f"{type(exc).__name__}: {exc}")
                log.warning("%s error: %s", stream, exc)
            # Keep the sequence state: the jump across this reconnect is the
            # measurement of what the outage cost us.
            self.seq.mark_reconnect()
            attempt += 1
            delay = min(60.0, (2 ** min(attempt, 6)) * 0.5) * (0.5 + random.random())
            self._event(stream, "reconnect", f"attempt={attempt} in {delay:.1f}s")
            await asyncio.sleep(delay)

    async def _consume(self, ws, stream: str, st: StreamStats, handle, started: float) -> None:
        stall_after = float(self.stall.get(stream, 300))
        while True:
            if time.monotonic() - started > self.reconnect_after:
                # Binance force-closes at 24h. Rotating first turns an abrupt
                # drop into a controlled handover.
                self._event(stream, "close", "scheduled rotation before 24h limit")
                return
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
            except asyncio.TimeoutError:
                if st.silent_for() > stall_after:
                    self._event(
                        stream, "stall",
                        f"no messages for {st.silent_for():.0f}s (limit {stall_after:.0f}s)",
                    )
                    log.error("%s stalled for %.0fs, reconnecting", stream, st.silent_for())
                    return
                self._roll_health()
                continue
            recv_ms = now_ms()
            payload = json.loads(raw)
            if isinstance(payload, dict) and "data" in payload and "stream" in payload:
                payload = payload["data"]
            handle(payload, recv_ms, len(raw), st)
            self._roll_health()

    # -------------------------------------------------------------- handlers

    def _handle_mark(self, payload, recv_ms: float, nbytes: int, st: StreamStats) -> None:
        items = payload if isinstance(payload, list) else [payload]
        minute = int(recv_ms // 60000)
        if self._pending_minute == 0:
            self._pending_minute = minute

        lag = None
        for it in items:
            if it.get("e") != "markPriceUpdate":
                continue
            sym = it["s"]
            ev = float(it["E"])
            lag = int(recv_ms - ev)
            row = {
                "exchange": EXCHANGE,
                "symbol": sym,
                "event_time": ch_ts(ev),
                "ingest_time": ch_ts(recv_ms),
                "mark_price": float(it.get("p", 0) or 0),
                "index_price": float(it.get("i", 0) or 0),
                "settle_price": float(it.get("P", 0) or 0),
                "funding_rate": float(it.get("r", 0) or 0),
                "next_funding_time": ch_ts(float(it.get("T", 0) or 0)),
                "sampled": 0,
                "extra": _extra(it, KNOWN_MARK),
            }
            if sym in self.focus:
                self.sink.write("market.mark_price", row)
            else:
                # Keep only the newest observation; it is written once the
                # minute closes. 935 symbols x 1/s would be 65M rows a day,
                # and none of the factors downstream need that resolution.
                row["sampled"] = 1
                self._pending_mark[sym] = row

        if minute != self._pending_minute:
            for row in self._pending_mark.values():
                self.sink.write("market.mark_price", row)
            self._pending_mark.clear()
            self._pending_minute = minute

        st.observe(nbytes=nbytes, rows=len(items), lag_ms=lag, symbol=None)
        st.symbols.update(i.get("s", "") for i in items)

    def _handle_agg(self, payload, recv_ms: float, nbytes: int, st: StreamStats) -> None:
        if payload.get("e") != "aggTrade":
            return
        sym = payload["s"]
        ev = float(payload["E"])
        agg_id = int(payload["a"])

        missing, spans_reconnect = self.seq.check(sym, agg_id)
        if missing:
            st.gaps += 1
            self.sink.write("ops.sequence_gaps", {
                "detected_at": ch_ts(recv_ms),
                "exchange": EXCHANGE,
                # Distinguishes "we were restarted" from "the feed dropped
                # messages while we were connected" - very different problems.
                "stream": "agg_trade/reconnect" if spans_reconnect else "agg_trade",
                "symbol": sym,
                "session_id": self.session_id,
                "expected_id": agg_id - missing, "received_id": agg_id,
                "missing": missing,
            })

        self.sink.write("market.trades", {
            "exchange": EXCHANGE,
            "symbol": sym,
            "event_time": ch_ts(float(payload.get("T", ev))),
            "ingest_time": ch_ts(recv_ms),
            "agg_id": agg_id,
            "first_id": int(payload.get("f", 0)),
            "last_id": int(payload.get("l", 0)),
            "price": float(payload["p"]),
            "qty": float(payload["q"]),
            "is_buyer_maker": 1 if payload.get("m") else 0,
            "extra": _extra(payload, KNOWN_AGG),
        })
        st.observe(nbytes=nbytes, rows=1, lag_ms=int(recv_ms - ev), symbol=sym)

    def _handle_force(self, payload, recv_ms: float, nbytes: int, st: StreamStats) -> None:
        if payload.get("e") != "forceOrder":
            return
        o = payload.get("o") or {}
        ev = float(payload["E"])
        self.sink.write("market.liquidations", {
            "exchange": EXCHANGE,
            "symbol": o.get("s", ""),
            "event_time": ch_ts(ev),
            "ingest_time": ch_ts(recv_ms),
            "trade_time": ch_ts(float(o.get("T", ev) or ev)),
            "side": o.get("S", ""),
            "order_type": o.get("o", ""),
            "time_in_force": o.get("f", ""),
            "order_status": o.get("X", ""),
            "price": float(o.get("p", 0) or 0),
            "avg_price": float(o.get("ap", 0) or 0),
            "orig_qty": float(o.get("q", 0) or 0),
            "last_filled_qty": float(o.get("l", 0) or 0),
            "cum_filled_qty": float(o.get("z", 0) or 0),
            "extra": _extra(o, KNOWN_FORCE),
        })
        st.observe(nbytes=nbytes, rows=1, lag_ms=int(recv_ms - ev), symbol=o.get("s"))

    # ---------------------------------------------------------- open interest

    async def _open_interest_loop(self) -> None:
        """No WebSocket exists for OI; REST polling is the only option. OI is
        the weight in "median across exchanges weighted by OI", so this is a
        first-class feed, not an afterthought."""
        period = float(self.cfg.get("open_interest_poll_seconds", 60))
        which = self.cfg.get("open_interest_symbols", "focus")
        st = self._stat("open_interest")
        timeout = aiohttp.ClientTimeout(total=20)
        async with aiohttp.ClientSession(timeout=timeout) as s:
            while True:
                symbols = sorted(self.focus) if which == "focus" else sorted(self.focus)
                t0 = time.monotonic()
                for sym in symbols:
                    try:
                        async with s.get(f"{REST}/fapi/v1/openInterest", params={"symbol": sym}) as r:
                            if r.status != 200:
                                self._event("open_interest", "error", f"{sym} HTTP {r.status}")
                                continue
                            d = await r.json()
                        recv_ms = now_ms()
                        ev = float(d.get("time", recv_ms))
                        self.sink.write("market.open_interest", {
                            "exchange": EXCHANGE,
                            "symbol": d["symbol"],
                            "event_time": ch_ts(ev),
                            "ingest_time": ch_ts(recv_ms),
                            "open_interest": float(d["openInterest"]),
                            "extra": _extra(d, {"symbol", "openInterest", "time"}),
                        })
                        st.observe(nbytes=len(str(d)), rows=1,
                                   lag_ms=int(recv_ms - ev), symbol=d["symbol"])
                    except Exception as exc:  # noqa: BLE001
                        self._event("open_interest", "error", f"{sym}: {exc}")
                    await asyncio.sleep(0.05)  # stay well inside the REST weight limit
                self._roll_health()
                await asyncio.sleep(max(1.0, period - (time.monotonic() - t0)))

    # ------------------------------------------------------- config validation

    async def _validate_focus(self) -> None:
        """Check every configured focus symbol actually trades.

        A delisted or settling symbol is the quietest possible failure: it is
        spelled correctly, the subscription is accepted, and it simply never
        produces a row. Caught in the field with TONUSDT, whose status had moved
        to SETTLING - the collector looked perfectly healthy while silently
        covering 19 symbols instead of 20.
        """
        timeout = aiohttp.ClientTimeout(total=30)
        try:
            async with aiohttp.ClientSession(timeout=timeout) as s:
                async with s.get(f"{REST}/fapi/v1/exchangeInfo") as r:
                    r.raise_for_status()
                    info = await r.json()
        except Exception as exc:  # noqa: BLE001 - never block startup on this
            self._event("config", "error", f"exchangeInfo unavailable: {exc}")
            log.warning("could not validate focus symbols: %s", exc)
            return

        status = {d["symbol"]: d.get("status", "") for d in info.get("symbols", [])}
        for sym in sorted(self.focus):
            st = status.get(sym)
            if st is None:
                self._event("config", "error", f"{sym} does not exist on {EXCHANGE}")
                log.error("focus symbol %s does not exist on this venue", sym)
            elif st != "TRADING":
                self._event("config", "error", f"{sym} status={st}, expect no data")
                log.error("focus symbol %s is %s, not TRADING - it will produce no data", sym, st)
        tradable = sum(1 for s in self.focus if status.get(s) == "TRADING")
        self._event("config", "subscribed", f"{tradable}/{len(self.focus)} focus symbols tradable")
        log.info("focus universe: %d/%d symbols tradable", tradable, len(self.focus))

    # -------------------------------------------------------------------- run

    async def run(self) -> None:
        await self._validate_focus()
        focus_streams = "/".join(f"{s.lower()}@aggTrade" for s in sorted(self.focus))
        tasks = [
            asyncio.create_task(
                self._ws_loop("mark_price", f"{WS_MARKET}/ws/!markPrice@arr@1s", self._handle_mark),
                name="mark_price"),
            asyncio.create_task(
                self._ws_loop("agg_trade", f"{WS_MARKET}/stream?streams={focus_streams}", self._handle_agg),
                name="agg_trade"),
            asyncio.create_task(
                self._ws_loop("force_order", f"{WS_MARKET}/ws/!forceOrder@arr", self._handle_force),
                name="force_order"),
            asyncio.create_task(self._open_interest_loop(), name="open_interest"),
        ]
        try:
            await asyncio.gather(*tasks)
        finally:
            for t in tasks:
                t.cancel()
