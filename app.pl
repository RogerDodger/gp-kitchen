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
my $config_file = $ENV{GP_KITCHEN_CONFIG} // "$FindBin::Bin/config.yml";
my $config = LoadFile($config_file);

# Initialize database
my $schema = OSRS::GE::Schema->new(
    db_path => "$FindBin::Bin/" . $config->{database}{path}
);
$schema->init_schema("$FindBin::Bin/schema.sql");

# Run migration if needed
$schema->migrate($config->{admin_password});

# Store in app
app->helper(schema => sub { $schema });
app->helper(config => sub { $config });

# Session configuration (30 day expiry)
app->secrets([$config->{session}{secret} // 'change_me_in_production']);
app->sessions->default_expiration(30 * 24 * 60 * 60);  # 30 days

# Static files and templates
app->static->paths->[0] = "$FindBin::Bin/public";
app->renderer->paths->[0] = "$FindBin::Bin/templates";

# =====================================
# User helpers
# =====================================

app->helper(current_user => sub ($c) {
    my $user_id = $c->session('user_id');
    return unless $user_id;
    return $schema->get_user($user_id);
});

app->helper(is_admin => sub ($c) {
    my $user = $c->current_user;
    return $user && $user->{is_admin};
});

app->helper(is_guest => sub ($c) {
    my $user = $c->current_user;
    return $user && $user->{is_guest};
});

app->helper(is_authenticated => sub ($c) {
    return !!$c->session('user_id');
});

app->helper(is_dev_mode => sub ($c) {
    return $config->{dev_mode} ? 1 : 0;
});

# =====================================
# CSRF helpers
# =====================================

app->helper(csrf_token => sub ($c) {
    my $token = $c->session('csrf_token');
    unless ($token) {
        $token = _random_string(32);
        $c->session(csrf_token => $token);
    }
    return $token;
});

app->helper(csrf_check => sub ($c) {
    my $expected = $c->session('csrf_token');
    my $provided = $c->param('csrf_token');
    return $expected && $provided && $expected eq $provided;
});

sub _random_string {
    my ($len) = @_;
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $str = '';
    $str .= $chars[rand @chars] for 1..$len;
    return $str;
}

# =====================================
# Formatting helpers
# =====================================

app->helper(format_gp => sub ($c, $num) {
    return 'N/A' unless defined $num;
    $num = int($num);
    my $sign = $num < 0 ? '-' : '';
    $num = abs($num);

    # Add commas
    $num =~ s/(\d)(?=(\d{3})+(?!\d))/$1,/g;
    return $sign . $num;
});

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

app->helper(format_vol => sub ($c, $num) {
    return '0' unless defined $num;
    if ($num >= 1_000_000) {
        return sprintf("%.1fM", $num / 1_000_000);
    } elsif ($num >= 1_000) {
        return sprintf("%.1fK", $num / 1_000);
    }
    return $num;
});

app->helper(calculate_tax => sub ($c, $price, $quantity) {
    $quantity //= 1;
    my $total = ($price // 0) * $quantity;
    my $tax = int($total * 0.02);  # 2% tax
    my $max_tax = 5_000_000 * $quantity;
    return $tax > $max_tax ? $max_tax : $tax;
});

app->helper(compute_rowspans => sub ($c, $count, $max_rows) {
    return [(1) x $count] if $count == $max_rows;
    my $base = int($max_rows / $count);
    my $rem = $max_rows % $count;
    return [map { $base + ($_ < $rem ? 1 : 0) } (0 .. $count - 1)];
});

app->helper(compute_recipe_modes => sub ($c, $recipe) {
    my %result = (instant => {}, patient => {});

    for my $mode (qw(instant patient)) {
        my $input_cost = 0;
        my $output_revenue = 0;
        my $total_tax = 0;

        for my $input (@{$recipe->{inputs}}) {
            my $price = $mode eq 'instant'
                ? ($input->{high_price} // 0)
                : ($input->{low_price} // 0);
            $input_cost += $price * ($input->{quantity} // 1);
        }

        for my $output (@{$recipe->{outputs}}) {
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
    my $user = $c->current_user;
    my $recipes = [];
    if ($user) {
        $recipes = $schema->get_all_recipes($user->{id}, 1);  # Active only
    }
    my $stats = $schema->get_price_stats;
    $c->stash(recipes => $recipes, stats => $stats);
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

# API: Get all recipes (for dashboard refresh)
get '/api/recipes' => sub ($c) {
    my $user = $c->current_user;
    return $c->render(json => []) unless $user;

    my $active_only = $c->param('active') // 1;
    my $recipes = $schema->get_all_recipes($user->{id}, $active_only);
    $c->render(json => $recipes);
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
        agent   => $config->{user_agent} // 'GP-Kitchen/1.0',
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
    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';

    my $user = $schema->authenticate_user($username, $password);
    if ($user) {
        $c->session(user_id => $user->{id});
        $schema->update_user_last_active($user->{id});
        return $c->redirect_to('/cook');
    }

    $c->flash(error => 'Invalid username or password');
    $c->redirect_to('/login');
};

get '/logout' => sub ($c) {
    $c->session(expires => 1);
    $c->redirect_to('/');
};

get '/register' => sub ($c) {
    $c->render(template => 'auth/register');
};

post '/register' => sub ($c) {
    return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';
    my $confirm = $c->param('confirm_password') // '';

    # Validation
    if (length($username) < 3 || length($username) > 20) {
        $c->flash(error => 'Username must be 3-20 characters');
        return $c->redirect_to('/register');
    }
    unless ($username =~ /^[a-zA-Z0-9_]+$/) {
        $c->flash(error => 'Username can only contain letters, numbers, and underscores');
        return $c->redirect_to('/register');
    }
    if (length($password) < 6) {
        $c->flash(error => 'Password must be at least 6 characters');
        return $c->redirect_to('/register');
    }
    if ($password ne $confirm) {
        $c->flash(error => 'Passwords do not match');
        return $c->redirect_to('/register');
    }

    # Check if upgrading guest
    my $current_user = $c->current_user;
    if ($current_user && $current_user->{is_guest}) {
        my $result = $schema->register_guest($current_user->{id}, $username, $password);
        if ($result->{error}) {
            $c->flash(error => $result->{error});
            return $c->redirect_to('/register');
        }
        $c->flash(success => 'Account saved! You can now log in from any device.');
        return $c->redirect_to('/cook');
    }

    # New registration
    my $existing = $schema->get_user_by_username($username);
    if ($existing) {
        $c->flash(error => 'Username already taken');
        return $c->redirect_to('/register');
    }

    my $user_id = $schema->create_user(
        username => $username,
        password => $password,
    );
    $c->session(user_id => $user_id);
    $c->flash(success => 'Account created!');
    $c->redirect_to('/cook');
};

# =====================================
# Recipe routes (authenticated)
# =====================================

group {
    under '/cook' => sub ($c) {
        # Ensure user exists (create guest if needed for modifying actions)
        my $user = $c->current_user;
        if (!$user && $c->req->method eq 'POST') {
            # Create guest account on first modifying action
            my $user_id = $schema->create_guest_user;
            $c->session(user_id => $user_id);
            $user = $schema->get_user($user_id);
        }
        return 1 if $user || $c->req->method eq 'GET';
        $c->redirect_to('/login');
        return 0;
    };

    # Recipe management page
    get '/' => sub ($c) {
        my $user = $c->current_user;
        return $c->redirect_to('/login') unless $user;

        my $recipes = $schema->get_all_recipes($user->{id}, 0);  # All
        my $stats = $schema->get_price_stats;
        $c->stash(recipes => $recipes, stats => $stats);
        $c->render(template => 'cook/index');
    };

    # Edit recipe form (or blank for new)
    get '/recipe/:id' => sub ($c) {
        my $user = $c->current_user;
        return $c->redirect_to('/login') unless $user;

        my $id = $c->param('id');

        # Handle 'blank' as a special case for new recipe
        if ($id eq 'blank') {
            my $recipe = {
                id => 'blank',
                inputs => [],
                outputs => [],
                active => 1,
                live => 0,
            };
            $c->stash(recipe => $recipe);
            return $c->render(template => 'cook/recipe');
        }

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $id);

        my $recipe = $schema->get_recipe($id);
        return $c->render(text => 'Not found', status => 404) unless $recipe;

        $c->stash(recipe => $recipe);
        $c->render(template => 'cook/recipe');
    };

    # Toggle recipe active status
    post '/recipe/:id/toggle' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $id = $c->param('id');
        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $id);

        $schema->toggle_recipe_active($id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/cook');
    };

    # Toggle recipe live status
    post '/recipe/:id/toggle-live' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $id = $c->param('id');
        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $id);

        $schema->toggle_recipe_live($id, $user->{id});
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/cook');
    };

    # Reorder recipes
    post '/reorder' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $order = $c->param('order') // '';
        my $id = $c->param('id');
        my $dir = $c->param('dir');

        my @ids = grep { /^\d+$/ } split /,/, $order;
        if (@ids && $id && $dir =~ /^(up|down)$/) {
            # Verify all recipes belong to user
            for my $recipe_id (@ids) {
                return $c->render(text => 'Not authorized', status => 403)
                    unless $schema->user_owns_recipe($user->{id}, $recipe_id);
            }

            my ($idx) = grep { $ids[$_] == $id } 0..$#ids;
            if (defined $idx) {
                my $swap_idx = $dir eq 'up' ? $idx - 1 : $idx + 1;
                if ($swap_idx >= 0 && $swap_idx <= $#ids) {
                    # Check if both items have same live status
                    my $dbh = $schema->dbh;
                    my $live_status = $dbh->selectall_hashref(
                        'SELECT id, live FROM recipes WHERE id IN (?, ?)',
                        'id', undef, $ids[$idx], $ids[$swap_idx]
                    );
                    my $same_live = $live_status->{$ids[$idx]}{live} == $live_status->{$ids[$swap_idx]}{live};
                    if ($same_live) {
                        @ids[$idx, $swap_idx] = @ids[$swap_idx, $idx];
                        $schema->reorder_recipes(\@ids);
                    }
                }
            }
        }
        $c->flash(restore_scroll => 1);
        $c->redirect_to('/cook');
    };

    # Delete recipe
    post '/recipe/:id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $id = $c->param('id');
        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $id);

        $schema->delete_recipe($id);
        $c->flash(success => 'Recipe deleted');
        $c->redirect_to('/cook');
    };

    # Add input to recipe
    post '/recipe/:id/inputs' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $recipe_id = $c->param('id');
        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        # Create recipe on first input if blank
        if ($recipe_id eq 'blank') {
            return $c->redirect_to('/cook/recipe/blank') unless $item_id;
            $recipe_id = $schema->create_recipe($user->{id});
            $schema->add_recipe_input($recipe_id, $item_id, $quantity);
            $c->flash(restore_scroll => 1);
            return $c->redirect_to("/cook/recipe/$recipe_id");
        }

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $recipe_id);

        if ($item_id) {
            $schema->add_recipe_input($recipe_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cook/recipe/$recipe_id");
    };

    # Remove input from recipe
    post '/recipe/:id/inputs/:input_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $recipe_id = $c->param('id');
        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $recipe_id);

        my $input_id = $c->param('input_id');
        $schema->remove_recipe_input($input_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cook/recipe/$recipe_id");
    };

    # Add output to recipe
    post '/recipe/:id/outputs' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $recipe_id = $c->param('id');
        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        # Create recipe on first output if blank
        if ($recipe_id eq 'blank') {
            return $c->redirect_to('/cook/recipe/blank') unless $item_id;
            $recipe_id = $schema->create_recipe($user->{id});
            $schema->add_recipe_output($recipe_id, $item_id, $quantity);
            $c->flash(restore_scroll => 1);
            return $c->redirect_to("/cook/recipe/$recipe_id");
        }

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $recipe_id);

        if ($item_id) {
            $schema->add_recipe_output($recipe_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cook/recipe/$recipe_id");
    };

    # Remove output from recipe
    post '/recipe/:id/outputs/:output_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $user = $c->current_user;
        my $recipe_id = $c->param('id');
        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->user_owns_recipe($user->{id}, $recipe_id);

        my $output_id = $c->param('output_id');
        $schema->remove_recipe_output($output_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cook/recipe/$recipe_id");
    };
};

# =====================================
# Cookbook routes (public browsing)
# =====================================

# Browse all cookbooks
get '/cookbooks' => sub ($c) {
    my $cookbooks = $schema->get_all_cookbooks;

    # Get all recipes for each cookbook
    for my $cookbook (@$cookbooks) {
        my $recipes = $schema->get_cookbook_recipes($cookbook->{id});
        $cookbook->{recipes} = $recipes;
        $cookbook->{total_recipes} = scalar @$recipes;
    }

    my $stats = $schema->get_price_stats;
    $c->stash(cookbooks => $cookbooks, stats => $stats);
    $c->render(template => 'cookbooks/index');
};

# Import selection page
get '/cookbooks/:id/import' => sub ($c) {
    my $id = $c->param('id');
    my $cookbook = $schema->get_cookbook($id);
    return $c->render(text => 'Cookbook not found', status => 404) unless $cookbook;

    my $recipes = $schema->get_cookbook_recipes($id);
    $c->stash(cookbook => $cookbook, recipes => $recipes);
    $c->render(template => 'cookbooks/import');
};

# Process import
post '/cookbooks/:id/import' => sub ($c) {
    return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

    my $cookbook_id = $c->param('id');
    my $cookbook = $schema->get_cookbook($cookbook_id);
    return $c->render(text => 'Cookbook not found', status => 404) unless $cookbook;

    # Ensure user exists (create guest if needed)
    my $user = $c->current_user;
    unless ($user) {
        my $user_id = $schema->create_guest_user;
        $c->session(user_id => $user_id);
        $user = $schema->get_user($user_id);
    }

    # Get selected recipe IDs (every_param for multiple checkboxes)
    my @recipe_ids = @{ $c->every_param('recipe_ids') };
    @recipe_ids = grep { /^\d+$/ } @recipe_ids;

    if (@recipe_ids) {
        eval {
            $schema->import_cookbook($cookbook_id, $user->{id}, \@recipe_ids);
        };
        if ($@) {
            $c->flash(error => "Import failed: $@");
            return $c->redirect_to("/cookbooks/$cookbook_id/import");
        }
        my $count = @recipe_ids;
        $c->flash(success => "Imported $count recipe(s) from " . $cookbook->{name});
    }

    $c->redirect_to('/cook');
};

# =====================================
# Cookbook admin routes (admin only)
# =====================================

group {
    under '/cookbooks' => sub ($c) {
        # Only check admin for POST requests and /new route
        return 1 unless $c->req->method eq 'POST' || $c->req->url->path =~ m{/(new|edit|\d+/recipes)};
        return 1 if $c->is_admin;
        $c->render(text => 'Admin access required', status => 403);
        return 0;
    };

    # New cookbook form
    get '/new' => sub ($c) {
        $c->render(template => 'cookbooks/new');
    };

    # Create cookbook
    post '/new' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $name = $c->param('name') // '';
        my $description = $c->param('description') // '';

        if (length($name) < 1) {
            $c->flash(error => 'Name is required');
            return $c->redirect_to('/cookbooks/new');
        }

        my $user = $c->current_user;
        my $id = $schema->create_cookbook($name, $description, $user->{id});
        $c->redirect_to("/cookbooks/$id/recipes");
    };

    # Edit cookbook recipes
    get '/:cookbook_id/recipes' => sub ($c) {
        my $cookbook_id = $c->param('cookbook_id');
        my $cookbook = $schema->get_cookbook($cookbook_id);
        return $c->render(text => 'Cookbook not found', status => 404) unless $cookbook;

        my $recipes = $schema->get_cookbook_recipes($cookbook_id);
        my $stats = $schema->get_price_stats;
        $c->stash(cookbook => $cookbook, recipes => $recipes, stats => $stats);
        $c->render(template => 'cookbooks/recipes');
    };

    # Update cookbook metadata
    post '/:cookbook_id/edit' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $name = $c->param('name') // '';
        my $description = $c->param('description') // '';

        $schema->update_cookbook($cookbook_id, $name, $description);
        $c->flash(success => 'Cookbook updated');
        $c->redirect_to("/cookbooks/$cookbook_id/recipes");
    };

    # Delete cookbook
    post '/:cookbook_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        $schema->delete_cookbook($cookbook_id);
        $c->flash(success => 'Cookbook deleted');
        $c->redirect_to('/cookbooks');
    };

    # Add recipe to cookbook
    post '/:cookbook_id/recipes' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $id = $schema->create_cookbook_recipe($cookbook_id);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes/$id/edit");
    };

    # Edit cookbook recipe
    get '/:cookbook_id/recipes/:recipe_id/edit' => sub ($c) {
        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        my $cookbook = $schema->get_cookbook($cookbook_id);
        return $c->render(text => 'Cookbook not found', status => 404) unless $cookbook;

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        my $recipe = $schema->get_cookbook_recipe($recipe_id);
        return $c->render(text => 'Recipe not found', status => 404) unless $recipe;

        $c->stash(cookbook => $cookbook, recipe => $recipe);
        $c->render(template => 'cookbooks/edit_recipe');
    };

    # Delete cookbook recipe
    post '/:cookbook_id/recipes/:recipe_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        $schema->delete_cookbook_recipe($recipe_id);
        $c->flash(success => 'Recipe deleted');
        $c->redirect_to("/cookbooks/$cookbook_id/recipes");
    };

    # Add input to cookbook recipe
    post '/:cookbook_id/recipes/:recipe_id/inputs' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        if ($item_id) {
            $schema->add_cookbook_recipe_input($recipe_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes/$recipe_id/edit");
    };

    # Remove input from cookbook recipe
    post '/:cookbook_id/recipes/:recipe_id/inputs/:input_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        my $input_id = $c->param('input_id');
        $schema->remove_cookbook_recipe_input($input_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes/$recipe_id/edit");
    };

    # Add output to cookbook recipe
    post '/:cookbook_id/recipes/:recipe_id/outputs' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        my $item_id = $c->param('item_id');
        my $quantity = $c->param('quantity') // 1;

        if ($item_id) {
            $schema->add_cookbook_recipe_output($recipe_id, $item_id, $quantity);
        }

        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes/$recipe_id/edit");
    };

    # Remove output from cookbook recipe
    post '/:cookbook_id/recipes/:recipe_id/outputs/:output_id/delete' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $recipe_id = $c->param('recipe_id');

        return $c->render(text => 'Not authorized', status => 403)
            unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);

        my $output_id = $c->param('output_id');
        $schema->remove_cookbook_recipe_output($output_id);
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes/$recipe_id/edit");
    };

    # Reorder cookbook recipes
    post '/:cookbook_id/recipes/reorder' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $cookbook_id = $c->param('cookbook_id');
        my $order = $c->param('order') // '';
        my $id = $c->param('id');
        my $dir = $c->param('dir');

        my @ids = grep { /^\d+$/ } split /,/, $order;
        if (@ids && $id && $dir =~ /^(up|down)$/) {
            # Verify all recipes belong to cookbook
            for my $recipe_id (@ids) {
                return $c->render(text => 'Not authorized', status => 403)
                    unless $schema->cookbook_owns_recipe($cookbook_id, $recipe_id);
            }

            my ($idx) = grep { $ids[$_] == $id } 0..$#ids;
            if (defined $idx) {
                my $swap_idx = $dir eq 'up' ? $idx - 1 : $idx + 1;
                if ($swap_idx >= 0 && $swap_idx <= $#ids) {
                    @ids[$idx, $swap_idx] = @ids[$swap_idx, $idx];
                    $schema->reorder_cookbook_recipes(\@ids);
                }
            }
        }
        $c->flash(restore_scroll => 1);
        $c->redirect_to("/cookbooks/$cookbook_id/recipes");
    };
};

# =====================================
# Admin routes
# =====================================

group {
    under '/admin' => sub ($c) {
        return 1 if $c->is_admin;
        $c->render(text => 'Admin access required', status => 403);
        return 0;
    };

    # Update price cache (dev mode only)
    post '/update-prices' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;
        return $c->render(text => 'Dev mode only', status => 403) unless $c->is_dev_mode;

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

    # Cleanup inactive guest accounts (30+ days)
    post '/cleanup-guests' => sub ($c) {
        return $c->render(text => 'CSRF check failed', status => 403) unless $c->csrf_check;

        my $deleted = $schema->cleanup_inactive_guests(30);
        $c->flash(success => 'Inactive guest accounts cleaned up');
        $c->redirect_to('/cook');
    };
};

# Start the app
app->start;

__DATA__

@@ auth/login.html.ep
% layout 'default';
% title 'Login';

<div class="login-container">
    <h1>Login</h1>

    % if (flash 'error') {
        <div class="alert alert-error"><%= flash 'error' %></div>
    % }

    <form method="post" action="/login">
        <div class="form-group">
            <label for="username">Username</label>
            <input type="text" id="username" name="username" required autofocus>
        </div>
        <div class="form-group">
            <label for="password">Password</label>
            <input type="password" id="password" name="password" required>
        </div>
        <button type="submit" class="btn btn-primary">Login</button>
    </form>

    <p style="margin-top: 1rem; text-align: center;">
        Don't have an account? <a href="/register">Register</a>
    </p>
</div>

@@ auth/register.html.ep
% layout 'default';
% title 'Register';

<div class="login-container">
    <h1><%= is_guest() ? 'Save Account' : 'Register' %></h1>

    % if (flash 'error') {
        <div class="alert alert-error"><%= flash 'error' %></div>
    % }

    % if (is_guest()) {
        <p class="info-text">Save your dashboard by creating an account. You'll be able to log in from any device.</p>
    % }

    <form method="post" action="/register">
        <input type="hidden" name="csrf_token" value="<%= csrf_token %>">
        <div class="form-group">
            <label for="username">Username</label>
            <input type="text" id="username" name="username" required autofocus
                   pattern="[a-zA-Z0-9_]+" minlength="3" maxlength="20">
            <small>3-20 characters, letters, numbers, and underscores only</small>
        </div>
        <div class="form-group">
            <label for="password">Password</label>
            <input type="password" id="password" name="password" required minlength="6">
            <small>At least 6 characters</small>
        </div>
        <div class="form-group">
            <label for="confirm_password">Confirm Password</label>
            <input type="password" id="confirm_password" name="confirm_password" required>
        </div>
        <button type="submit" class="btn btn-primary"><%= is_guest() ? 'Save Account' : 'Register' %></button>
    </form>

    % unless (is_guest()) {
        <p style="margin-top: 1rem; text-align: center;">
            Already have an account? <a href="/login">Login</a>
        </p>
    % }
</div>
