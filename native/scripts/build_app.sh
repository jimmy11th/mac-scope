#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
PROJECT_ROOT=${NATIVE_ROOT:h}
CONFIGURATION=${1:-debug}
APP_DIR="$NATIVE_ROOT/build/MacScope.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" >&2
BIN_DIR=$(swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" --show-bin-path)

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/ditto "$BIN_DIR/MacScopeShell" "$MACOS_DIR/MacScopeShell"
/usr/bin/ditto "$NATIVE_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

for resource_bundle in "$BIN_DIR"/*.bundle(N); do
    /usr/bin/ditto "$resource_bundle" "$RESOURCES_DIR/${resource_bundle:t}"
done

UV_PATH=${MACSCOPE_UV_PATH:-$(command -v uv || true)}
/usr/libexec/PlistBuddy -c "Set :MacScopeProjectRoot $PROJECT_ROOT" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacScopeUVPath $UV_PATH" "$CONTENTS_DIR/Info.plist"

/usr/bin/codesign --force --deep --sign - "$APP_DIR" >&2
/usr/bin/printf '%s\n' "$APP_DIR"
