#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
CONFIGURATION=${1:-debug}
APP_DIR="$NATIVE_ROOT/build/MacScope.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" >&2
BIN_DIR=$(swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" --show-bin-path)

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/ditto "$BIN_DIR/MacScopeNative" "$MACOS_DIR/MacScopeNative"
/usr/bin/ditto "$NATIVE_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/ditto "$NATIVE_ROOT/Resources/MacScope.icns" "$RESOURCES_DIR/MacScope.icns"
/usr/bin/ditto "$NATIVE_ROOT/Resources/GitHubMark.svg" "$RESOURCES_DIR/GitHubMark.svg"
for localization in "$NATIVE_ROOT"/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    /usr/bin/ditto "$localization" "$RESOURCES_DIR/${localization:t}"
done

/usr/bin/codesign --force --deep --sign - "$APP_DIR" >&2
/usr/bin/printf '%s\n' "$APP_DIR"
