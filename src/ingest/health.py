"""Health accounting: what the collector was doing, so that missing data is a
fact rather than a guess.

An empty hour in market.trades is ambiguous - either nothing traded, or we were
blind. These helpers remove the ambiguity by recording, minute by minute, how
many messages arrived, how far behind the exchange clock we were, and every
connect/stall/error along the way.
"""

from __future__ import annotations

import logging
import time
import uuid
from dataclasses import dataclass, field

log = logging.getLogger(__name__)


def ch_ts(ms: float) -> str:
    """Epoch milliseconds -> the literal ClickHouse parses into DateTime64(3)."""
    s, frac = divmod(int(ms), 1000)
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(s)) + f".{frac:03d}"


def now_ms() -> float:
    return time.time() * 1000.0


@dataclass
class StreamStats:
    """Rolling one-minute counters for a single stream."""

    exchange: str
    connector: str
    stream: str
    session_id: str

    minute: int = 0
    messages: int = 0
    rows: int = 0
    nbytes: int = 0
    gaps: int = 0
    symbols: set[str] = field(default_factory=set)
    lags: list[int] = field(default_factory=list)
    last_msg_monotonic: float = field(default_factory=time.monotonic)

    def observe(self, *, nbytes: int, rows: int, lag_ms: int | None, symbol: str | None) -> None:
        self.messages += 1
        self.rows += rows
        self.nbytes += nbytes
        self.last_msg_monotonic = time.monotonic()
        if symbol:
            self.symbols.add(symbol)
        if lag_ms is not None:
            # Negative lag means our clock is behind the exchange's; clamp so a
            # small clock skew cannot masquerade as impossibly fast delivery.
            self.lags.append(max(0, lag_ms))

    def roll(self, minute: int) -> dict | None:
        """Close the current minute and return a row for ops.stream_health."""
        if self.minute == 0:
            self.minute = minute
            return None
        if minute == self.minute:
            return None
        row = self._row()
        self.minute = minute
        self.messages = self.rows = self.nbytes = self.gaps = 0
        self.symbols = set()
        self.lags = []
        return row

    def _row(self) -> dict:
        lags = sorted(self.lags)

        def pct(p: float) -> int:
            if not lags:
                return 0
            idx = min(len(lags) - 1, int(len(lags) * p))
            return int(lags[idx])

        return {
            "minute": time.strftime("%Y-%m-%d %H:%M:00", time.gmtime(self.minute * 60)),
            "exchange": self.exchange,
            "connector": self.connector,
            "stream": self.stream,
            "session_id": self.session_id,
            "messages": self.messages,
            "rows": self.rows,
            "bytes": self.nbytes,
            "symbols": len(self.symbols),
            "lag_ms_p50": pct(0.50),
            "lag_ms_p99": pct(0.99),
            "lag_ms_max": int(lags[-1]) if lags else 0,
            "gaps": self.gaps,
            "insert_errors": 0,
        }

    def silent_for(self) -> float:
        return time.monotonic() - self.last_msg_monotonic


class SequenceTracker:
    """Detects holes in a per-symbol contiguous id sequence (Binance aggTrade).

    Only reports a gap when ids move FORWARD by more than one. Duplicates and
    out-of-order redelivery are normal on reconnect and are not losses.
    """

    def __init__(self) -> None:
        self._last: dict[str, int] = {}

    def check(self, symbol: str, seq: int) -> int:
        prev = self._last.get(symbol)
        self._last[symbol] = max(seq, prev) if prev is not None else seq
        if prev is None or seq <= prev:
            return 0
        return seq - prev - 1

    def reset(self, symbol: str | None = None) -> None:
        # After a reconnect the exchange may resume anywhere; a jump across the
        # reconnect boundary is a real gap, but we record it as a connection
        # event instead of a fake million-message sequence gap.
        if symbol is None:
            self._last.clear()
        else:
            self._last.pop(symbol, None)


def new_session_id() -> str:
    return str(uuid.uuid4())


def connection_event(
    *, exchange: str, connector: str, stream: str, session_id: str, event: str, detail: str = ""
) -> dict:
    return {
        "ts": ch_ts(now_ms()),
        "exchange": exchange,
        "connector": connector,
        "stream": stream,
        "session_id": session_id,
        "event": event,
        "detail": detail[:2000],
    }
