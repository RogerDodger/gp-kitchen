package OSRS::GE::Schema;
use strict;
use warnings;
use DBI;
use File::Basename qw(dirname);
use File::Path qw(make_path);

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

# Item methods
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

# Price methods
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

# Conversion pair methods
sub create_conversion_pair {
    my ($self) = @_;
    my ($max_order) = $self->dbh->selectrow_array(
        'SELECT COALESCE(MAX(sort_order), -1) FROM conversions'
    );
    my $sql = q{
        INSERT INTO conversions (sort_order, created_at, updated_at)
        VALUES (?, strftime('%s', 'now'), strftime('%s', 'now'))
    };
    $self->dbh->do($sql, undef, $max_order + 1);
    return $self->dbh->last_insert_id(undef, undef, 'conversions', 'id');
}

sub update_conversion_pair {
    my ($self, $id, $data) = @_;
    my @sets;
    my @values;

    for my $key (qw(active sort_order)) {
        if (exists $data->{$key}) {
            push @sets, "$key = ?";
            push @values, $data->{$key};
        }
    }

    return unless @sets;

    push @sets, "updated_at = strftime('%s', 'now')";
    my $sql = "UPDATE conversions SET " . join(', ', @sets) . " WHERE id = ?";
    $self->dbh->do($sql, undef, @values, $id);
}

sub delete_conversion_pair {
    my ($self, $id) = @_;
    $self->dbh->do('DELETE FROM conversions WHERE id = ?', undef, $id);
}

sub toggle_conversion_active {
    my ($self, $id) = @_;
    $self->dbh->do(q{
        UPDATE conversions SET active = NOT active, updated_at = strftime('%s', 'now')
        WHERE id = ?
    }, undef, $id);
}

sub toggle_conversion_live {
    my ($self, $id) = @_;
    $self->dbh->do(q{
        UPDATE conversions SET live = NOT live, updated_at = strftime('%s', 'now')
        WHERE id = ?
    }, undef, $id);
}

sub reorder_conversions {
    my ($self, $ids) = @_;
    my $order = 0;
    for my $id (@$ids) {
        $self->dbh->do('UPDATE conversions SET sort_order = ? WHERE id = ?',
            undef, $order++, $id);
    }
}

sub get_conversion_pair {
    my ($self, $id) = @_;
    my $sql = 'SELECT * FROM conversions WHERE id = ?';
    my $pair = $self->dbh->selectrow_hashref($sql, undef, $id);
    return unless $pair;

    # Get inputs
    $pair->{inputs} = $self->dbh->selectall_arrayref(q{
        SELECT ci.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM conversion_inputs ci
        JOIN items i ON ci.item_id = i.id
        LEFT JOIN item_prices ip ON ci.item_id = ip.item_id
        WHERE ci.pair_id = ?
    }, { Slice => {} }, $id);

    # Get outputs
    $pair->{outputs} = $self->dbh->selectall_arrayref(q{
        SELECT co.*, i.name, i.icon, ip.high_price, ip.low_price
        FROM conversion_outputs co
        JOIN items i ON co.item_id = i.id
        LEFT JOIN item_prices ip ON co.item_id = ip.item_id
        WHERE co.pair_id = ?
    }, { Slice => {} }, $id);

    return $pair;
}

sub get_all_conversions {
    my ($self, $active_only) = @_;
    my $sql = q{
        SELECT cp.*,
               COALESCE(profit_data.input_cost, 0) as input_cost,
               COALESCE(profit_data.output_revenue, 0) as output_revenue,
               COALESCE(profit_data.total_tax, 0) as total_tax,
               COALESCE(profit_data.output_revenue_after_tax, 0) as output_revenue_after_tax,
               COALESCE(profit_data.profit, 0) as profit,
               COALESCE(profit_data.roi_percent, 0) as roi_percent
        FROM conversions cp
        LEFT JOIN conversion_profits profit_data ON cp.id = profit_data.id
    };
    $sql .= ' WHERE cp.active = 1' if $active_only;
    $sql .= ' ORDER BY cp.live DESC, cp.sort_order, cp.id';

    my $pairs = $self->dbh->selectall_arrayref($sql, { Slice => {} });

    # Fetch inputs and outputs for each pair
    for my $pair (@$pairs) {
        $pair->{inputs} = $self->dbh->selectall_arrayref(q{
            SELECT ci.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM conversion_inputs ci
            JOIN items i ON ci.item_id = i.id
            LEFT JOIN item_prices ip ON ci.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON ci.item_id = iv.item_id
            WHERE ci.pair_id = ?
        }, { Slice => {} }, $pair->{id});

        $pair->{outputs} = $self->dbh->selectall_arrayref(q{
            SELECT co.*, i.name, i.icon, ip.high_price, ip.low_price, ip.high_time, ip.low_time,
                   iv.vol_5m_high, iv.vol_5m_low, iv.vol_4h_high, iv.vol_4h_low,
                   iv.vol_24h_high, iv.vol_24h_low
            FROM conversion_outputs co
            JOIN items i ON co.item_id = i.id
            LEFT JOIN item_prices ip ON co.item_id = ip.item_id
            LEFT JOIN item_volumes iv ON co.item_id = iv.item_id
            WHERE co.pair_id = ?
        }, { Slice => {} }, $pair->{id});
    }

    return $pairs;
}

# Input/Output management
sub add_conversion_input {
    my ($self, $pair_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    my $sql = 'INSERT INTO conversion_inputs (pair_id, item_id, quantity) VALUES (?, ?, ?)';
    $self->dbh->do($sql, undef, $pair_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'conversion_inputs', 'id');
}

sub add_conversion_output {
    my ($self, $pair_id, $item_id, $quantity) = @_;
    $quantity //= 1;
    my $sql = 'INSERT INTO conversion_outputs (pair_id, item_id, quantity) VALUES (?, ?, ?)';
    $self->dbh->do($sql, undef, $pair_id, $item_id, $quantity);
    return $self->dbh->last_insert_id(undef, undef, 'conversion_outputs', 'id');
}

sub remove_conversion_input {
    my ($self, $input_id) = @_;
    $self->dbh->do('DELETE FROM conversion_inputs WHERE id = ?', undef, $input_id);
}

sub remove_conversion_output {
    my ($self, $output_id) = @_;
    $self->dbh->do('DELETE FROM conversion_outputs WHERE id = ?', undef, $output_id);
}

# Stats
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

# Volume methods
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

1;
