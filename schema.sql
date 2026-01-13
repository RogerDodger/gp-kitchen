-- GP Kitchen Database Schema

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

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT,          -- NULL for guest accounts
    is_guest INTEGER DEFAULT 0,
    is_admin INTEGER DEFAULT 0,
    last_active INTEGER DEFAULT (strftime('%s', 'now')),
    created_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Recipes: defines input-output relationships (user dashboards)
CREATE TABLE IF NOT EXISTS recipes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    active INTEGER DEFAULT 1,
    live INTEGER DEFAULT 0,
    sort_order INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Recipe inputs: items that go INTO a recipe (you BUY these)
CREATE TABLE IF NOT EXISTS recipe_inputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Recipe outputs: items that come OUT of a recipe (you SELL these)
CREATE TABLE IF NOT EXISTS recipe_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Cookbooks: admin-curated recipe collections
CREATE TABLE IF NOT EXISTS cookbooks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    created_by INTEGER REFERENCES users(id),
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Cookbook recipes
CREATE TABLE IF NOT EXISTS cookbook_recipes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cookbook_id INTEGER NOT NULL REFERENCES cookbooks(id) ON DELETE CASCADE,
    sort_order INTEGER DEFAULT 0
);

-- Cookbook recipe inputs
CREATE TABLE IF NOT EXISTS cookbook_recipe_inputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_id INTEGER NOT NULL REFERENCES cookbook_recipes(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Cookbook recipe outputs
CREATE TABLE IF NOT EXISTS cookbook_recipe_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_id INTEGER NOT NULL REFERENCES cookbook_recipes(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES items(id),
    quantity INTEGER NOT NULL DEFAULT 1
);

-- Cookbook imports: tracks which users imported which cookbooks
CREATE TABLE IF NOT EXISTS cookbook_imports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cookbook_id INTEGER NOT NULL REFERENCES cookbooks(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    imported_at INTEGER DEFAULT (strftime('%s', 'now')),
    UNIQUE(cookbook_id, user_id)
);

-- Aggregated volume data for items (from timeseries API)
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
CREATE INDEX IF NOT EXISTS idx_recipes_user ON recipes(user_id);
CREATE INDEX IF NOT EXISTS idx_recipes_active ON recipes(active);
CREATE INDEX IF NOT EXISTS idx_recipe_inputs_recipe ON recipe_inputs(recipe_id);
CREATE INDEX IF NOT EXISTS idx_recipe_outputs_recipe ON recipe_outputs(recipe_id);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_last_active ON users(last_active);
CREATE INDEX IF NOT EXISTS idx_cookbook_recipes_cookbook ON cookbook_recipes(cookbook_id);
CREATE INDEX IF NOT EXISTS idx_cookbook_imports_cookbook ON cookbook_imports(cookbook_id);

-- View for calculating recipe profits
-- Profit = (Sum of output sell prices after tax) - (Sum of input buy prices)
-- GE Tax: 2% capped at 5M GP per item (as of May 2025)
CREATE VIEW IF NOT EXISTS recipe_profits AS
SELECT
    r.id,
    r.user_id,
    r.active,
    r.sort_order,
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
FROM recipes r
LEFT JOIN (
    SELECT
        ri.recipe_id,
        SUM(COALESCE(ip.high_price, 0) * ri.quantity) AS total_cost
    FROM recipe_inputs ri
    LEFT JOIN item_prices ip ON ri.item_id = ip.item_id
    GROUP BY ri.recipe_id
) inputs ON r.id = inputs.recipe_id
LEFT JOIN (
    SELECT
        ro.recipe_id,
        SUM(COALESCE(ip.low_price, 0) * ro.quantity) AS total_revenue,
        SUM(
            CASE
                WHEN ro.item_id = 995 THEN 0  -- No tax on coins
                ELSE MIN(CAST(COALESCE(ip.low_price, 0) * ro.quantity * 0.02 AS INTEGER), 5000000 * ro.quantity)
            END
        ) AS total_tax
    FROM recipe_outputs ro
    LEFT JOIN item_prices ip ON ro.item_id = ip.item_id
    GROUP BY ro.recipe_id
) outputs ON r.id = outputs.recipe_id;

-- View for calculating cookbook recipe profits (same logic as recipe_profits)
CREATE VIEW IF NOT EXISTS cookbook_recipe_profits AS
SELECT
    pr.id,
    pr.cookbook_id,
    pr.sort_order,
    COALESCE(inputs.total_cost, 0) AS input_cost,
    COALESCE(outputs.total_revenue, 0) AS output_revenue,
    COALESCE(outputs.total_tax, 0) AS total_tax,
    COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) AS output_revenue_after_tax,
    COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) - COALESCE(inputs.total_cost, 0) AS profit,
    CASE
        WHEN COALESCE(inputs.total_cost, 0) > 0
        THEN ROUND((COALESCE(outputs.total_revenue, 0) - COALESCE(outputs.total_tax, 0) - COALESCE(inputs.total_cost, 0)) * 100.0 / inputs.total_cost, 2)
        ELSE 0
    END AS roi_percent
FROM cookbook_recipes pr
LEFT JOIN (
    SELECT
        pri.recipe_id,
        SUM(COALESCE(ip.high_price, 0) * pri.quantity) AS total_cost
    FROM cookbook_recipe_inputs pri
    LEFT JOIN item_prices ip ON pri.item_id = ip.item_id
    GROUP BY pri.recipe_id
) inputs ON pr.id = inputs.recipe_id
LEFT JOIN (
    SELECT
        pro.recipe_id,
        SUM(COALESCE(ip.low_price, 0) * pro.quantity) AS total_revenue,
        SUM(
            CASE
                WHEN pro.item_id = 995 THEN 0
                ELSE MIN(CAST(COALESCE(ip.low_price, 0) * pro.quantity * 0.02 AS INTEGER), 5000000 * pro.quantity)
            END
        ) AS total_tax
    FROM cookbook_recipe_outputs pro
    LEFT JOIN item_prices ip ON pro.item_id = ip.item_id
    GROUP BY pro.recipe_id
) outputs ON pr.id = outputs.recipe_id;
