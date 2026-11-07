-- market.mark_price gains funding_interval_h: hours between funding payments.
-- Hyperliquid pays every hour, Binance and Bybit every 8, 4 or 1 hours by
-- symbol, so funding_rate alone cannot be compared across venues. Additive
-- and idempotent: existing rows read 0 (unknown), and 002_market.sql already
-- has it for tables created from scratch.
ALTER TABLE market.mark_price ADD COLUMN IF NOT EXISTS funding_interval_h UInt8 CODEC(ZSTD(1)) AFTER next_funding_time;
