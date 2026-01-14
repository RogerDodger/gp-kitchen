# GP Kitchen

OSRS Grand Exchange conversion profit tracker. Configure input/output item pairs and see real-time profit calculations.

## Features

- Conversion pair dashboard with profit/ROI calculations
- Patient vs instant pricing modes
- Volume data (5m/4h/24h)
- GE tax included (2%, capped at 5M)
- Prices from OSRS Wiki API

## Quick Start

```bash
cpanm --installdeps .
perl update_prices.pl
perl app.pl daemon
```

Open http://localhost:3000. Login with password from `config.yml` to configure conversions.

## Production

See `systemd/` for service files. Copy to `/opt/gp-kitchen`, create a `gp-kitchen` user, enable services.
