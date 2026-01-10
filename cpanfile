# OSRS GE Tracker Dependencies

requires 'Mojolicious', '>= 9.0';
requires 'DBI', '>= 1.643';
requires 'DBD::SQLite', '>= 1.70';
requires 'YAML::PP', '>= 0.035';
requires 'LWP::UserAgent', '>= 6.0';
requires 'JSON::PP', '>= 4.0';

# Optional but recommended
recommends 'IO::Socket::SSL', '>= 2.0';
recommends 'Net::SSLeay', '>= 1.0';
