package OSRS::GE::Schema;
use strict;
use warnings;
use DBI;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Crypt::Bcrypt qw(bcrypt bcrypt_check);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        db_path        => $args{db_path} // 'data/osrs_ge.db',
        prices_db_path => $args{prices_db_path} // 'data/prices.db',
        dbh            => undef,
        prices_dbh     => undef,
    }, $class;
    return $self;
}

sub connect {
    my ($self) = @_;
    return $self->{dbh} if $self->{dbh};

    # Ensure directories exist
    for my $path ($self->{db_path}, $self->{prices_db_path}) {
        my $dir = dirname($path);
        make_path($dir) unless -d $dir;
    }

    # Connect to main database
    $self->{dbh} = DBI->connect(
        "dbi:SQLite:dbname=$self->{db_path}",
        '', '',
        {
            RaiseError     => 1,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );
    $self->{dbh}->do('PRAGMA foreign_keys = ON');
    $self->{dbh}->do('PRAGMA cache_size = -32000');  # 32MB cache

    # Attach prices database for reading
    $self->{dbh}->do("ATTACH DATABASE '$self->{prices_db_path}' AS prices");

    return $self->{dbh};
}

sub connect_prices {
    my ($self) = @_;
    return $self->{prices_dbh} if $self->{prices_dbh};

    # Ensure directory exists
    my $dir = dirname($self->{prices_db_path});
    make_path($dir) unless -d $dir;

    # Separate connection for price writes (independent lock)
    $self->{prices_dbh} = DBI->connect(
        "dbi:SQLite:dbname=$self->{prices_db_path}",
        '', '',
        {
            RaiseError     => 1,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );

    return $self->{prices_dbh};
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh} // $self->connect;
}

sub prices_dbh {
    my ($self) = @_;
    return $self->{prices_dbh} // $self->connect_prices;
}

sub init_schema {
    my ($self, $schema_file, $prices_schema_file) = @_;
    $schema_file //= 'schema.sql';
    $prices_schema_file //= 'prices_schema.sql';

    # Enable WAL mode for better concurrent read performance (persistent setting)
    $self->dbh->do('PRAGMA journal_mode = WAL');
    $self->prices_dbh->do('PRAGMA journal_mode = WAL');

    # Initialize prices database first (needed before main schema due to ATTACH)
    $self->_init_schema_file($self->prices_dbh, $prices_schema_file);

    # Initialize main database (will ATTACH prices)
    $self->_init_schema_file($self->dbh, $schema_file);

    # Ensure coins exists
    $self->_init_coins;

    return 1;
}

sub _init_schema_file {
    my ($self, $dbh, $schema_file) = @_;

    open my $fh, '<', $schema_file or die "Cannot open $schema_file: $!";
    my $sql = do { local $/; <$fh> };
    close $fh;

    # Split by semicolons and execute each statement
    my @statements = grep { /\S/ } split /;/, $sql;
    for my $stmt (@statements) {
        next unless $stmt =~ /\S/;
        $dbh->do($stmt);
    }
}

sub _init_coins {
    my ($self) = @_;

    # Insert coins item in main db
    $self->dbh->do(q{
        INSERT OR IGNORE INTO items (id, name, examine, members, lowalch, highalch, ge_limit, icon, updated_at)
        VALUES (995, 'Coins', 'Lovely money!', 0, 0, 0, 0, 'Coins_10000.png', strftime('%s', 'now'))
    });

    # Set coins price to 1 gp in prices db
    $self->prices_dbh->do(q{
        INSERT OR REPLACE INTO item_prices (item_id, high_price, high_time, low_price, low_time, updated_at)
        VALUES (995, 1, strftime('%s', 'now'), 1, strftime('%s', 'now'), strftime('%s', 'now'))
    });
}

# =====================================
# Migration
# =====================================

sub migrate {
    my ($self, $admin_password) = @_;
    my $dbh = $self->dbh;

    # Check if migration is needed (do old tables exist?)
    my $has_conversions = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='conversions'"
    );

    return unless $has_conversions;

    # Check if new tables already exist
    my $has_recipes = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='recipes'"
    );
    return if $has_recipes;

    $dbh->begin_work;
    eval {
        # Create admin user first
        my $password_hash = bcrypt($admin_password, '2b', 12, _random_salt());
        $dbh->do(q{
            INSERT INTO users (username, password_hash, is_guest, is_admin)
            VALUES ('admin', ?, 0, 1)
        }, undef, $password_hash);
        my $admin_id = $dbh->last_insert_id(undef, undef, 'users', 'id');

        # Migrate conversions to recipes
        $dbh->do(q{
            INSERT INTO recipes (id, user_id, active, live, sort_order, created_at, updated_at)
            SELECT id, ?, active, live, sort_order, created_at, updated_at
            FROM conversions
        }, undef, $admin_id);

        # Migrate conversion_inputs to recipe_inputs
        $dbh->do(q{
            INSERT INTO recipe_inputs (id, recipe_id, item_id, quantity)
            SELECT id, pair_id, item_id, quantity
            FROM conversion_inputs
        });

        # Migrate conversion_outputs to recipe_outputs
        $dbh->do(q{
            INSERT INTO recipe_outputs (id, recipe_id, item_id, quantity)
            SELECT id, pair_id, item_id, quantity
            FROM conversion_outputs
        });

        # Drop old view first (it depends on old tables)
        $dbh->do('DROP VIEW IF EXISTS conversion_profits');

        # Drop old tables
        $dbh->do('DROP TABLE IF EXISTS conversion_inputs');
        $dbh->do('DROP TABLE IF EXISTS conversion_outputs');
        $dbh->do('DROP TABLE IF EXISTS conversions');

        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        die "Migration failed: $@";
    }
}

sub migrate_prices_to_separate_db {
    my ($self) = @_;
    my $dbh = $self->dbh;
    my $prices_dbh = $self->prices_dbh;

    # Check if old item_prices table exists in main database
    my $has_old_prices = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='item_prices'"
    );
    return unless $has_old_prices;

    # Check if prices db already has data (avoid duplicate migration)
    my ($prices_count) = $prices_dbh->selectrow_array('SELECT COUNT(*) FROM item_prices');
    if ($prices_count > 1) {  # > 1 because coins (995) is always inserted
        # Already migrated, just drop old tables
        $dbh->do('DROP TABLE IF EXISTS item_prices');
        $dbh->do('DROP TABLE IF EXISTS item_volumes');
        return;
    }

    # Migrate item_prices
    my $old_prices = $dbh->selectall_arrayref(
        'SELECT * FROM item_prices', { Slice => {} }
    );
    if (@$old_prices) {
        $prices_dbh->begin_work;
        eval {
            my $sth = $prices_dbh->prepare(q{
                INSERT OR REPLACE INTO item_prices
                (item_id, high_price, high_time, low_price, low_time,
                 avg_high_price, avg_low_price, high_volume, low_volume, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            });
            for my $p (@$old_prices) {
                $sth->execute(
                    $p->{item_id}, $p->{high_price}, $p->{high_time},
                    $p->{low_price}, $p->{low_time}, $p->{avg_high_price},
                    $p->{avg_low_price}, $p->{high_volume}, $p->{low_volume},
                    $p->{updated_at}
                );
            }
            $prices_dbh->commit;
        };
        if ($@) {
            $prices_dbh->rollback;
            die "Price migration failed: $@";
        }
    }

    # Migrate item_volumes if exists
    my $has_old_volumes = $dbh->selectrow_array(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='item_volumes'"
    );
    if ($has_old_volumes) {
        my $old_volumes = $dbh->selectall_arrayref(
            'SELECT * FROM item_volumes', { Slice => {} }
        );
        if (@$old_volumes) {
            $prices_dbh->begin_work;
            eval {
                my $sth = $prices_dbh->prepare(q{
                    INSERT OR REPLACE INTO item_volumes
                    (item_id, vol_5m_high, vol_5m_low, vol_4h_high, vol_4h_low,
                     vol_24h_high, vol_24h_low, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                });
                for my $v (@$old_volumes) {
                    $sth->execute(
                        $v->{item_id}, $v->{vol_5m_high}, $v->{vol_5m_low},
                        $v->{vol_4h_high}, $v->{vol_4h_low}, $v->{vol_24h_high},
                        $v->{vol_24h_low}, $v->{updated_at}
                    );
                }
                $prices_dbh->commit;
            };
            if ($@) {
                $prices_dbh->rollback;
                die "Volume migration failed: $@";
            }
        }
    }

    # Drop old tables from main database
    $dbh->do('DROP TABLE IF EXISTS item_prices');
    $dbh->do('DROP TABLE IF EXISTS item_volumes');
}

sub _random_salt {
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $salt = '';
    $salt .= $chars[rand @chars] for 1..16;
    return $salt;
}

# =====================================
# User methods
# =====================================

sub create_user {
    my ($self, %args) = @_;
    my $dbh = $self->dbh;

    my $password_hash = undef;
    if ($args{password}) {
        $password_hash = bcrypt($args{password}, '2b', 12, _random_salt());
    }

    $dbh->do(q{
        INSERT INTO users (username, password_hash, is_guest, is_admin)
        VALUES (?, ?, ?, ?)
    }, undef,
        $args{username},
        $password_hash,
        $args{is_guest} ? 1 : 0,
        $args{is_admin} ? 1 : 0,
    );

    return $dbh->last_insert_id(undef, undef, 'users', 'id');
}

sub create_guest_user {
    my ($self) = @_;
    my $username = 'guest_' . _random_string(12);
    return $self->create_user(
        username => $username,
        is_guest => 1,
    );
}

sub _random_string {
    my ($len) = @_;
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $str = '';
    $str .= $chars[rand @chars] for 1..$len;
    return $str;
}

sub get_user {
    my ($self, $id) = @_;
    return $self->dbh->selectrow_hashref(
        'SELECT * FROM users WHERE id = ?', undef, $id
    );
}

sub get_user_by_username {
    my ($self, $username) = @_;
    return $self->dbh->selectrow_hashref(
        'SELECT * FROM users WHERE username = ?', undef, $username
    );
}

sub authenticate_user {
    my ($self, $username, $password) = @_;
    my $user = $self->get_user_by_username($username);
    return unless $user && $user->{password_hash};
    return bcrypt_check($password, $user->{password_hash}) ? $user : undef;
}

sub update_user_last_active {
    my ($self, $user_id) = @_;
    $self->dbh->do(q{
        UPDATE users SET last_active = strftime('%s', 'now') WHERE id = ?
    }, undef, $user_id);
}

sub register_guest {
    my ($self, $user_id, $username, $password) = @_;
    my $dbh = $self->dbh;

    # Check username availability
    my $existing = $self->get_user_by_username($username);
    return { error => 'Username already taken' } if $existing;

    my $password_hash = bcrypt($password, '2b', 12, _random_salt());

    $dbh->do(q{
        UPDATE users SET username = ?, password_hash = ?, is_guest = 0
        WHERE id = ? AND is_guest = 1
    }, undef, $username, $password_hash, $user_id);

    return { success => 1 };
}

sub update_password {
    my ($self, $user_id, $current_password, $new_password) = @_;
    my $dbh = $self->dbh;

    # Get user and verify current password
    my $user = $self->get_user($user_id);
    return { error => 'User not found' } unless $user;
    return { error => 'Cannot change password for guest accounts' } if $user->{is_guest};

    if (!bcrypt_check($current_password, $user->{password_hash})) {
        return { error => 'Current password is incorrect' };
    }

    my $password_hash = bcrypt($new_password, '2b', 12, _random_salt());
    $dbh->do(q{
        UPDATE users SET password_hash = ?
        WHERE id = ?
    }, undef, $password_hash, $user_id);

    return { success => 1 };
}

sub cleanup_inactive_guests {
    my ($self, $days, $dry_run) = @_;
    $days //= 30;
    my $cutoff = time() - ($days * 86400);

    if ($dry_run) {
        return $self->dbh->selectrow_array(
            "SELECT COUNT(*) FROM users WHERE is_guest = 1 AND last_active < ?",
            undef, $cutoff
        );
    }

    my $sth = $self->dbh->do(q{
        DELETE FROM users WHERE is_guest = 1 AND last_active < ?
    }, undef, $cutoff);
    return $sth;
}

# =====================================
# Item methods
# =====================================

sub upsert_item {
    my ($self, $item) = @_;
    my $sql = q{
        INSERT INTO items (id, name, examine, members, lowalch, highalch, ge_limit, icon, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            examine = excluded.examine,
            members = excluded.members,
            lowalch = excluded.lowalch,
            highalch = excluded.highalch,
            ge_limit = excluded.ge_limit,
            icon = excluded.icon,
            updated_at = strftime('%s', 'now')
    };
    $self->dbh->do($sql, undef,
        $item->{id},
        $item->{name},
        $item->{examine},
        $item->{members} ? 1 : 0,
        $item->{lowalch},
        $item->{highalch},
        $item->{limit},
        $item->{icon},
    );
}

sub get_item {
    my ($self, $id) = @_;
    my $sql = q{
        SELECT i.*, ip.high_price, ip.high_time, ip.low_price, ip.low_time,
               iv.vol_24h_high, iv.vol_24h_low
        FROM items i
        LEFT JOIN prices.item_prices ip ON i.id = ip.item_id
        LEFT JOIN prices.item_volumes iv ON i.id = iv.item_id
        WHERE i.id = ?
    };
    return $self->dbh->selectrow_hashref($sql, undef, $id);
}

sub search_items {
    my ($self, $query, $limit) = @_;
    my $sql = q{
        SELECT i.*, ip.high_price, ip.high_time, ip.low_price, ip.low_time,
               iv.vol_24h_high, iv.vol_24h_low
        FROM items i
        LEFT JOIN prices.item_prices ip ON i.id = ip.item_id
        LEFT JOIN prices.item_volumes iv ON i.id = iv.item_id
        WHERE i.name LIKE ?
        ORDER BY i.name
    };
    if ($limit) {
        $sql .= " LIMIT ?";
        return $self->dbh->selectall_arrayref($sql, { Slice => {} }, "%$query%", $limit);
    }
    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, "%$query%");
}

# =====================================
# Price methods (write to prices_dbh)
# =====================================

sub upsert_price {
    my ($self, $item_id, $price_data) = @_;
    my $sql = q{
        INSERT INTO item_prices (item_id, high_price, high_time, low_price, low_time,
                                 avg_high_price, avg_low_price, high_volume, low_volume, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(item_id) DO UPDATE SET
            high_price = COALESCE(excluded.high_price, item_prices.high_price),
            high_time = COALESCE(excluded.high_time, item_prices.high_time),
            low_price = COALESCE(excluded.low_price, item_prices.low_price),
            low_time = COALESCE(excluded.low_time, item_prices.low_time),
            avg_high_price = COALESCE(excluded.avg_high_price, item_prices.avg_high_price),
            avg_low_price = COALESCE(excluded.avg_low_price, item_prices.avg_low_price),
            high_volume = COALESCE(excluded.high_volume, item_prices.high_volume),
            low_volume = COALESCE(excluded.low_volume, item_prices.low_volume),
            updated_at = strftime('%s', 'now')
    };
    $self->prices_dbh->do($sql, undef,
        $item_id,
        $price_data->{high},
        $price_data->{highTime},
        $price_data->{low},
        $price_data->{lowTime},
        $price_data->{avgHighPrice},
        $price_data->{avgLowPrice},
        $price_data->{highPriceVolume},
        $price_data->{lowPriceVolume},
    );
}

sub bulk_upsert_prices {
    my ($self, $prices) = @_;
    my $prices_dbh = $self->prices_dbh;

    # Get set of known item IDs from main db to avoid orphan prices
    my $known_ids = $self->dbh->selectcol_arrayref('SELECT id FROM items');
    my %known = map { $_ => 1 } @$known_ids;

    $prices_dbh->begin_work;
    eval {
        my $sql = q{
            INSERT INTO item_prices (item_id, high_price, high_time, low_price, low_time, updated_at)
            VALUES (?, ?, ?, ?, ?, strftime('%s', 'now'))
            ON CONFLICT(item_id) DO UPDATE SET
                high_price = COALESCE(excluded.high_price, item_prices.high_price),
                high_time = COALESCE(excluded.high_time, item_prices.high_time),
                low_price = COALESCE(excluded.low_price, item_prices.low_price),
                low_time = COALESCE(excluded.low_time, item_prices.low_time),
                updated_at = strftime('%s', 'now')
        };
        my $sth = $prices_dbh->prepare($sql);

        for my $item_id (keys %$prices) {
            next unless $known{$item_id};  # Skip unknown items
            next if $item_id == 995;       # Skip coins (fixed at 1 gp)
            my $p = $prices->{$item_id};
            $sth->execute($item_id, $p->{high}, $p->{highTime}, $p->{low}, $p->{lowTime});
        }
        $prices_dbh->commit;
    };
    if ($@) {
        $prices_dbh->rollback;
        die "Bulk price update failed: $@";
    }
}

# =====================================
# Recipe methods
# =====================================

sub create_recipe {
    my ($self, $user_id) = @_;
    my $dbh = $self->dbh;
    my ($max_order) = $dbh->selectrow_array(
        'SELECT COALESCE(MAX(sort_order), -1) FROM recipes WHERE user_id = ?',
        undef, $user_id
    );
    my $sql = q{
        INSERT INTO recipes (user_id, sort_order, created_at, updated_at)
        VALUES (?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    };
    $dbh->do($sql, undef, $user_id, $max_order + 1);
    return $dbh->last_insert_id(undef, undef, 'recipes', 'id');
}

sub delete_recipe {
    my ($self, $id, $mode) = @_;
    $mode //= 'recipe';
    my $table = $mode eq 'recipe' ? 'recipes' : 'cookbook_recipes';
    $self->dbh->do("DELETE FROM $table WHERE id = ?", undef, $id);
}

sub toggle_recipe_active {
    my ($self, $id) = @_;
    $self->dbh->do(q{
        UPDATE recipes SET active = NOT active, updated_at = strftime('%s', 'now')
        WHERE id = ?
    }, undef, $id);
}

sub toggle_recipe_live {
    my ($self, $id, $user_id) = @_;
    my $dbh = $self->dbh;

    # Get current state
    my $recipe = $dbh->selectrow_hashref(
        'SELECT id, live FROM recipes WHERE id = ? AND user_id = ?',
        undef, $id, $user_id
    );
    return unless $recipe;

    my $new_live = $recipe->{live} ? 0 : 1;

    # Get all recipes for this user in current visual order
    my $all = $dbh->selectall_arrayref(
        'SELECT id, live FROM recipes WHERE user_id = ? ORDER BY live DESC, sort_order, id',
        { Slice => {} }, $user_id
    );

    # Remove the toggled recipe from the list
    my @others = grep { $_->{id} != $id } @$all;

    # Find insertion point
    my @new_order;
    if ($new_live) {
        # Toggling ON: insert at bottom of live section
        my @live = grep { $_->{live} } @others;
        my @dormant = grep { !$_->{live} } @others;
        @new_order = (@live, $id, @dormant);
    } else {
        # Toggling OFF: insert at top of dormant section
        my @live = grep { $_->{live} } @others;
        my @dormant = grep { !$_->{live} } @others;
        @new_order = (@live, $id, @dormant);
    }

    # Extract just the IDs
    @new_order = map { ref($_) ? $_->{id} : $_ } @new_order;

    # Update the live status
    $dbh->do(q{
        UPDATE recipes SET live = ?, updated_at = strftime('%s', 'now')
        WHERE id = ?
    }, undef, $new_live, $id);

    # Renumber all
    $self->reorder_recipes(\@new_order);
}

sub reorder_recipes {
    my ($self, $ids, $mode) = @_;
    $mode //= 'recipe';
    my $table = $mode eq 'recipe' ? 'recipes' : 'cookbook_recipes';
    my $order = 0;
    for my $id (@$ids) {
        $self->dbh->do("UPDATE $table SET sort_order = ? WHERE id = ?",
            undef, $order++, $id);
    }
}

sub swap_recipe_order {
    my ($self, $ids, $id, $dir, $mode) = @_;
    $mode //= 'recipe';
    my $table = $mode eq 'recipe' ? 'recipes' : 'cookbook_recipes';

    my ($idx) = grep { $ids->[$_] == $id } 0..$#$ids;
    return unless defined $idx;

    my $swap_idx = $dir eq 'up' ? $idx - 1 : $idx + 1;
    return if $swap_idx < 0 || $swap_idx > $#$ids;

    # For user recipes, check if both items have same live status
    if ($mode eq 'recipe') {
        my $live_status = $self->dbh->selectall_hashref(
            'SELECT id, live FROM recipes WHERE id IN (?, ?)',
            'id', undef, $ids->[$idx], $ids->[$swap_idx]
        );
        return unless $live_status->{$ids->[$idx]}{live} == $live_status->{$ids->[$swap_idx]}{live};
    }

    @$ids[$idx, $swap_idx] = @$ids[$swap_idx, $idx];
    $self->reorder_recipes($ids, $mode);
}

# Helper to fetch inputs/outputs for a recipe
# $mode: 'recipe' for user recipes, 'cookbook_recipe' for cookbook recipes
# $with_volumes: include volume data (for list views)
sub _fetch_recipe_items {
    my ($self, $recipe_id, $mode, $with_volumes) = @_;
    $mode //= 'recipe';
    my $input_table = "${mode}_inputs";
    my $output_table = "${mode}_outputs";

    my $volume_cols = $with_volumes
        ? ', ip.high_time, ip.low_time, iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low, iv.vol_24h_high, iv.vol_24h_low'
        : '';
    my $volume_join = $with_volumes
        ? 'LEFT JOIN prices.item_volumes iv ON t.item_id = iv.item_id'
        : '';

    my $inputs = $self->dbh->selectall_arrayref(qq{
        SELECT t.*, i.name, i.icon, ip.high_price, ip.low_price$volume_cols
        FROM $input_table t
        JOIN items i ON t.item_id = i.id
        LEFT JOIN prices.item_prices ip ON t.item_id = ip.item_id
        $volume_join
        WHERE t.recipe_id = ?
    }, { Slice => {} }, $recipe_id);

    my $outputs = $self->dbh->selectall_arrayref(qq{
        SELECT t.*, i.name, i.icon, ip.high_price, ip.low_price$volume_cols
        FROM $output_table t
        JOIN items i ON t.item_id = i.id
        LEFT JOIN prices.item_prices ip ON t.item_id = ip.item_id
        $volume_join
        WHERE t.recipe_id = ?
    }, { Slice => {} }, $recipe_id);

    return ($inputs, $outputs);
}

# Compute profit data from inputs/outputs
sub _compute_profit {
    my ($self, $inputs, $outputs) = @_;

    my $input_cost = 0;
    for my $input (@$inputs) {
        $input_cost += ($input->{high_price} // 0) * ($input->{quantity} // 1);
    }

    my $output_revenue = 0;
    my $total_tax = 0;
    for my $output (@$outputs) {
        my $price = $output->{low_price} // 0;
        my $qty = $output->{quantity} // 1;
        my $revenue = $price * $qty;
        $output_revenue += $revenue;

        # GE tax: 2% capped at 5M per item (no tax on coins, item_id 995)
        unless (($output->{item_id} // 0) == 995) {
            my $tax = int($revenue * 0.02);
            my $max_tax = 5_000_000 * $qty;
            $total_tax += ($tax > $max_tax ? $max_tax : $tax);
        }
    }

    my $profit = $output_revenue - $total_tax - $input_cost;
    my $roi = $input_cost > 0 ? sprintf("%.2f", ($profit / $input_cost) * 100) : 0;

    return {
        input_cost               => $input_cost,
        output_revenue           => $output_revenue,
        total_tax                => $total_tax,
        output_revenue_after_tax => $output_revenue - $total_tax,
        profit                   => $profit,
        roi_percent              => $roi,
    };
}

sub get_recipe {
    my ($self, $id) = @_;
    my $recipe = $self->dbh->selectrow_hashref('SELECT * FROM recipes WHERE id = ?', undef, $id);
    return unless $recipe;

    ($recipe->{inputs}, $recipe->{outputs}) = $self->_fetch_recipe_items($id, 'recipe');
    return $recipe;
}

sub get_all_recipes {
    my ($self, $user_id, $active_only) = @_;
    my $sql = 'SELECT * FROM recipes WHERE user_id = ?';
    $sql .= ' AND active = 1' if $active_only;
    $sql .= ' ORDER BY sort_order, id';

    my $recipes = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $user_id);

    for my $recipe (@$recipes) {
        ($recipe->{inputs}, $recipe->{outputs}) = $self->_fetch_recipe_items($recipe->{id}, 'recipe', 1);
        my $profit = $self->_compute_profit($recipe->{inputs}, $recipe->{outputs});
        $recipe->{$_} = $profit->{$_} for keys %$profit;
    }

    return $recipes;
}

# =====================================
# Recipe Input/Output management
# =====================================

# Generic recipe item management (works for both user recipes and cookbook recipes)
# $mode: 'recipe' for user recipes, 'cookbook_recipe' for cookbook recipes
# $type: 'input' or 'output'
sub add_recipe_item {
    my ($self, $recipe_id, $item_id, $quantity, $type, $mode) = @_;
    $quantity //= 1;
    $mode //= 'recipe';
    my $table = "${mode}_${type}s";
    $self->dbh->do(
        "INSERT INTO $table (recipe_id, item_id, quantity) VALUES (?, ?, ?)",
        undef, $recipe_id, $item_id, $quantity
    );
    return $self->dbh->last_insert_id(undef, undef, $table, 'id');
}

sub remove_recipe_item {
    my ($self, $item_id, $type, $mode) = @_;
    $mode //= 'recipe';
    my $table = "${mode}_${type}s";
    $self->dbh->do("DELETE FROM $table WHERE id = ?", undef, $item_id);
}

# Convenience wrappers for user recipes
sub add_recipe_input {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    return $self->add_recipe_item($recipe_id, $item_id, $quantity, 'input', 'recipe');
}

sub add_recipe_output {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    return $self->add_recipe_item($recipe_id, $item_id, $quantity, 'output', 'recipe');
}

sub remove_recipe_input {
    my ($self, $input_id) = @_;
    $self->remove_recipe_item($input_id, 'input', 'recipe');
}

sub remove_recipe_output {
    my ($self, $output_id) = @_;
    $self->remove_recipe_item($output_id, 'output', 'recipe');
}

# =====================================
# Recipe ownership check
# =====================================

sub user_owns_recipe {
    my ($self, $user_id, $recipe_id) = @_;
    my ($count) = $self->dbh->selectrow_array(
        'SELECT 1 FROM recipes WHERE id = ? AND user_id = ?',
        undef, $recipe_id, $user_id
    );
    return $count;
}

# =====================================
# Stats
# =====================================

sub get_price_stats {
    my ($self) = @_;
    my $sql = q{
        SELECT
            COUNT(*) as total_items,
            COUNT(CASE WHEN high_price IS NOT NULL THEN 1 END) as items_with_high,
            COUNT(CASE WHEN low_price IS NOT NULL THEN 1 END) as items_with_low,
            MAX(updated_at) as last_update
        FROM prices.item_prices
    };
    return $self->dbh->selectrow_hashref($sql);
}

# =====================================
# Volume methods (write to prices_dbh)
# =====================================

sub upsert_5m_volumes {
    my ($self, $item_id, $high, $low) = @_;
    my $sql = q{
        INSERT INTO item_volumes (item_id, vol_5m_high, vol_5m_low, updated_at)
        VALUES (?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(item_id) DO UPDATE SET
            vol_5m_high = excluded.vol_5m_high,
            vol_5m_low = excluded.vol_5m_low,
            updated_at = strftime('%s', 'now')
    };
    $self->prices_dbh->do($sql, undef, $item_id, $high // 0, $low // 0);
}

sub upsert_4h_volumes {
    my ($self, $item_id, $high, $low) = @_;
    my $sql = q{
        INSERT INTO item_volumes (item_id, vol_4h_high, vol_4h_low, updated_at)
        VALUES (?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(item_id) DO UPDATE SET
            vol_4h_high = excluded.vol_4h_high,
            vol_4h_low = excluded.vol_4h_low,
            updated_at = strftime('%s', 'now')
    };
    $self->prices_dbh->do($sql, undef, $item_id, $high // 0, $low // 0);
}

sub upsert_24h_volumes {
    my ($self, $item_id, $high, $low) = @_;
    my $sql = q{
        INSERT INTO item_volumes (item_id, vol_24h_high, vol_24h_low, updated_at)
        VALUES (?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(item_id) DO UPDATE SET
            vol_24h_high = excluded.vol_24h_high,
            vol_24h_low = excluded.vol_24h_low,
            updated_at = strftime('%s', 'now')
    };
    $self->prices_dbh->do($sql, undef, $item_id, $high // 0, $low // 0);
}

# =====================================
# Cookbook methods
# =====================================

sub create_cookbook {
    my ($self, $name, $created_by) = @_;
    my $dbh = $self->dbh;
    my ($max_order) = $dbh->selectrow_array(
        'SELECT COALESCE(MAX(sort_order), -1) FROM cookbooks'
    );
    $dbh->do(q{
        INSERT INTO cookbooks (name, sort_order, created_by, created_at, updated_at)
        VALUES (?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    }, undef, $name, $max_order + 1, $created_by);
    return $dbh->last_insert_id(undef, undef, 'cookbooks', 'id');
}

sub update_cookbook {
    my ($self, $id, $name) = @_;
    $self->dbh->do(q{
        UPDATE cookbooks SET name = ?, updated_at = strftime('%s', 'now')
        WHERE id = ?
    }, undef, $name, $id);
}

sub delete_cookbook {
    my ($self, $id) = @_;
    $self->dbh->do('DELETE FROM cookbooks WHERE id = ?', undef, $id);
}

sub get_cookbook {
    my ($self, $id) = @_;
    my $cookbook = $self->dbh->selectrow_hashref(
        'SELECT * FROM cookbooks WHERE id = ?', undef, $id
    );
    return unless $cookbook;

    # Get import count
    my ($import_count) = $self->dbh->selectrow_array(
        'SELECT COUNT(*) FROM cookbook_imports WHERE cookbook_id = ?', undef, $id
    );
    $cookbook->{import_count} = $import_count // 0;

    return $cookbook;
}

sub get_all_cookbooks {
    my ($self, $limit) = @_;
    $limit //= 50;
    my $sql = q{
        SELECT p.*,
               COALESCE(ic.import_count, 0) as import_count,
               COALESCE(rc.recipe_count, 0) as total_recipes,
               u.username as created_by_username
        FROM cookbooks p
        LEFT JOIN (
            SELECT cookbook_id, COUNT(*) as import_count
            FROM cookbook_imports
            GROUP BY cookbook_id
        ) ic ON p.id = ic.cookbook_id
        LEFT JOIN (
            SELECT cookbook_id, COUNT(*) as recipe_count
            FROM cookbook_recipes
            GROUP BY cookbook_id
        ) rc ON p.id = rc.cookbook_id
        LEFT JOIN users u ON p.created_by = u.id
        ORDER BY p.sort_order, p.id
        LIMIT ?
    };
    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, $limit);
}

sub reorder_cookbooks {
    my ($self, $ids) = @_;
    my $order = 0;
    for my $id (@$ids) {
        $self->dbh->do("UPDATE cookbooks SET sort_order = ? WHERE id = ?",
            undef, $order++, $id);
    }
}

sub swap_cookbook_order {
    my ($self, $ids, $id, $dir) = @_;

    my ($idx) = grep { $ids->[$_] == $id } 0..$#$ids;
    return unless defined $idx;

    my $swap_idx = $dir eq 'up' ? $idx - 1 : $idx + 1;
    return if $swap_idx < 0 || $swap_idx > $#$ids;

    # Swap the two items
    ($ids->[$idx], $ids->[$swap_idx]) = ($ids->[$swap_idx], $ids->[$idx]);

    # Update all sort_order values
    $self->reorder_cookbooks($ids);
}

# =====================================
# Cookbook recipe methods
# =====================================

sub create_cookbook_recipe {
    my ($self, $cookbook_id) = @_;
    my $dbh = $self->dbh;
    my ($max_order) = $dbh->selectrow_array(
        'SELECT COALESCE(MAX(sort_order), -1) FROM cookbook_recipes WHERE cookbook_id = ?',
        undef, $cookbook_id
    );
    $dbh->do(q{
        INSERT INTO cookbook_recipes (cookbook_id, sort_order)
        VALUES (?, ?)
    }, undef, $cookbook_id, $max_order + 1);
    return $dbh->last_insert_id(undef, undef, 'cookbook_recipes', 'id');
}

sub delete_cookbook_recipe {
    my ($self, $id) = @_;
    $self->delete_recipe($id, 'cookbook_recipe');
}

sub get_cookbook_recipe {
    my ($self, $id) = @_;
    my $recipe = $self->dbh->selectrow_hashref('SELECT * FROM cookbook_recipes WHERE id = ?', undef, $id);
    return unless $recipe;

    ($recipe->{inputs}, $recipe->{outputs}) = $self->_fetch_recipe_items($id, 'cookbook_recipe');
    return $recipe;
}

sub get_cookbook_recipes {
    my ($self, $cookbook_id) = @_;
    my $sql = 'SELECT * FROM cookbook_recipes WHERE cookbook_id = ? ORDER BY sort_order, id';

    my $recipes = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $cookbook_id);

    for my $recipe (@$recipes) {
        ($recipe->{inputs}, $recipe->{outputs}) = $self->_fetch_recipe_items($recipe->{id}, 'cookbook_recipe', 1);
        my $profit = $self->_compute_profit($recipe->{inputs}, $recipe->{outputs});
        $recipe->{$_} = $profit->{$_} for keys %$profit;
    }

    return $recipes;
}

# Convenience wrappers for cookbook recipes (use generic methods)
sub add_cookbook_recipe_input {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    return $self->add_recipe_item($recipe_id, $item_id, $quantity, 'input', 'cookbook_recipe');
}

sub add_cookbook_recipe_output {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    return $self->add_recipe_item($recipe_id, $item_id, $quantity, 'output', 'cookbook_recipe');
}

sub remove_cookbook_recipe_input {
    my ($self, $input_id) = @_;
    $self->remove_recipe_item($input_id, 'input', 'cookbook_recipe');
}

sub remove_cookbook_recipe_output {
    my ($self, $output_id) = @_;
    $self->remove_recipe_item($output_id, 'output', 'cookbook_recipe');
}

# Check if recipe belongs to cookbook
sub cookbook_owns_recipe {
    my ($self, $cookbook_id, $recipe_id) = @_;
    my ($count) = $self->dbh->selectrow_array(
        'SELECT 1 FROM cookbook_recipes WHERE id = ? AND cookbook_id = ?',
        undef, $recipe_id, $cookbook_id
    );
    return $count;
}

# =====================================
# Cookbook import
# =====================================

sub import_cookbook {
    my ($self, $cookbook_id, $user_id, $recipe_ids) = @_;
    my $dbh = $self->dbh;

    $dbh->begin_work;
    eval {
        # Record the import (or ignore if already imported)
        $dbh->do(q{
            INSERT OR IGNORE INTO cookbook_imports (cookbook_id, user_id, imported_at)
            VALUES (?, ?, strftime('%s', 'now'))
        }, undef, $cookbook_id, $user_id);

        # Get max sort order for user's recipes
        my ($max_order) = $dbh->selectrow_array(
            'SELECT COALESCE(MAX(sort_order), -1) FROM recipes WHERE user_id = ?',
            undef, $user_id
        );

        # Import selected recipes
        for my $cookbook_recipe_id (@$recipe_ids) {
            # Verify recipe belongs to cookbook
            next unless $self->cookbook_owns_recipe($cookbook_id, $cookbook_recipe_id);

            $max_order++;

            # Create user recipe
            $dbh->do(q{
                INSERT INTO recipes (user_id, active, live, sort_order, created_at, updated_at)
                VALUES (?, 1, 0, ?, strftime('%s', 'now'), strftime('%s', 'now'))
            }, undef, $user_id, $max_order);
            my $new_recipe_id = $dbh->last_insert_id(undef, undef, 'recipes', 'id');

            # Copy inputs
            my $inputs = $dbh->selectall_arrayref(
                'SELECT item_id, quantity FROM cookbook_recipe_inputs WHERE recipe_id = ?',
                { Slice => {} }, $cookbook_recipe_id
            );
            for my $input (@$inputs) {
                $dbh->do(q{
                    INSERT INTO recipe_inputs (recipe_id, item_id, quantity)
                    VALUES (?, ?, ?)
                }, undef, $new_recipe_id, $input->{item_id}, $input->{quantity});
            }

            # Copy outputs
            my $outputs = $dbh->selectall_arrayref(
                'SELECT item_id, quantity FROM cookbook_recipe_outputs WHERE recipe_id = ?',
                { Slice => {} }, $cookbook_recipe_id
            );
            for my $output (@$outputs) {
                $dbh->do(q{
                    INSERT INTO recipe_outputs (recipe_id, item_id, quantity)
                    VALUES (?, ?, ?)
                }, undef, $new_recipe_id, $output->{item_id}, $output->{quantity});
            }
        }

        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        die "Import failed: $@";
    }

    return 1;
}

1;
