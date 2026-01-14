#!/bin/bash
# Download item icons from RuneLite cache
# Skips items that have already been downloaded

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_PATH="$SCRIPT_DIR/data/gp_kitchen.db"
ICONS_DIR="$SCRIPT_DIR/public/images/items"
BASE_URL="https://static.runelite.net/cache/item/icon"

mkdir -p "$ICONS_DIR"

# Get item IDs that are missing
sqlite3 "$DB_PATH" "SELECT id FROM items ORDER BY id" | while read id; do
    [ ! -f "$ICONS_DIR/$id.png" ] && echo "$id"
done > /tmp/missing_icons.txt

missing=$(wc -l < /tmp/missing_icons.txt)
existing=$(ls "$ICONS_DIR"/*.png 2>/dev/null | wc -l)

if [ "$missing" -eq 0 ]; then
    echo "All $existing icons already downloaded."
    exit 0
fi

echo "Found $existing existing icons, downloading $missing missing..."

# Download in parallel (8 concurrent)
cat /tmp/missing_icons.txt | xargs -P 8 -I {} sh -c \
    'curl -sf --connect-timeout 5 --max-time 10 -o "'"$ICONS_DIR"'/{}.png" "'"$BASE_URL"'/{}.png" 2>/dev/null && echo -n "." || echo -n "x"'

echo ""
echo "Done! Total icons: $(ls "$ICONS_DIR"/*.png | wc -l)"
