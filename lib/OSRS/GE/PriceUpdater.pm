package OSRS::GE::PriceUpdater;
use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP qw(decode_json);

my $BASE_URL = 'https://prices.runescape.wiki/api/v1/osrs';

sub new {
    my ($class, %args) = @_;
    return bless {
        schema     => $args{schema},
        user_agent => $args{user_agent} // 'GP-Kitchen/1.0',
        log        => $args{log} // sub { warn @_, "\n" },
    }, $class;
}

sub update_all {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    # Fetch and update item mappings
    $log->("Fetching item mappings...");
    my $mapping_res = $ua->get("$BASE_URL/mapping");
    die "Failed to fetch mappings: " . $mapping_res->status_line unless $mapping_res->is_success;

    my $items = decode_json($mapping_res->decoded_content);
    $log->("Updating " . scalar(@$items) . " items...");
    $self->{schema}->upsert_item($_) for @$items;

    # Fetch and update latest prices
    $log->("Fetching latest prices...");
    my $prices_res = $ua->get("$BASE_URL/latest");
    die "Failed to fetch prices: " . $prices_res->status_line unless $prices_res->is_success;

    my $prices = decode_json($prices_res->decoded_content)->{data};
    $log->("Updating prices for " . scalar(keys %$prices) . " items...");
    $self->{schema}->bulk_upsert_prices($prices);

    # Fetch and update 5-minute averages
    $log->("Fetching 5-minute averages...");
    my $avg_res = $ua->get("$BASE_URL/5m");
    die "Failed to fetch 5m prices: " . $avg_res->status_line unless $avg_res->is_success;

    my $averages = decode_json($avg_res->decoded_content)->{data};
    $log->("Updating 5m averages for " . scalar(keys %$averages) . " items...");
    $self->{schema}->bulk_upsert_5m_prices($averages);

    # Update volumes for conversion items
    $self->update_conversion_volumes;

    $log->("Price update complete.");
}

sub update_latest {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    my $res = $ua->get("$BASE_URL/latest");
    die "Failed to fetch prices: " . $res->status_line unless $res->is_success;

    my $prices = decode_json($res->decoded_content)->{data};
    $self->{schema}->bulk_upsert_prices($prices);
}

sub update_conversion_volumes {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    $log->("Fetching bulk volume data...");

    my %volumes;
    my $now = time();

    # 1. Fetch /5m for 5-minute volumes (all items)
    $log->("Fetching 5m volumes...");
    my $res_5m = $ua->get("$BASE_URL/5m");
    if ($res_5m->is_success) {
        my $data = decode_json($res_5m->decoded_content)->{data};
        for my $id (keys %$data) {
            $volumes{$id}{vol_5m_high} = $data->{$id}{highPriceVolume} // 0;
            $volumes{$id}{vol_5m_low} = $data->{$id}{lowPriceVolume} // 0;
        }
    }

    # 2. Fetch /1h for last 4 hours to get 4h volumes
    # Timestamps must be rounded to hour boundaries
    my $hour_start = int($now / 3600) * 3600;
    $log->("Fetching 4h volumes (4 hourly requests)...");
    for my $h (1 .. 4) {  # Start from 1 (current hour has no data yet)
        my $ts = $hour_start - ($h * 3600);
        my $res = $ua->get("$BASE_URL/1h?timestamp=$ts");
        next unless $res->is_success;
        my $data = decode_json($res->decoded_content)->{data};
        for my $id (keys %$data) {
            $volumes{$id}{vol_4h_high} += $data->{$id}{highPriceVolume} // 0;
            $volumes{$id}{vol_4h_low} += $data->{$id}{lowPriceVolume} // 0;
        }
    }

    # 3. Fetch /1h at 1h, 6h, 12h, 18h ago to estimate 24h volume
    $log->("Fetching 24h volume samples...");
    my %samples_24h;
    for my $h (1, 7, 13, 19) {  # Start from 1 (current hour has no data)
        my $ts = $hour_start - ($h * 3600);
        my $res = $ua->get("$BASE_URL/1h?timestamp=$ts");
        next unless $res->is_success;
        my $data = decode_json($res->decoded_content)->{data};
        for my $id (keys %$data) {
            $samples_24h{$id}{high} += $data->{$id}{highPriceVolume} // 0;
            $samples_24h{$id}{low} += $data->{$id}{lowPriceVolume} // 0;
            $samples_24h{$id}{count}++;
        }
    }
    for my $id (keys %samples_24h) {
        my $count = $samples_24h{$id}{count} || 1;
        $volumes{$id}{vol_24h_high} = int(($samples_24h{$id}{high} / $count) * 24);
        $volumes{$id}{vol_24h_low} = int(($samples_24h{$id}{low} / $count) * 24);
    }

    # Save volumes for all items
    $log->("Saving volumes for " . scalar(keys %volumes) . " items...");
    for my $id (keys %volumes) {
        $self->{schema}->upsert_item_volumes($id, $volumes{$id});
    }

    $log->("Volume update complete.");
}

1;
