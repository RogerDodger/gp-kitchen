-- OSRS GE Tracker Database Schema

-- Items table: stores item metadata from the OSRS Wiki API
CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    examine TEXT,
    members INTEGER DEFAULT 0,
    lowalch INTEGER,
    highalch INTEGER,
    ge_limit INTEGER,
    icon TEXT,
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Item prices table: stores current prices
CREATE TABLE IF NOT EXISTS item_prices (
    item_id INTEGER PRIMARY KEY REFERENCES items(id),
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

-- Conversions: defines input-output relationships
CREATE TABLE IF NOT EXISTS conversions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    active INTEGER DEFAULT 1,
    live INTEGER DEFAULT 0,
    sort_order INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Conversion inputs: items that go INTO a conversion (you BUY these)
CREATE TABLE IF NOT EXISTS conversion_inputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pair_id INTEGER NOT NULL REFERENCES conversions(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Conversion outputs: items that come OUT of a conversion (you SELL these)
CREATE TABLE IF NOT EXISTS conversion_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pair_id INTEGER NOT NULL REFERENCES conversions(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Aggregated volume data for conversion items (from timeseries API)
CREATE TABLE IF NOT EXISTS item_volumes (
    item_id INTEGER PRIMARY KEY REFERENCES items(id),
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

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_item_prices_updated ON item_prices(updated_at);
CREATE INDEX IF NOT EXISTS idx_conversions_active ON conversions(active);
CREATE INDEX IF NOT EXISTS idx_conversion_inputs_pair ON conversion_inputs(pair_id);
CREATE INDEX IF NOT EXISTS idx_conversion_outputs_pair ON conversion_outputs(pair_id);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);

-- View for calculating conversion profits
-- Profit = (Sum of output sell prices after tax) - (Sum of input buy prices)
-- GE Tax: 2% capped at 5M GP per item (as of May 2025)
CREATE VIEW IF NOT EXISTS conversion_profits AS
SELECT
    cp.id,
    cp.active,
    cp.sort_order,
    -- Total cost to buy inputs (using high_price = instant buy / ask price)
    COALESCE(inputs.total_cost, 0) AS input_cost,
    -- Total revenue from selling outputs (using low_price = instant sell / bid price)
    COALESCE(outputs.total_revenue, 0) AS output_revenue,
    -- Total GE tax (2% capped at 5M per item)
    COALESCE(outputs.total_tax, 0) AS total_tax,
    -- Revenue after tax
    COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) AS output_revenue_after_tax,
    -- Profit calculation
    COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) - COALESCE(inputs.total_cost, 0) AS profit,
    -- ROI percentage
    CASE
        WHEN COALESCE(inputs.total_cost, 0) > 0
        THEN ROUND((COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) - COALESCE(inputs.total_cost, 0)) * 100.0 / inputs.total_cost, 2)
        ELSE 0
    END AS roi_percent
FROM conversions cp
LEFT JOIN (
    SELECT
        ci.pair_id,
        SUM(COALESCE(ip.high_price, 0) * ci.quantity) AS total_cost
    FROM conversion_inputs ci
    LEFT JOIN item_prices ip ON ci.item_id = ip.item_id
    GROUP BY ci.pair_id
) inputs ON cp.id = inputs.pair_id
LEFT JOIN (
    SELECT
        co.pair_id,
        SUM(COALESCE(ip.low_price, 0) * co.quantity) AS total_revenue,
        SUM(
            CASE
                WHEN co.item_id = 995 THEN 0  -- No tax on coins
                ELSE MIN(CAST(COALESCE(ip.low_price, 0) * co.quantity * 0.02 AS INTEGER), 5000000 * co.quantity)
            END
        ) AS total_tax
    FROM conversion_outputs co
    LEFT JOIN item_prices ip ON co.item_id = ip.item_id
    GROUP BY co.pair_id
) outputs ON cp.id = outputs.pair_id;
