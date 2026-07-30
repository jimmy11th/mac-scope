#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
RESOURCE_DIR="$NATIVE_ROOT/Resources"
SOURCE_DIR="$RESOURCE_DIR/IconSources"
TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macscope-icons.XXXXXX")

cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

build_icon() {
  local source_name=$1
  local png_name=$2
  local icns_name=$3
  local source_path="$SOURCE_DIR/${source_name}.png"
  local png_path="$RESOURCE_DIR/${png_name}.png"
  local iconset_path="$TEMP_DIR/${icns_name}.iconset"

  /usr/bin/swift "$SCRIPT_DIR/render_app_icon.swift" "$source_path" "$png_path"
  /bin/mkdir -p "$iconset_path"

  /usr/bin/sips -z 16 16 "$png_path" --out "$iconset_path/icon_16x16.png" >/dev/null
  /usr/bin/sips -z 32 32 "$png_path" --out "$iconset_path/icon_16x16@2x.png" >/dev/null
  /usr/bin/sips -z 32 32 "$png_path" --out "$iconset_path/icon_32x32.png" >/dev/null
  /usr/bin/sips -z 64 64 "$png_path" --out "$iconset_path/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -z 128 128 "$png_path" --out "$iconset_path/icon_128x128.png" >/dev/null
  /usr/bin/sips -z 256 256 "$png_path" --out "$iconset_path/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -z 256 256 "$png_path" --out "$iconset_path/icon_256x256.png" >/dev/null
  /usr/bin/sips -z 512 512 "$png_path" --out "$iconset_path/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -z 512 512 "$png_path" --out "$iconset_path/icon_512x512.png" >/dev/null
  /usr/bin/ditto "$png_path" "$iconset_path/icon_512x512@2x.png"
  /usr/bin/iconutil -c icns "$iconset_path" -o "$RESOURCE_DIR/${icns_name}.icns"
}

build_icon "MacScopeForeground" "MacScopeIcon" "MacScope"
build_icon "MacScopeDetailedForeground" "MacScopeIconDetailed" "MacScopeDetailed"

/usr/bin/printf 'Generated MacScope app icons in %s\n' "$RESOURCE_DIR"
