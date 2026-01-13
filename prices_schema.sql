-- GP Kitchen Prices Database Schema
-- Separate database for price data to avoid write lock contention

-- Item prices table: stores current prices
CREATE TABLE IF NOT EXISTS item_prices (
    item_id INTEGER PRIMARY KEY,
    high_price INTEGER,          -- Last instant-buy (ask) price
    high_time INTEGER,           -- Unix timestamp of last instant-buy
    low_price INTEGER,           -- Last instant-sell (bid) price
    low_time INTEGER,            -- Unix timestamp of last instant-sell
    avg_high_price INTEGER,      -- 5-minute average high
    avg_low_price INTEGER,       -- 5-minute average low
    high_volume INTEGER,         -- Volume at high price in last 5 min
    low_volume INTEGER,          -- Volume at low price in last 5 min
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Aggregated volume data for items (from timeseries API)
CREATE TABLE IF NOT EXISTS item_volumes (
    item_id INTEGER PRIMARY KEY,
    vol_5m_high INTEGER DEFAULT 0,
    vol_5m_low INTEGER DEFAULT 0,
    vol_4h_high INTEGER DEFAULT 0,
    vol_4h_low INTEGER DEFAULT 0,
    vol_24h_high INTEGER DEFAULT 0,
    vol_24h_low INTEGER DEFAULT 0,
    vol_7d_high INTEGER DEFAULT 0,
    vol_7d_low INTEGER DEFAULT 0,
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_item_prices_updated ON item_prices(updated_at);
