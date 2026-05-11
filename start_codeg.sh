#!/usr/bin/env bash
set -euo pipefail

CODEG_APP="/Users/taliszhou/code/src/github.com/codeg/src-tauri/target/release/bundle/macos/codeg.app"
ANACONDA_BIN="/opt/anaconda3/bin"

if [[ ! -d "$CODEG_APP" ]]; then
  echo "codeg.app not found at: $CODEG_APP" >&2
  exit 1
fi

if pgrep -x codeg >/dev/null; then
  echo "codeg is already running. quit it first (Cmd-Q) so the new PATH takes effect."
  exit 1
fi

launchctl setenv PATH "$ANACONDA_BIN:$(launchctl getenv PATH 2>/dev/null || echo "$PATH")"
echo "launchd PATH now: $(launchctl getenv PATH)"

open "$CODEG_APP"
echo "codeg launched. python3 will resolve to: $ANACONDA_BIN/python3"
