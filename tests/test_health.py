import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from ingest.health import ch_ts, SequenceTracker, StreamStats

fails = []
def check(name, got, want):
    if got == want: print(f"  PASS  {name}")
    else: print(f"  FAIL  {name}: got {got!r}, want {want!r}"); fails.append(name)

print("== ch_ts: ClickHouse DateTime64(3) literal")
check("epoch",            ch_ts(0),              "1970-01-01 00:00:00.000")
check("millis kept",      ch_ts(1789029931123),  "2026-09-10 08:45:31.123")
check("millis zero-pad",  ch_ts(1789029931007),  "2026-09-10 08:45:31.007")
check("float input",      ch_ts(1789029931123.9),"2026-09-10 08:45:31.123")
check("always UTC",       len(ch_ts(time.time()*1000)), 23)

print("== SequenceTracker: only forward jumps are losses")
t = SequenceTracker()
check("first id is not a gap",  t.check("BTC", 100), 0)
check("contiguous",             t.check("BTC", 101), 0)
check("jump of 1 missing",      t.check("BTC", 103), 1)
check("jump of 4 missing",      t.check("BTC", 108), 4)
check("duplicate is not a gap", t.check("BTC", 108), 0)
check("out-of-order not a gap", t.check("BTC", 105), 0)
check("resumes from high water",t.check("BTC", 109), 0)
check("per-symbol isolation",   t.check("ETH", 5000), 0)
t.reset()
check("reset forgets",          t.check("BTC", 99999), 0)

print("== StreamStats: minute rollover and percentiles")
st = StreamStats(exchange="x", connector="c", stream="s", session_id="sid")
check("first roll primes only", st.roll(100), None)
for lag in range(1, 101):
    st.observe(nbytes=10, rows=1, lag_ms=lag, symbol="BTC")
check("same minute no row", st.roll(100), None)
row = st.roll(101)
check("rolled a row",     row is not None, True)
check("rows counted",     row["rows"], 100)
check("bytes counted",    row["bytes"], 1000)
check("symbols counted",  row["symbols"], 1)
check("p50",              row["lag_ms_p50"], 51)
check("p99",              row["lag_ms_p99"], 100)
check("max",              row["lag_ms_max"], 100)
check("counters reset",   st.rows, 0)
check("minute literal",   row["minute"], "1970-01-01 01:40:00")

print("== negative lag (clock skew) is clamped, not negative")
st2 = StreamStats(exchange="x", connector="c", stream="s", session_id="sid")
st2.roll(200); st2.observe(nbytes=1, rows=1, lag_ms=-500, symbol="BTC")
check("clamped to zero", st2.roll(201)["lag_ms_p50"], 0)

print()
print("ALL PASSED" if not fails else f"FAILURES: {fails}")
raise SystemExit(1 if fails else 0)
