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
- openInterest is BOTH sides (longs + shorts), in the base coin. Not
  documented; checked on 2026-11-06: BTC 42 604 against HyperTracker's
  42 308 total / 21 154 long, and on xyz:CAMBRICON against clearinghouseState.
  Stored halved, one side as on Binance; the raw figure stays in extra;
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
    open_interest  openInterest / 2 (one side); openInterest in extra
"""

from __future__ import annotations

import asyncio
import json
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


def _need(c: dict, key: str) -> float:
    """A number every listed market has (they come as strings). Without it the
    row would carry a made-up 0, so the coin is skipped instead."""
    x = c.get(key)
    if x in (None, ""):
        raise ValueError(f"no {key}")
    return float(x)


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
        self.hip3_refresh_s = float(cfg.get("hip3_refresh_hours", 1)) * 3600
        # "all": every DEX perpDexs lists; a list: only those; []: none
        self.hip3_dexes = cfg.get("hip3_dexes", "all")
        if not (self.hip3_dexes == "all" or (isinstance(self.hip3_dexes, list)
                                             and all(isinstance(x, str) and x for x in self.hip3_dexes))):
            raise ValueError(f'hyperliquid.hip3_dexes: "all" or a list of DEX names, '
                             f'not {self.hip3_dexes!r}')
        self._dexes: list[str] = []
        # DEXes whose every market is delisted: not asked again until the
        # next refresh of the list.
        self._dead: set[str] = set()
        self._focus_reported = False

    # ------------------------------------------------------------------ rest

    async def _info(self, body: dict, *, stream: str, what: str):
        assert self.rest is not None
        if stream == "hip3":
            await self._hip3_room()
        return await self.rest.post("/info", body, weight=INFO_WEIGHT, stream=stream, what=what)

    async def _hip3_room(self) -> None:
        """HIP-3 never takes the last request of a window: that one is the
        main DEX's. The budget is served first come, first served, so with
        enough HIP-3 DEXes ("all" picks up new ones) the main poll would
        otherwise wait for the next window and its minute would be lost."""
        while 0 < self.rest.used() and self.rest.used() + 2 * INFO_WEIGHT > self.rest.budget:
            await asyncio.sleep(self.rest.window_left() + 0.1)

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
        try:
            return self._write_ctxs(dex, d, now_ms(), self._stat(stream))
        except Exception as exc:  # noqa: BLE001 - a crash restarts the process,
            # and every restart asks every DEX again: a DEX that keeps answering
            # garbage would spend the IP's limit that the main DEX needs
            self._event(stream, "error", f"{what}: {type(exc).__name__}: {exc}")
            log.exception("%s: unreadable answer", what)
            return None

    def _write_ctxs(self, dex: str, d, recv_ms: float, st: StreamStats) -> int:
        """Rows for every listed market of one DEX's answer."""
        try:
            universe, ctxs = d[0]["universe"], d[1]
            if not isinstance(universe, list) or not isinstance(ctxs, list):
                raise TypeError
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
                                for u in universe if isinstance(u, dict) and u.get("name")},
                               "trading")
            self._focus_reported = True
        n, bad = 0, []
        for i, (u, c) in enumerate(zip(universe, ctxs)):
            try:
                if u.get("isDelisted"):
                    continue
                # both rows built before either is written: never a mark
                # without its open interest
                mark, oi = self._mark_row(u["name"], c, recv_ms), self._oi_row(u["name"], c, recv_ms)
            except Exception as exc:  # noqa: BLE001 - one bad coin, not the whole DEX
                name = u.get("name") if isinstance(u, dict) else None
                bad.append(f"{name or '#' + str(i)} ({type(exc).__name__}: {exc})")
                continue
            self.sink.write("market.mark_price", mark)
            self.sink.write("market.open_interest", oi)
            n += 1
        if bad:
            self._event(st.stream, "error",
                        f"{dex or 'main'}: {len(bad)} unreadable, skipped: {'; '.join(bad)}"[:400])
        if dex and n == 0 and not bad:
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
            "mark_price": _need(c, "markPx"),
            # the oracle: a weighted median of spot prices on other venues,
            # what Binance calls the index
            "index_price": _need(c, "oraclePx"),
            "settle_price": 0.0,
            "funding_rate": _need(c, "funding"),
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
            "open_interest": _need(c, "openInterest") / 2,
            "extra": json.dumps({"openInterest": c["openInterest"], "derived": "openInterest/2"},
                                separators=(",", ":")),
        }

    # ----------------------------------------------------------------- loops

    def _roll(self, stream: str) -> None:
        """Close the stream's minute right BEFORE a poll, so the closed row
        holds the previous poll under the minute it was made in. Each loop
        closes only its own stream: rolled every minute, the HIP-3 stream
        (polled every few minutes) would log empty minutes in between, and
        those read as blind spots in ops.v_silent_minutes."""
        self._stat(stream)
        self._roll_health({stream})

    async def _main_loop(self) -> None:
        # A fixed schedule rather than "a period after the last poll ended":
        # the polls keep their second of the minute, one poll per minute.
        due = time.monotonic()
        while True:
            self._roll("asset_ctx")
            await self._poll("", "asset_ctx")
            due += self.poll_s
            now = time.monotonic()
            if due < now:       # fell behind (a long rate-limit pause): new grid
                due = now + self.poll_s
            await asyncio.sleep(due - now)

    async def _refresh_dexes(self) -> bool:
        """Fetch the DEX list; False when that failed."""
        if isinstance(self.hip3_dexes, list):
            self._dexes = list(self.hip3_dexes)
        else:
            try:
                d = await self._info({"type": "perpDexs"}, stream="hip3", what="perpDexs")
            except Exception as exc:  # noqa: BLE001 - keep the list we have
                self._event("hip3", "error", f"perpDexs: {type(exc).__name__}: {exc}")
                return False
            # the first entry is null: the main DEX
            names = ([x["name"] for x in d if isinstance(x, dict) and x.get("name")]
                     if isinstance(d, list) else [])
            if not names:
                # Ten DEXes exist; an answer without any is broken. Kept as a
                # failure, it is asked again next round, not at the next refresh.
                self._event("hip3", "error", f"perpDexs: no DEXes in {str(d)[:200]}")
                return False
            self._dexes = names
        self._dead.clear()
        self._event("hip3", "subscribed", f"{len(self._dexes)} DEXes: {','.join(self._dexes)}")
        return True

    async def _hip3_loop(self) -> None:
        refreshed = float("-inf")
        while True:
            t0 = time.monotonic()
            self._roll("hip3")
            # A failed fetch is retried on the next round, not at the next refresh;
            # until then the list we have (empty at start) is polled.
            if t0 - refreshed >= self.hip3_refresh_s and await self._refresh_dexes():
                refreshed = t0
            for dex in self._dexes:
                if dex not in self._dead:
                    await self._poll(dex, "hip3")
            await asyncio.sleep(max(1.0, self.hip3_poll_s - (time.monotonic() - t0)))

    # -------------------------------------------------------------------- run

    def _primed_counters(self) -> list[str]:
        names = [f"rows.{EXCHANGE}.{s}" for s in ("mark_price", "open_interest")]
        return names + super()._primed_counters()

    def _coroutines(self) -> dict:
        work = {"asset_ctx": self._main_loop()}
        if self.hip3_dexes:
            work["hip3"] = self._hip3_loop()
        return work
