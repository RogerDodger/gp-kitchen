#!/usr/bin/env perl
# Migration script: Rename presets tables to cookbooks
use strict;
use warnings;
use DBI;

my $db_path = $ARGV[0] // 'gp_kitchen.db';

print "Migrating database: $db_path\n";

my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', {
    RaiseError => 1,
    AutoCommit => 0,
});

# Disable foreign keys during migration
$dbh->do('PRAGMA foreign_keys = OFF');

eval {
    # Check if migration is needed
    my ($has_presets) = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='presets'"
    );

    unless ($has_presets) {
        print "No 'presets' table found - migration may have already been done or not needed.\n";
        $dbh->rollback;
        exit 0;
    }

    # Check if new tables already exist (from init_schema running with new schema)
    my ($has_cookbooks) = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='cookbooks'"
    );

    if ($has_cookbooks) {
        print "Both old and new tables exist. Dropping empty new tables first...\n";
        $dbh->do('DROP VIEW IF EXISTS cookbook_recipe_profits');
        $dbh->do('DROP TABLE IF EXISTS cookbook_imports');
        $dbh->do('DROP TABLE IF EXISTS cookbook_recipe_outputs');
        $dbh->do('DROP TABLE IF EXISTS cookbook_recipe_inputs');
        $dbh->do('DROP TABLE IF EXISTS cookbook_recipes');
        $dbh->do('DROP TABLE IF EXISTS cookbooks');
    }

    # Drop old views that reference old table names
    print "Dropping old views...\n";
    $dbh->do('DROP VIEW IF EXISTS preset_recipe_profits');

    # Rename tables
    print "Renaming tables...\n";
    $dbh->do('ALTER TABLE presets RENAME TO cookbooks');
    $dbh->do('ALTER TABLE preset_recipes RENAME TO cookbook_recipes');
    $dbh->do('ALTER TABLE preset_recipe_inputs RENAME TO cookbook_recipe_inputs');
    $dbh->do('ALTER TABLE preset_recipe_outputs RENAME TO cookbook_recipe_outputs');
    $dbh->do('ALTER TABLE preset_imports RENAME TO cookbook_imports');

    # Drop old indexes (will recreate after column renaming)
    print "Dropping old indexes...\n";
    $dbh->do('DROP INDEX IF EXISTS idx_preset_recipes_preset');
    $dbh->do('DROP INDEX IF EXISTS idx_preset_imports_preset');

    # Note: The cookbook_recipes table has a column named preset_id that should be cookbook_id
    # SQLite doesn't support renaming columns directly in older versions, so we need to recreate tables

    # Check if we need to rename the preset_id column
    my $col_info = $dbh->selectall_arrayref("PRAGMA table_info(cookbook_recipes)", { Slice => {} });
    my $has_preset_id = grep { $_->{name} eq 'preset_id' } @$col_info;

    if ($has_preset_id) {
        print "Renaming preset_id column to cookbook_id in cookbook_recipes...\n";

        # Create new table with correct column name
        $dbh->do(q{
            CREATE TABLE cookbook_recipes_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cookbook_id INTEGER NOT NULL REFERENCES cookbooks(id) ON DELETE CASCADE,
                sort_order INTEGER DEFAULT 0
            )
        });

        # Copy data
        $dbh->do(q{
            INSERT INTO cookbook_recipes_new (id, cookbook_id, sort_order)
            SELECT id, preset_id, sort_order FROM cookbook_recipes
        });

        # Drop old table and rename new one
        $dbh->do('DROP TABLE cookbook_recipes');
        $dbh->do('ALTER TABLE cookbook_recipes_new RENAME TO cookbook_recipes');

        # Recreate index
        $dbh->do('CREATE INDEX IF NOT EXISTS idx_cookbook_recipes_cookbook ON cookbook_recipes(cookbook_id)');
    }

    # Same for cookbook_imports
    $col_info = $dbh->selectall_arrayref("PRAGMA table_info(cookbook_imports)", { Slice => {} });
    $has_preset_id = grep { $_->{name} eq 'preset_id' } @$col_info;

    if ($has_preset_id) {
        print "Renaming preset_id column to cookbook_id in cookbook_imports...\n";

        $dbh->do(q{
            CREATE TABLE cookbook_imports_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cookbook_id INTEGER NOT NULL REFERENCES cookbooks(id) ON DELETE CASCADE,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                imported_at INTEGER DEFAULT (strftime('%s', 'now')),
                UNIQUE(cookbook_id, user_id)
            )
        });

        $dbh->do(q{
            INSERT INTO cookbook_imports_new (id, cookbook_id, user_id, imported_at)
            SELECT id, preset_id, user_id, imported_at FROM cookbook_imports
        });

        $dbh->do('DROP TABLE cookbook_imports');
        $dbh->do('ALTER TABLE cookbook_imports_new RENAME TO cookbook_imports');

        $dbh->do('CREATE INDEX IF NOT EXISTS idx_cookbook_imports_cookbook ON cookbook_imports(cookbook_id)');
    }

    # Create the new view for cookbook recipe profits
    print "Creating cookbook_recipe_profits view...\n";
    $dbh->do(q{
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
        ) outputs ON pr.id = outputs.recipe_id
    });

    $dbh->commit;
    print "Migration completed successfully!\n";
};

if ($@) {
    print "Migration failed: $@\n";
    $dbh->rollback;
    exit 1;
}

# Re-enable foreign keys
$dbh->do('PRAGMA foreign_keys = ON');
$dbh->disconnect;
