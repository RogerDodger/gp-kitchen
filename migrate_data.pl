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
my $dbh = $schema->connect;

# Get admin user
my $admin = $schema->get_user_by_username('admin');
die "Admin user not found!\n" unless $admin;
my $admin_id = $admin->{id};

print "Migrating data for admin user (id: $admin_id)\n\n";

# Check if already migrated
my ($recipe_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM recipes WHERE user_id = ?', undef, $admin_id);
if ($recipe_count > 0) {
    print "Admin already has $recipe_count recipes. Skipping recipe migration.\n";
} else {
    # Migrate conversions to recipes
    print "Migrating conversions to recipes...\n";

    my $conversions = $dbh->selectall_arrayref(
        'SELECT * FROM conversions ORDER BY sort_order',
        { Slice => {} }
    );

    for my $conv (@$conversions) {
        # Create recipe
        $dbh->do(q{
            INSERT INTO recipes (user_id, active, live, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        }, undef, $admin_id, $conv->{active}, $conv->{live}, $conv->{sort_order},
           $conv->{created_at}, $conv->{updated_at});

        my $recipe_id = $dbh->last_insert_id(undef, undef, 'recipes', 'id');

        # Copy inputs
        my $inputs = $dbh->selectall_arrayref(
            'SELECT * FROM conversion_inputs WHERE pair_id = ?',
            { Slice => {} }, $conv->{id}
        );
        for my $input (@$inputs) {
            $dbh->do(q{
                INSERT INTO recipe_inputs (recipe_id, item_id, quantity)
                VALUES (?, ?, ?)
            }, undef, $recipe_id, $input->{item_id}, $input->{quantity});
        }

        # Copy outputs
        my $outputs = $dbh->selectall_arrayref(
            'SELECT * FROM conversion_outputs WHERE pair_id = ?',
            { Slice => {} }, $conv->{id}
        );
        for my $output (@$outputs) {
            $dbh->do(q{
                INSERT INTO recipe_outputs (recipe_id, item_id, quantity)
                VALUES (?, ?, ?)
            }, undef, $recipe_id, $output->{item_id}, $output->{quantity});
        }

        print "  Migrated conversion $conv->{id} -> recipe $recipe_id\n";
    }

    print "Migrated " . scalar(@$conversions) . " recipes.\n\n";
}

# Define cookbook categories based on output item names
my %cookbook_categories = (
    'Potion Decanting' => [
        'Divine ranging potion(4)',
        'Ranging potion(4)',
        'Super combat potion(4)',
        'Divine super combat potion(4)',
        'Stamina potion(4)',
        'Prayer potion(4)',
    ],
    'Armour Sets' => [
        'Eclipse moon armour set',
        'Virtus armour set',
        'Masori armour set (f)',
        'Justiciar armour set',
    ],
    'Tree Saplings' => [
        'Yew sapling',
        'Magic sapling',
        'Palm sapling',
        'Calquat sapling',
        'Papaya sapling',
        'Dragonfruit sapling',
    ],
);

# Build reverse lookup: output name -> category
my %output_to_category;
for my $cat (keys %cookbook_categories) {
    for my $output (@{$cookbook_categories{$cat}}) {
        $output_to_category{$output} = $cat;
    }
}

# Check if cookbooks already exist
my ($cookbook_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM cookbooks');
if ($cookbook_count > 0) {
    print "Cookbooks already exist ($cookbook_count). Skipping cookbook creation.\n";
    exit 0;
}

print "Creating cookbooks...\n\n";

# Get all recipes with their output names
my $recipes = $dbh->selectall_arrayref(q{
    SELECT r.id, r.sort_order, GROUP_CONCAT(i.name) as output_names
    FROM recipes r
    JOIN recipe_outputs ro ON r.id = ro.recipe_id
    JOIN items i ON ro.item_id = i.id
    WHERE r.user_id = ?
    GROUP BY r.id
    ORDER BY r.sort_order
}, { Slice => {} }, $admin_id);

# Categorize recipes
my %categorized;
my @misc;

for my $recipe (@$recipes) {
    my $output = $recipe->{output_names};
    my $category = $output_to_category{$output};

    if ($category) {
        push @{$categorized{$category}}, $recipe;
    } else {
        push @misc, $recipe;
    }
}

# Create cookbooks in order
my @cookbook_order = ('Potion Decanting', 'Armour Sets', 'Tree Saplings');

for my $cookbook_name (@cookbook_order) {
    my $recipes_in_cookbook = $categorized{$cookbook_name} // [];
    next unless @$recipes_in_cookbook;

    create_cookbook($cookbook_name, $recipes_in_cookbook);
}

# Create Misc cookbook for remaining recipes
if (@misc) {
    create_cookbook('Misc', \@misc);
}

print "\nDone!\n";

sub create_cookbook {
    my ($name, $recipe_list) = @_;

    print "Creating cookbook: $name (" . scalar(@$recipe_list) . " recipes)\n";

    # Create cookbook
    $dbh->do(q{
        INSERT INTO cookbooks (name, description, created_by, created_at, updated_at)
        VALUES (?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
    }, undef, $name, '', $admin_id);

    my $cookbook_id = $dbh->last_insert_id(undef, undef, 'cookbooks', 'id');

    my $sort_order = 0;
    for my $recipe (@$recipe_list) {
        # Create cookbook recipe
        $dbh->do(q{
            INSERT INTO cookbook_recipes (cookbook_id, sort_order)
            VALUES (?, ?)
        }, undef, $cookbook_id, $sort_order++);

        my $cookbook_recipe_id = $dbh->last_insert_id(undef, undef, 'cookbook_recipes', 'id');

        # Copy inputs from user recipe to cookbook recipe
        my $inputs = $dbh->selectall_arrayref(
            'SELECT item_id, quantity FROM recipe_inputs WHERE recipe_id = ?',
            { Slice => {} }, $recipe->{id}
        );
        for my $input (@$inputs) {
            $dbh->do(q{
                INSERT INTO cookbook_recipe_inputs (recipe_id, item_id, quantity)
                VALUES (?, ?, ?)
            }, undef, $cookbook_recipe_id, $input->{item_id}, $input->{quantity});
        }

        # Copy outputs
        my $outputs = $dbh->selectall_arrayref(
            'SELECT item_id, quantity FROM recipe_outputs WHERE recipe_id = ?',
            { Slice => {} }, $recipe->{id}
        );
        for my $output (@$outputs) {
            $dbh->do(q{
                INSERT INTO cookbook_recipe_outputs (recipe_id, item_id, quantity)
                VALUES (?, ?, ?)
            }, undef, $cookbook_recipe_id, $output->{item_id}, $output->{quantity});
        }

        print "  Added recipe $recipe->{id} as cookbook_recipe $cookbook_recipe_id\n";
    }
}
