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

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_recipes_user ON recipes(user_id);
CREATE INDEX IF NOT EXISTS idx_recipes_active ON recipes(active);
CREATE INDEX IF NOT EXISTS idx_recipe_inputs_recipe ON recipe_inputs(recipe_id);
CREATE INDEX IF NOT EXISTS idx_recipe_outputs_recipe ON recipe_outputs(recipe_id);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_last_active ON users(last_active);
CREATE INDEX IF NOT EXISTS idx_cookbook_recipes_cookbook ON cookbook_recipes(cookbook_id);
CREATE INDEX IF NOT EXISTS idx_cookbook_imports_cookbook ON cookbook_imports(cookbook_id);

-- Note: Profit calculations are done in application code since SQLite views
-- cannot reference attached databases (prices.item_prices)
