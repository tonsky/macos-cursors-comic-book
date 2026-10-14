#!/bin/bash
# Removes the LaunchAgent and installed files. Stock cursors return after logout.
set -euo pipefail

LABEL=me.tonsky.cursors

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/ComicBookCursors"

echo "Done. Log out and back in to restore stock cursors."
