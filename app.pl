#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use Mojolicious::Lite -signatures;
use YAML qw(LoadFile);
use OSRS::GE::Schema;
use OSRS::GE::PriceUpdater;

# Load configuration
my $config_file = $ENV{FLIPPA_CONFIG} // "$FindBin::Bin/config.yml";
my $config = LoadFile($config_file);

# Initialize database
my $schema = OSRS::GE::Schema->new(
    db_path => "$FindBin::Bin/" . $config->{database}{path}
);
$schema->init_schema("$FindBin::Bin/schema.sql");

# Store in app
app->helper(schema => sub { $schema });
app->helper(config => sub { $config });

# Session secret
app->secrets([$config->{session}{secret} // 'change_me_in_production']);

# Static files and templates
app->static->paths->[0] = "$FindBin::Bin/public";
app->renderer->paths->[0] = "$FindBin::Bin/templates";

# Helper to check authentication
app->helper(is_authenticated => sub ($c) {
    return $c->session('authenticated');
});

# Helper to format numbers with commas
app->helper(format_gp => sub ($c, $num) {
    return 'N/A' unless defined $num;
    $num = int($num);
    my $sign = $num < 0 ? '-' : '';
    $num = abs($num);

    # Add commas
    $num =~ s/(\d)(?=(\d{3})+(?!\d))/$1,/g;
    return $sign . $num;
});

# Helper to format numbers compactly (1.2M, 500K, etc.)
app->helper(format_gp_compact => sub ($c, $num) {
    return 'N/A' unless defined $num;
    my $sign = $num < 0 ? '-' : '';
    $num = abs($num);

    if ($num >= 1_000_000_000) {
        return sprintf("%s%.2fB", $sign, $num / 1_000_000_000);
    } elsif ($num >= 1_000_000) {
        return sprintf("%s%.2fM", $sign, $num / 1_000_000);
    } elsif ($num >= 1_000) {
        return sprintf("%s%.1fK", $sign, $num / 1_000);
    }
    return $sign . $num;
});

# Helper to format time as relative short format (e.g., "50s ago", "5m ago", "2h ago", "3d ago")
app->helper(time_ago => sub ($c, $timestamp) {
    return 'N/A' unless defined $timestamp;
    my $diff = time() - $timestamp;
    return "${diff}s ago" if $diff < 60;
    my $mins = int($diff / 60);
    return "${mins}m ago" if $mins < 60;
    my $hours = int($mins / 60);
    return "${hours}h ago" if $hours < 24;
    my $days = int($hours / 24);
    return "${days}d ago";
});

# Helper to format volume numbers compactly
app->helper(format_vol => sub ($c, $num) {
    return '0' unless defined $num;
    if ($num >= 1_000_000) {
        return sprintf("%.1fM", $num / 1_000_000);
    } elsif ($num >= 1_000) {
        return sprintf("%.1fK", $num / 1_000);
    }
    return $num;
});

# Helper to calculate GE tax (2% capped at 5M per item, as of May 2025)
app->helper(calculate_tax => sub ($c, $price, $quantity) {
    $quantity //= 1;
    my $total = ($price // 0) * $quantity;
    my $tax = int($total * 0.02);  # 2% tax
    my $max_tax = 5_000_000 * $quantity;
    return $tax > $max_tax ? $max_tax : $tax;
});

# Helper to compute rowspans for items when counts differ
app->helper(compute_rowspans => sub ($c, $count, $max_rows) {
    return [(1) x $count] if $count == $max_rows;
    my $base = int($max_rows / $count);
    my $rem = $max_rows % $count;
    return [map { $base + ($_ < $rem ? 1 : 0) } (0 .. $count - 1)];
});

# Helper to compute pair profits for both modes
app->helper(compute_conversion_modes => sub ($c, $conv) {
    my %result = (instant => {}, patient => {});

    # Instant mode: buy at high (ask), sell at low (bid)
    # Patient mode: buy at low (bid), sell at high (ask)

    for my $mode (qw(instant patient)) {
        my $input_cost = 0;
        my $output_revenue = 0;
        my $total_tax = 0;

        for my $input (@{$conv->{inputs}}) {
            my $price = $mode eq 'instant'
                ? ($input->{high_price} // 0)
                : ($input->{low_price} // 0);
            $input_cost += $price * ($input->{quantity} // 1);
        }

        for my $output (@{$conv->{outputs}}) {
            my $qty = $output->{quantity} // 1;
            my $price = $mode eq 'instant'
                ? ($output->{low_price} // 0)
                : ($output->{high_price} // 0);
            my $revenue = $price * $qty;
            $output_revenue += $revenue;

            # Tax (no tax on coins, item ID 995)
            unless ($output->{item_id} == 995) {
                $total_tax += $c->calculate_tax($price, $qty);
            }
        }

        my $profit = $output_revenue - $total_tax - $input_cost;
        my $roi = $input_cost > 0 ? sprintf("%.2f", ($profit / $input_cost) * 100) : 0;

        $result{$mode} = {
            input_cost => $input_cost,
            output_revenue => $output_revenue,
            total_tax => $total_tax,
            profit => $profit,
            roi_percent => $roi,
        };
    }

    return \%result;
});

# =====================================
# Routes
# =====================================

# Dashboard (main page)
get '/' => sub ($c) {
    my $conversions = $schema->get_all_conversions(1);  # Active only
    my $stats = $schema->get_price_stats;
    $c->stash(conversions => $conversions, stats => $stats);
    $c->render(template => 'dashboard/index');
};

# API: Search items
get '/api/items/search' => sub ($c) {
    my $q = $c->param('q') // '';
    return $c->render(json => []) if length($q) < 2;

    my $items = $schema->search_items($q, 20);
    $c->render(json => $items);
};

# API: Get item details
get '/api/items/:id' => sub ($c) {
    my $id = $c->param('id');
    my $item = $schema->get_item($id);
    return $c->render(json => { error => 'Item not found' }, status => 404) unless $item;
    $c->render(json => $item);
};

# API: Get all conversions (for dashboard refresh)
get '/api/conversions' => sub ($c) {
    my $active_only = $c->param('active') // 1;
    my $conversions = $schema->get_all_conversions($active_only);
    $c->render(json => $conversions);
};

# API: Get price history from OSRS Wiki
get '/api/items/:id/history' => sub ($c) {
    my $id = $c->param('id');
    my $timestep = $c->param('timestep') // '6h';

    # Validate timestep
    unless ($timestep =~ /^(5m|1h|6h|24h)$/) {
        return $c->render(json => { error => 'Invalid timestep' }, status => 400);
    }

    # Fetch from OSRS Wiki API
    require LWP::UserAgent;
    require JSON::PP;

    my $ua = LWP::UserAgent->new(
        timeout => 15,
        agent   => $config->{user_agent} // 'OSRS-GE-Tracker/1.0',
    );

    my $url = "https://prices.runescape.wiki/api/v1/osrs/timeseries?id=$id&timestep=$timestep";
    my $response = $ua->get($url);

    unless ($response->is_success) {
        return $c->render(json => { error => 'Failed to fetch history' }, status => 502);
    }

    my $data = eval { JSON::PP::decode_json($response->decoded_content) };
    if ($@) {
        return $c->render(json => { error => 'Invalid response' }, status => 502);
    }

    $c->render(json => $data);
};

# Item detail page
get '/item/:id' => sub ($c) {
    my $id = $c->param('id');
    my $item = $schema->get_item($id);
    return $c->render(text => 'Item not found', status => 404) unless $item;

    $c->stash(item => $item);
    $c->render(template => 'item/show');
};

# =====================================
# Authentication
# =====================================

get '/login' => sub ($c) {
    $c->render(template => 'auth/login');
};

post '/login' => sub ($c) {
    my $password = $c->param('password') // '';

    if ($password eq $config->{admin_password}) {
        $c->session(authenticated => 1);
        $c->session(expiration => 86400);
        return $c->redirect_to('/admin');
    }

    $c->flash(error => 'Invalid password');
    $c->redirect_to('/login');
};

get '/logout' => sub ($c) {
    $c->session(expires => 1);
    $c->redirect_to('/');
};

# =====================================
# Admin routes (authenticated)
# =====================================

group {
    under '/admin' => sub ($c) {
        return 1 if $c->is_authenticated;
        $c->redirect_to('/login');
        return 0;
    };

    # Admin dashboard
    get '/' => sub ($c) {
        my $conversions = $schema->get_all_conversions(0);  # All
        my $stats = $schema->get_price_stats;
        $c->stash(conversions => $conversions, stats => $stats);
        $c->render(template => 'admin/index');
    };

    # Create new conversion pair
    post '/conversions' => sub ($c) {
        my $id = $schema->create_conversion_pair();
        $c->redirect_to("/admin/conversions/$id/edit");
    };

    # Edit conversion pair form
    get '/conversions/:id/edit' => sub ($c) {
        my $id = $c->param('id');
        my $conv = $schema->get_conversion_pair($id);
        return $c->render(text => 'Not found', status => 404) unless $conv;

        $c->stash(conv => $conv);
        $c->render(template => 'admin/edit_conversion');
    };

    # Toggle conversion active status
    post '/conversions/:id/toggle' => sub ($c) {
        my $id = $c->param('id');
        $schema->toggle_conversion_active($id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/admin');
    };

    # Toggle conversion live status
    post '/conversions/:id/toggle-live' => sub ($c) {
        my $id = $c->param('id');
        $schema->toggle_conversion_live($id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/admin');
    };

    # Reorder conversions
    post '/conversions/reorder' => sub ($c) {
        my $order = $c->param('order') // '';
        my $id = $c->param('id');
        my $dir = $c->param('dir');

        my @ids = grep { /^\d+$/ } split /,/, $order;
        if (@ids && $id && $dir =~ /^(up|down)$/) {
            my ($idx) = grep { $ids[$_] == $id } 0..$#ids;
            if (defined $idx) {
                my $swap_idx = $dir eq 'up' ? $idx - 1 : $idx + 1;
                if ($swap_idx >= 0 && $swap_idx <= $#ids) {
                    # Check if both items have same live status
                    my $live_status = $schema->dbh->selectall_hashref(
                        'SELECT id, live FROM conversions WHERE id IN (?, ?)',
                        'id', undef, $ids[$idx], $ids[$swap_idx]
                    );
                    my $same_live = $live_status->{$ids[$idx]}{live} == $live_status->{$ids[$swap_idx]}{live};
                    if ($same_live) {
                        @ids[$idx, $swap_idx] = @ids[$swap_idx, $idx];
                        $schema->reorder_conversions(\@ids);
                    }
                }
            }
        }
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/admin');
    };

    # Delete conversion pair
    post '/conversions/:id/delete' => sub ($c) {
        my $id = $c->param('id');
        $schema->delete_conversion_pair($id);
        $c->flash(success => 'Conversion pair deleted');
        $c->redirect_to('/admin');
    };

    # Update price cache (latest only for speed)
    post '/update-prices' => sub ($c) {
        eval {
            my $updater = OSRS::GE::PriceUpdater->new(
                schema     => $schema,
                user_agent => $config->{user_agent},
            );
            $updater->update_latest;
        };
        if ($@) {
            $c->flash(error => "Price update failed: $@");
        }
        $c->redirect_to($c->req->headers->referrer // '/');
    };

    # Add input to conversion
    post '/conversions/:id/inputs' => sub ($c) {
        my $pair_id = $c->param('id');
        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        if ($item_id) {
            $schema->add_conversion_input($pair_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/admin/conversions/$pair_id/edit");
    };

    # Remove input from conversion
    post '/conversions/:id/inputs/:input_id/delete' => sub ($c) {
        my $pair_id = $c->param('id');
        my $input_id = $c->param('input_id');

        $schema->remove_conversion_input($input_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/admin/conversions/$pair_id/edit");
    };

    # Add output to conversion
    post '/conversions/:id/outputs' => sub ($c) {
        my $pair_id = $c->param('id');
        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        if ($item_id) {
            $schema->add_conversion_output($pair_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/admin/conversions/$pair_id/edit");
    };

    # Remove output from conversion
    post '/conversions/:id/outputs/:output_id/delete' => sub ($c) {
        my $pair_id = $c->param('id');
        my $output_id = $c->param('output_id');

        $schema->remove_conversion_output($output_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/admin/conversions/$pair_id/edit");
    };
};

# Start the app
app->start;

__DATA__

@@ auth/login.html.ep
% layout 'default';
% title 'Login';

<div class="login-container">
    <h1>Admin Login</h1>

    % if (flash 'error') {
        <div class="alert alert-error"><%= flash 'error' %></div>
    % }

    <form method="post" action="/login">
        <div class="form-group">
            <label for="password">Password</label>
            <input type="password" id="password" name="password" required autofocus>
        </div>
        <button type="submit" class="btn btn-primary">Login</button>
    </form>
</div>
