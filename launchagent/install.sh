#!/bin/bash
# Builds capeapply, installs a .cape and a LaunchAgent that applies it at login
# and after every display change.
#
#   ./install.sh                    use ComicBook.cape from this repo
#   ./install.sh path/to/file.cape  use another cape instead
set -euo pipefail

LABEL=me.tonsky.cursors
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/Library/Application Support/ComicBookCursors"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ComicBookCursors.log"
CAPE="${1:-$HERE/../ComicBook.cape}"

mkdir -p "$DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"

echo "Building capeapply"
clang -fobjc-arc -O2 -Wall -o "$DIR/capeapply" "$HERE/capeapply.m" \
    -framework Cocoa -framework SystemConfiguration

echo "Using $CAPE"
cp "$CAPE" "$DIR/ComicBook.cape"

echo "Installing $PLIST"
sed -e "s|__DIR__|$DIR|g" -e "s|__LOG__|$LOG|g" "$HERE/$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Done. Log: $LOG"
