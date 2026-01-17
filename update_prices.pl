#!/usr/bin/env perl
# Fetches latest GE prices from OSRS Wiki API and updates local database.
# Run via systemd timer, cron, or with --daemon for continuous updates.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use Getopt::Long;
use YAML::PP;
use OSRS::GE::Schema;
use OSRS::GE::PriceUpdater;
use POSIX qw(strftime);

my $daemon = 0;
my $latest_only = 0;
GetOptions(
    'daemon|d' => \$daemon,
    'latest|l' => \$latest_only,
) or die "Usage: $0 [--daemon|-d] [--latest|-l]\n";

sub log_msg { print "[", strftime("%Y-%m-%d %H:%M:%S", localtime), "] ", @_, "\n" }

my $config_file = $ENV{GP_KITCHEN_CONFIG} // "$FindBin::Bin/config.yml";
die "Config not found: $config_file\n" unless -f $config_file;

my $config = YAML::PP->new->load_file($config_file);

my $schema = OSRS::GE::Schema->new(
    db_path        => "$FindBin::Bin/" . $config->{database}{main_path},
    prices_db_path => "$FindBin::Bin/" . $config->{database}{prices_path},
);
$schema->init_schema("$FindBin::Bin/schema.sql", "$FindBin::Bin/prices_schema.sql");

my $updater = OSRS::GE::PriceUpdater->new(
    schema     => $schema,
    user_agent => $config->{user_agent},
    log        => \&log_msg,
);

my $update_prices = sub {
    log_msg("Updating prices...");
    eval { $updater->update_latest };
    log_msg("ERROR: $@") if $@;
};

my $update_5m_vol = sub {
    log_msg("Updating 5m volumes...");
    eval { $updater->update_5m_volumes };
    log_msg("ERROR: $@") if $@;
};

my $update_4h_vol = sub {
    log_msg("Updating 4h volumes...");
    eval { $updater->update_4h_volumes };
    log_msg("ERROR: $@") if $@;
};

my $update_daily = sub {
    log_msg("Running daily update (mappings + 24h volumes)...");
    eval { $updater->update_mappings };
    log_msg("ERROR: $@") if $@;
    eval { $updater->update_24h_volumes };
    log_msg("ERROR: $@") if $@;
};

if ($latest_only) {
    $update_prices->();
} elsif ($daemon) {
    log_msg("Starting daemon mode (prices every 10s, 5m vol every 5min, 4h vol every 20min, mappings+24h vol every 4h)");

    use Mojo::IOLoop;

    # Run all updates immediately on start
    $update_daily->();
    $update_4h_vol->();
    $update_5m_vol->();
    $update_prices->();

    # Schedule recurring updates
    Mojo::IOLoop->recurring(5 => $update_prices);
    Mojo::IOLoop->recurring(300 => $update_5m_vol);
    Mojo::IOLoop->recurring(1200 => $update_4h_vol);
    Mojo::IOLoop->recurring(14400 => $update_daily);

    $SIG{INT} = $SIG{TERM} = sub {
        log_msg("Shutting down...");
        Mojo::IOLoop->stop;
    };

    Mojo::IOLoop->start;
} else {
    # Single run mode
    $update_daily->();
    $update_4h_vol->();
    $update_5m_vol->();
    $update_prices->();

    my $stats = $schema->get_price_stats;
    log_msg("Stats: $stats->{total_items} items, $stats->{items_with_high} with high price, $stats->{items_with_low} with low price");
}
