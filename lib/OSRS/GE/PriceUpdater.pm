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

sub update_mappings {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    $log->("Fetching item mappings...");
    my $res = $ua->get("$BASE_URL/mapping");
    die "Failed to fetch mappings: " . $res->status_line unless $res->is_success;

    my $items = decode_json($res->decoded_content);
    $log->("Updating " . scalar(@$items) . " items...");
    $self->{schema}->upsert_item($_) for @$items;
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

sub update_5m_volumes {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    $log->("Fetching 5m volumes...");
    my $res = $ua->get("$BASE_URL/5m");
    return unless $res->is_success;

    my $data = decode_json($res->decoded_content)->{data};
    $log->("Saving 5m volumes for " . scalar(keys %$data) . " items...");
    for my $id (keys %$data) {
        $self->{schema}->upsert_5m_volumes($id, $data->{$id}{highPriceVolume}, $data->{$id}{lowPriceVolume});
    }
}

sub update_4h_volumes {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    my $now = time();
    my $hour_start = int($now / 3600) * 3600;

    $log->("Fetching 4h volumes (4 hourly requests)...");
    my %volumes;
    for my $h (1 .. 4) {
        my $ts = $hour_start - ($h * 3600);
        my $res = $ua->get("$BASE_URL/1h?timestamp=$ts");
        next unless $res->is_success;
        my $data = decode_json($res->decoded_content)->{data};
        for my $id (keys %$data) {
            $volumes{$id}{high} += $data->{$id}{highPriceVolume} // 0;
            $volumes{$id}{low} += $data->{$id}{lowPriceVolume} // 0;
        }
    }

    $log->("Saving 4h volumes for " . scalar(keys %volumes) . " items...");
    for my $id (keys %volumes) {
        $self->{schema}->upsert_4h_volumes($id, $volumes{$id}{high}, $volumes{$id}{low});
    }
}

sub update_24h_volumes {
    my ($self) = @_;
    my $log = $self->{log};

    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent   => $self->{user_agent},
    );

    $log->("Fetching 24h volumes...");
    my $res = $ua->get("$BASE_URL/24h");
    return unless $res->is_success;

    my $data = decode_json($res->decoded_content)->{data};
    $log->("Saving 24h volumes for " . scalar(keys %$data) . " items...");
    for my $id (keys %$data) {
        $self->{schema}->upsert_24h_volumes($id, $data->{$id}{highPriceVolume}, $data->{$id}{lowPriceVolume});
    }
}

1;
