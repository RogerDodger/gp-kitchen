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
        db_path => $args{db_path} // 'data/osrs_ge.db',
        dbh     => undef,
    }, $class;
    return $self;
}

sub connect {
    my ($self) = @_;
    return $self->{dbh} if $self->{dbh};

    # Ensure directory exists
    my $dir = dirname($self->{db_path});
    make_path($dir) unless -d $dir;

    $self->{dbh} = DBI->connect(
        "dbi:SQLite:dbname=$self->{db_path}",
        '', '',
        {
            RaiseError     => 1,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    );

    # Enable foreign keys
    $self->{dbh}->do('PRAGMA foreign_keys = ON');

    return $self->{dbh};
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh} // $self->connect;
}

sub init_schema {
    my ($self, $schema_file) = @_;
    $schema_file //= 'schema.sql';

    open my $fh, '<', $schema_file or die "Cannot open $schema_file: $!";
    my $sql = do { local $/; <$fh> };
    close $fh;

    # Split by semicolons and execute each statement
    my @statements = grep { /\S/ } split /;/, $sql;
    for my $stmt (@statements) {
        next unless $stmt =~ /\S/;
        $self->dbh->do($stmt);
    }

    # Ensure coins exists (ID 995) with fixed price of 1 gp
    $self->_init_coins;

    return 1;
}

sub _init_coins {
    my ($self) = @_;
    my $dbh = $self->dbh;

    # Insert coins item
    $dbh->do(q{
        INSERT OR IGNORE INTO items (id, name, examine, members, lowalch, highalch, ge_limit, icon, updated_at)
        VALUES (995, 'Coins', 'Lovely money!', 0, 0, 0, 0, 'Coins_10000.png', strftime('%s', 'now'))
    });

    # Set coins price to 1 gp
    $dbh->do(q{
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

sub cleanup_inactive_guests {
    my ($self, $days) = @_;
    $days //= 30;
    my $cutoff = time() - ($days * 86400);
    $self->dbh->do(q{
        DELETE FROM users WHERE is_guest = 1 AND last_active < ?
    }, undef, $cutoff);
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
               ip.avg_high_price, ip.avg_low_price, ip.high_volume, ip.low_volume
        FROM items i
        LEFT JOIN item_prices ip ON i.id = ip.item_id
        WHERE i.id = ?
    };
    return $self->dbh->selectrow_hashref($sql, undef, $id);
}

sub search_items {
    my ($self, $query, $limit) = @_;
    $limit //= 20;
    my $sql = q{
        SELECT i.*, ip.high_price, ip.low_price
        FROM items i
        LEFT JOIN item_prices ip ON i.id = ip.item_id
        WHERE i.name LIKE ?
        ORDER BY i.name
        LIMIT ?
    };
    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, "%$query%", $limit);
}

# =====================================
# Price methods
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
    $self->dbh->do($sql, undef,
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
    my $dbh = $self->dbh;

    # Get set of known item IDs to avoid foreign key violations
    my $known_ids = $dbh->selectcol_arrayref('SELECT id FROM items');
    my %known = map { $_ => 1 } @$known_ids;

    $dbh->begin_work;
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
        my $sth = $dbh->prepare($sql);

        for my $item_id (keys %$prices) {
            next unless $known{$item_id};  # Skip unknown items
            next if $item_id == 995;       # Skip coins (fixed at 1 gp)
            my $p = $prices->{$item_id};
            $sth->execute($item_id, $p->{high}, $p->{highTime}, $p->{low}, $p->{lowTime});
        }
        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        die "Bulk price update failed: $@";
    }
}

sub bulk_upsert_5m_prices {
    my ($self, $prices) = @_;
    my $dbh = $self->dbh;

    $dbh->begin_work;
    eval {
        my $sql = q{
            UPDATE item_prices SET
                avg_high_price = ?,
                avg_low_price = ?,
                high_volume = ?,
                low_volume = ?,
                updated_at = strftime('%s', 'now')
            WHERE item_id = ?
        };
        my $sth = $dbh->prepare($sql);

        for my $item_id (keys %$prices) {
            my $p = $prices->{$item_id};
            $sth->execute(
                $p->{avgHighPrice},
                $p->{avgLowPrice},
                $p->{highPriceVolume},
                $p->{lowPriceVolume},
                $item_id
            );
        }
        $dbh->commit;
    };
    if ($@) {
        $dbh->rollback;
        die "Bulk 5m price update failed: $@";
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
    my ($self, $id) = @_;
    $self->dbh->do('DELETE FROM recipes WHERE id = ?', undef, $id);
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
    my ($self, $ids) = @_;
    my $order = 0;
    for my $id (@$ids) {
        $self->dbh->do('UPDATE recipes SET sort_order = ? WHERE id = ?',
            undef, $order++, $id);
    }
}

sub get_recipe {
    my ($self, $id) = @_;
    my $sql = 'SELECT * FROM recipes WHERE id = ?';
    my $recipe = $self->dbh->selectrow_hashref($sql, undef, $id);
    return unless $recipe;

    # Get inputs
    $recipe->{inputs} = $self->dbh->selectall_arrayref(q{
        SELECT ri.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM recipe_inputs ri
        JOIN items i ON ri.item_id = i.id
        LEFT JOIN item_prices ip ON ri.item_id = ip.item_id
        WHERE ri.recipe_id = ?
    }, { Slice => {} }, $id);

    # Get outputs
    $recipe->{outputs} = $self->dbh->selectall_arrayref(q{
        SELECT ro.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM recipe_outputs ro
        JOIN items i ON ro.item_id = i.id
        LEFT JOIN item_prices ip ON ro.item_id = ip.item_id
        WHERE ro.recipe_id = ?
    }, { Slice => {} }, $id);

    return $recipe;
}

sub get_all_recipes {
    my ($self, $user_id, $active_only) = @_;
    my $sql = q{
        SELECT r.*,
               COALESCE(profit_data.input_cost, 0) as input_cost,
               COALESCE(profit_data.output_revenue, 0) as output_revenue,
               COALESCE(profit_data.total_tax, 0) as total_tax,
               COALESCE(profit_data.output_revenue_after_tax, 0) as output_revenue_after_tax,
               COALESCE(profit_data.profit, 0) as profit,
               COALESCE(profit_data.roi_percent, 0) as roi_percent
        FROM recipes r
        LEFT JOIN recipe_profits profit_data ON r.id = profit_data.id
        WHERE r.user_id = ?
    };
    $sql .= ' AND r.active = 1' if $active_only;
    $sql .= ' ORDER BY r.sort_order, r.id';

    my $recipes = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $user_id);

    # Fetch inputs and outputs for each recipe
    for my $recipe (@$recipes) {
        $recipe->{inputs} = $self->dbh->selectall_arrayref(q{
            SELECT ri.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM recipe_inputs ri
            JOIN items i ON ri.item_id = i.id
            LEFT JOIN item_prices ip ON ri.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON ri.item_id = iv.item_id
            WHERE ri.recipe_id = ?
        }, { Slice => {} }, $recipe->{id});

        $recipe->{outputs} = $self->dbh->selectall_arrayref(q{
            SELECT ro.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM recipe_outputs ro
            JOIN items i ON ro.item_id = i.id
            LEFT JOIN item_prices ip ON ro.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON ro.item_id = iv.item_id
            WHERE ro.recipe_id = ?
        }, { Slice => {} }, $recipe->{id});
    }

    return $recipes;
}

# =====================================
# Recipe Input/Output management
# =====================================

sub add_recipe_input {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    my $sql = 'INSERT INTO recipe_inputs (recipe_id, item_id, quantity) VALUES (?, ?, ?)';
    $self->dbh->do($sql, undef, $recipe_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'recipe_inputs', 'id');
}

sub add_recipe_output {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    my $sql = 'INSERT INTO recipe_outputs (recipe_id, item_id, quantity) VALUES (?, ?, ?)';
    $self->dbh->do($sql, undef, $recipe_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'recipe_outputs', 'id');
}

sub remove_recipe_input {
    my ($self, $input_id) = @_;
    $self->dbh->do('DELETE FROM recipe_inputs WHERE id = ?', undef, $input_id);
}

sub remove_recipe_output {
    my ($self, $output_id) = @_;
    $self->dbh->do('DELETE FROM recipe_outputs WHERE id = ?', undef, $output_id);
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
        FROM item_prices
    };
    return $self->dbh->selectrow_hashref($sql);
}

# =====================================
# Volume methods
# =====================================

sub upsert_item_volumes {
    my ($self, $item_id, $volumes) = @_;
    my $sql = q{
        INSERT INTO item_volumes (item_id, vol_5m_high, vol_5m_low, vol_4h_high, vol_4h_low,
                                  vol_24h_high, vol_24h_low, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
        ON CONFLICT(item_id) DO UPDATE SET
            vol_5m_high = excluded.vol_5m_high,
            vol_5m_low = excluded.vol_5m_low,
            vol_4h_high = excluded.vol_4h_high,
            vol_4h_low = excluded.vol_4h_low,
            vol_24h_high = excluded.vol_24h_high,
            vol_24h_low = excluded.vol_24h_low,
            updated_at = strftime('%s', 'now')
    };
    $self->dbh->do($sql, undef,
        $item_id,
        $volumes->{vol_5m_high} // 0,
        $volumes->{vol_5m_low} // 0,
        $volumes->{vol_4h_high} // 0,
        $volumes->{vol_4h_low} // 0,
        $volumes->{vol_24h_high} // 0,
        $volumes->{vol_24h_low} // 0,
    );
}

# =====================================
# Cookbook methods
# =====================================

sub create_cookbook {
    my ($self, $name, $created_by) = @_;
    my $dbh = $self->dbh;
    $dbh->do(q{
        INSERT INTO cookbooks (name, created_by, created_at, updated_at)
        VALUES (?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    }, undef, $name, $created_by);
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
               u.username as created_by_username
        FROM cookbooks p
        LEFT JOIN (
            SELECT cookbook_id, COUNT(*) as import_count
            FROM cookbook_imports
            GROUP BY cookbook_id
        ) ic ON p.id = ic.cookbook_id
        LEFT JOIN users u ON p.created_by = u.id
        ORDER BY import_count DESC, p.created_at DESC
        LIMIT ?
    };
    return $self->dbh->selectall_arrayref($sql, { Slice => {} }, $limit);
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
    $self->dbh->do('DELETE FROM cookbook_recipes WHERE id = ?', undef, $id);
}

sub get_cookbook_recipe {
    my ($self, $id) = @_;
    my $recipe = $self->dbh->selectrow_hashref(
        'SELECT * FROM cookbook_recipes WHERE id = ?', undef, $id
    );
    return unless $recipe;

    # Get inputs
    $recipe->{inputs} = $self->dbh->selectall_arrayref(q{
        SELECT pri.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM cookbook_recipe_inputs pri
        JOIN items i ON pri.item_id = i.id
        LEFT JOIN item_prices ip ON pri.item_id = ip.item_id
        WHERE pri.recipe_id = ?
    }, { Slice => {} }, $id);

    # Get outputs
    $recipe->{outputs} = $self->dbh->selectall_arrayref(q{
        SELECT pro.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM cookbook_recipe_outputs pro
        JOIN items i ON pro.item_id = i.id
        LEFT JOIN item_prices ip ON pro.item_id = ip.item_id
        WHERE pro.recipe_id = ?
    }, { Slice => {} }, $id);

    return $recipe;
}

sub get_cookbook_recipes {
    my ($self, $cookbook_id) = @_;
    my $sql = q{
        SELECT pr.*,
               COALESCE(profit_data.input_cost, 0) as input_cost,
               COALESCE(profit_data.output_revenue, 0) as output_revenue,
               COALESCE(profit_data.total_tax, 0) as total_tax,
               COALESCE(profit_data.output_revenue_after_tax, 0) as output_revenue_after_tax,
               COALESCE(profit_data.profit, 0) as profit,
               COALESCE(profit_data.roi_percent, 0) as roi_percent
        FROM cookbook_recipes pr
        LEFT JOIN cookbook_recipe_profits profit_data ON pr.id = profit_data.id
        WHERE pr.cookbook_id = ?
        ORDER BY pr.sort_order, pr.id
    };

    my $recipes = $self->dbh->selectall_arrayref($sql, { Slice => {} }, $cookbook_id);

    # Fetch inputs and outputs for each recipe
    for my $recipe (@$recipes) {
        $recipe->{inputs} = $self->dbh->selectall_arrayref(q{
            SELECT pri.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM cookbook_recipe_inputs pri
            JOIN items i ON pri.item_id = i.id
            LEFT JOIN item_prices ip ON pri.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON pri.item_id = iv.item_id
            WHERE pri.recipe_id = ?
        }, { Slice => {} }, $recipe->{id});

        $recipe->{outputs} = $self->dbh->selectall_arrayref(q{
            SELECT pro.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM cookbook_recipe_outputs pro
            JOIN items i ON pro.item_id = i.id
            LEFT JOIN item_prices ip ON pro.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON pro.item_id = iv.item_id
            WHERE pro.recipe_id = ?
        }, { Slice => {} }, $recipe->{id});
    }

    return $recipes;
}

sub reorder_cookbook_recipes {
    my ($self, $ids) = @_;
    my $order = 0;
    for my $id (@$ids) {
        $self->dbh->do('UPDATE cookbook_recipes SET sort_order = ? WHERE id = ?',
            undef, $order++, $id);
    }
}

# Cookbook recipe input/output management
sub add_cookbook_recipe_input {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    $self->dbh->do(q{
        INSERT INTO cookbook_recipe_inputs (recipe_id, item_id, quantity)
        VALUES (?, ?, ?)
    }, undef, $recipe_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'cookbook_recipe_inputs', 'id');
}

sub add_cookbook_recipe_output {
    my ($self, $recipe_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    $self->dbh->do(q{
        INSERT INTO cookbook_recipe_outputs (recipe_id, item_id, quantity)
        VALUES (?, ?, ?)
    }, undef, $recipe_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'cookbook_recipe_outputs', 'id');
}

sub remove_cookbook_recipe_input {
    my ($self, $input_id) = @_;
    $self->dbh->do('DELETE FROM cookbook_recipe_inputs WHERE id = ?', undef, $input_id);
}

sub remove_cookbook_recipe_output {
    my ($self, $output_id) = @_;
    $self->dbh->do('DELETE FROM cookbook_recipe_outputs WHERE id = ?', undef, $output_id);
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
