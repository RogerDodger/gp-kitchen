#!/usr/bin/env perl
# Fetches latest GE prices from OSRS Wiki API and updates local database.
# Run via systemd timer, cron, or with --daemon for continuous updates.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use Getopt::Long;
use YAML qw(LoadFile);
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

my $config_file = $ENV{FLIPPA_CONFIG} // "$FindBin::Bin/config.yml";
die "Config not found: $config_file\n" unless -f $config_file;

my $config = LoadFile($config_file);

my $schema = OSRS::GE::Schema->new(
    db_path => "$FindBin::Bin/" . $config->{database}{path}
);
$schema->init_schema("$FindBin::Bin/schema.sql");

my $updater = OSRS::GE::PriceUpdater->new(
    schema     => $schema,
    user_agent => $config->{user_agent},
    log        => \&log_msg,
);

if ($latest_only) {
    # Quick update only (prices)
    log_msg("Running quick update (prices only)...");
    eval { $updater->update_latest };
    if ($@) {
        log_msg("ERROR: $@");
        exit 1;
    }
    log_msg("Quick update complete.");
} elsif ($daemon) {
    log_msg("Starting daemon mode (prices every 30s, volumes every 5min, full update daily)");
    $SIG{INT} = $SIG{TERM} = sub { log_msg("Shutting down..."); exit 0; };

    my $last_full_update = 0;
    my $last_volume_update = 0;

    while (1) {
        my $now = time();

        # Full update every 24 hours (for new item mappings)
        if ($now - $last_full_update >= 86400) {
            log_msg("Running full update (mappings + prices + volumes)...");
            eval { $updater->update_all };
            log_msg("ERROR: $@") if $@;
            $last_full_update = $now;
            $last_volume_update = $now;
        } else {
            # Volume update every 5 minutes
            if ($now - $last_volume_update >= 300) {
                log_msg("Updating volumes...");
                eval { $updater->update_conversion_volumes };
                log_msg("ERROR: $@") if $@;
                $last_volume_update = $now;
            }

            # Price update every 30 seconds
            log_msg("Updating prices...");
            eval { $updater->update_latest };
            log_msg("ERROR: $@") if $@;
        }

        sleep 30;
    }
} else {
    # Single run mode
    eval { $updater->update_all };
    if ($@) {
        log_msg("ERROR: $@");
        exit 1;
    }

    my $stats = $schema->get_price_stats;
    log_msg("Stats: $stats->{total_items} items, $stats->{items_with_high} with high price, $stats->{items_with_low} with low price");
}
