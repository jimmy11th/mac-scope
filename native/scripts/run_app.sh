#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_PATH=$("$SCRIPT_DIR/build_app.sh" "${1:-debug}")

/usr/bin/open "$APP_PATH"
