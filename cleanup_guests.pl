#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";

use Getopt::Long;
use YAML::PP;
use OSRS::GE::Schema;

my $days = 30;
my $dry_run = 0;

GetOptions(
    'days=i'  => \$days,
    'dry-run' => \$dry_run,
) or die "Usage: $0 [--days=N] [--dry-run]\n";

# Load configuration
my $config_file = $ENV{GP_KITCHEN_CONFIG} // "$FindBin::Bin/config.yml";
my $config = YAML::PP->new->load_file($config_file);

# Initialize database
my $schema = OSRS::GE::Schema->new(
    db_path        => "$FindBin::Bin/" . $config->{database}{main_path},
    prices_db_path => "$FindBin::Bin/" . $config->{database}{prices_path},
);

my $count = $schema->cleanup_inactive_guests($days, $dry_run);

if ($dry_run) {
    print "Would delete $count inactive guest accounts (inactive > $days days)\n";
} else {
    print "Deleted $count inactive guest accounts (inactive > $days days)\n";
}
