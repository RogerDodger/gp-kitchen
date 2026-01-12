#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use OSRS::GE::Schema;
use YAML qw(LoadFile);

my $config = LoadFile("$FindBin::Bin/config.yml");

my $schema = OSRS::GE::Schema->new(
    db_path => "$FindBin::Bin/" . $config->{database}{path}
);
$schema->connect;

# Check if admin exists
my $existing = $schema->get_user_by_username('admin');
if ($existing) {
    print "Admin user already exists (id: $existing->{id})\n";
    exit 0;
}

# Create admin
my $id = $schema->create_user(
    username => 'admin',
    password => $config->{admin_password},
    is_admin => 1,
);

print "Admin user created with id: $id\n";
print "Password: $config->{admin_password}\n";
