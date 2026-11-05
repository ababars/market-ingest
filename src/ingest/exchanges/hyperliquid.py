"""Hyperliquid collector: perpetuals of the main DEX and of the HIP-3 DEXes.

REST only. One POST https://api.hyperliquid.xyz/info {"type": "metaAndAssetCtxs"}
returns every perpetual of a DEX with its mark, oracle price, funding and open
interest; the names come in the same answer, so a value cannot be filed under
the wrong coin. The main DEX is asked once a minute, each HIP-3 DEX (`dex`
parameter) once per hip3_poll_seconds. A WebSocket feed of all DEXes exists
(allDexsAssetCtxs), but it sends the values by position without names, and a
listing between two reads of the names shifts them.

What is easy to get wrong:

- funding is the rate of ONE HOUR: Hyperliquid pays every hour. 0.0000125 is
  the 0.01 % per 8 h of Binance's default. funding_interval_h says 1, and the
  next payment is the next full hour;
- the answer carries no time of its own: event_time is when it arrived;
- open interest is one side, in the base coin, as on Binance (not documented
  by Hyperliquid; this is how data vendors read it, and it matches the size);
- coins are named without a quote currency (BTC, kPEPE = 1000 PEPE) and HIP-3
  coins with their DEX (xyz:TSLA). Delisted coins stay in the answer with zero
  open interest and are skipped;
- HIP-3 deployers scale funding per market (assetToFundingMultiplier); the
  `funding` field already includes it;
- an unknown DEX is HTTP 500 with the body `null`.

Rows go to the same tables as every venue:

    mark_price     markPx, oraclePx as index_price, funding; the other fields
                   (premium, midPx, impactPxs, 24 h volumes, prevDayPx) in extra.
                   sampled = 1: one row a minute (HIP-3: per poll)
    open_interest  openInterest
"""

from __future__ import annotations

import asyncio
import logging
import time

from ..health import StreamStats, ch_ts, now_ms
from ..metrics import Statsd
from ..rest import RateLimited, RestClient
from .base import Collector, extra_fields

log = logging.getLogger(__name__)

REST = "https://api.hyperliquid.xyz"
EXCHANGE = "hyperliquid"
# Every info request this collector sends weighs 20 of the 1200 per minute
# that Hyperliquid allows an IP.
INFO_WEIGHT = 20
FUNDING_INTERVAL_H = 1
HOUR_MS = 3_600_000

# openInterest goes to its own table; the rest of a context is kept in extra.
KNOWN_MARK = {"markPx", "oraclePx", "funding", "openInterest"}


def _f(x) -> float:
    """Numbers come as strings; null where a field does not apply."""
    return float(x) if x not in (None, "") else 0.0


def next_hour_ms(ms: float) -> float:
    return (int(ms) // HOUR_MS + 1) * HOUR_MS


class Hyperliquid(Collector):
    EXCHANGE = EXCHANGE

    def __init__(self, cfg: dict, sink, *, focus: list[str], sd: Statsd) -> None:
        super().__init__(cfg, sink, focus=focus, sd=sd)
        # Names are case-sensitive here: kPEPE is not KPEPE.
        self.focus = set(focus)
        # No header reports the IP's usage, so only our own count is known:
        # leave room for anything else on the host that calls Hyperliquid.
        self.rest = RestClient(REST, budget=int(cfg.get("rest_weight_per_minute", 600)),
                               window_s=60.0, limited_statuses=(429,),
                               default_pause_s=60.0, on_event=self._event)
        self.poll_s = float(cfg.get("poll_seconds", 60))
        self.hip3_poll_s = float(cfg.get("hip3_poll_seconds", 300))
        self.hip3_refresh_s = float(cfg.get("hip3_refresh_hours", 24)) * 3600
        # "all": every DEX perpDexs lists; a list: only those; []: none
        self.hip3_dexes = cfg.get("hip3_dexes", "all")
        self._dexes: list[str] = []
        # DEXes whose every market is delisted: not asked again until the
        # next refresh of the list.
        self._dead: set[str] = set()
        self._focus_reported = False

    # ------------------------------------------------------------------ rest

    async def _info(self, body: dict, *, stream: str, what: str):
        assert self.rest is not None
        return await self.rest.post("/info", body, weight=INFO_WEIGHT, stream=stream, what=what)

    async def _poll(self, dex: str, stream: str) -> int | None:
        """One DEX: rows written, or None when the request failed."""
        body = {"type": "metaAndAssetCtxs"}
        if dex:
            body["dex"] = dex
        what = f"metaAndAssetCtxs {dex or 'main'}"
        try:
            d = await self._info(body, stream=stream, what=what)
        except RateLimited:
            return None
        except Exception as exc:  # noqa: BLE001 - the next poll tries again
            self._event(stream, "error", f"{what}: {type(exc).__name__}: {exc}")
            log.warning("%s failed: %s", what, exc)
            return None
        return self._write_ctxs(dex, d, now_ms(), self._stat(stream))

    def _write_ctxs(self, dex: str, d, recv_ms: float, st: StreamStats) -> int:
        """Rows for every listed market of one DEX's answer."""
        try:
            universe, ctxs = d[0]["universe"], d[1]
        except (TypeError, KeyError, IndexError):
            self._event(st.stream, "error", f"{dex or 'main'}: unexpected answer {str(d)[:200]}")
            return 0
        if len(universe) != len(ctxs):
            # Values are matched to names by position; a mismatch would file
            # them under the wrong coins.
            self._event(st.stream, "error",
                        f"{dex or 'main'}: {len(universe)} names, {len(ctxs)} contexts")
            return 0
        if not dex and not self._focus_reported:
            self._report_focus({u["name"]: "delisted" if u.get("isDelisted") else "trading"
                                for u in universe}, "trading")
            self._focus_reported = True
        n = 0
        for u, c in zip(universe, ctxs):
            if u.get("isDelisted"):
                continue
            self.sink.write("market.mark_price", self._mark_row(u["name"], c, recv_ms))
            self.sink.write("market.open_interest", self._oi_row(u["name"], c, recv_ms))
            n += 1
        if dex and n == 0:
            self._dead.add(dex)
        st.observe(nbytes=0, rows=2 * n, lag_ms=None, symbol=None)
        self._count_rows("mark_price", n)
        self._count_rows("open_interest", n)
        return n

    @staticmethod
    def _mark_row(sym: str, c: dict, recv_ms: float) -> dict:
        ts = ch_ts(recv_ms)
        return {
            "exchange": EXCHANGE,
            "symbol": sym,
            "event_time": ts,
            "ingest_time": ts,
            "mark_price": _f(c.get("markPx")),
            # the oracle: a weighted median of spot prices on other venues,
            # what Binance calls the index
            "index_price": _f(c.get("oraclePx")),
            "settle_price": 0.0,
            "funding_rate": _f(c.get("funding")),
            "next_funding_time": ch_ts(next_hour_ms(recv_ms)),
            "funding_interval_h": FUNDING_INTERVAL_H,
            "sampled": 1,
            "extra": extra_fields(c, KNOWN_MARK),
        }

    @staticmethod
    def _oi_row(sym: str, c: dict, recv_ms: float) -> dict:
        ts = ch_ts(recv_ms)
        return {
            "exchange": EXCHANGE,
            "symbol": sym,
            "event_time": ts,
            "ingest_time": ts,
            "open_interest": _f(c.get("openInterest")),
            "extra": "",
        }

    # ----------------------------------------------------------------- loops

    async def _every(self, period: float, step) -> None:
        while True:
            t0 = time.monotonic()
            await step()
            self._roll_health()
            await asyncio.sleep(max(1.0, period - (time.monotonic() - t0)))

    async def _main_step(self) -> None:
        await self._poll("", "asset_ctx")

    async def _refresh_dexes(self) -> None:
        if isinstance(self.hip3_dexes, list):
            self._dexes = list(self.hip3_dexes)
        else:
            try:
                d = await self._info({"type": "perpDexs"}, stream="hip3", what="perpDexs")
            except Exception as exc:  # noqa: BLE001 - keep the list we have
                self._event("hip3", "error", f"perpDexs: {type(exc).__name__}: {exc}")
                return
            # the first entry is null: the main DEX
            self._dexes = [x["name"] for x in d if isinstance(x, dict) and x.get("name")]
        self._dead.clear()
        self._event("hip3", "subscribed", f"{len(self._dexes)} DEXes: {','.join(self._dexes)}")

    async def _hip3_loop(self) -> None:
        refreshed = float("-inf")
        while True:
            t0 = time.monotonic()
            if t0 - refreshed >= self.hip3_refresh_s:
                await self._refresh_dexes()
                refreshed = t0
            for dex in self._dexes:
                if dex not in self._dead:
                    await self._poll(dex, "hip3")
            self._roll_health()
            await asyncio.sleep(max(1.0, self.hip3_poll_s - (time.monotonic() - t0)))

    # -------------------------------------------------------------------- run

    def _primed_counters(self) -> list[str]:
        names = [f"rows.{EXCHANGE}.{s}" for s in ("mark_price", "open_interest")]
        return names + super()._primed_counters()

    def _coroutines(self) -> dict:
        work = {"asset_ctx": self._every(self.poll_s, self._main_step)}
        if self.hip3_dexes:
            work["hip3"] = self._hip3_loop()
        return work
