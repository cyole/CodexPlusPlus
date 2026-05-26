#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.0.0}"
ARCH="${2:-$(uname -m)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DIST="${DIST:-$ROOT/dist/macos-signed}"
WORK="$DIST/work-$ARCH"
STAGE="$WORK/stage"
BINARY_DIR="${BINARY_DIR:-$ROOT/target/release}"
DMG="$DIST/CodexPlusPlus-${VERSION}-macos-${ARCH}.dmg"
ICON_SOURCE="$ROOT/apps/codex-plus-manager/src-tauri/icons/icon.png"
ICON_NAME="codex-plus-plus.icns"
ICON_ICNS="$WORK/$ICON_NAME"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-${CODESIGN_IDENTITY:-}}"
ENTITLEMENTS="${MACOS_ENTITLEMENTS:-}"
NOTARIZE_MODE="${APPLE_NOTARIZE:-auto}"

log() {
  printf '[macos-signed-package] %s\n' "$*"
}

fail() {
  printf '[macos-signed-package] error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

require_macos_tools() {
  require_tool codesign
  require_tool hdiutil
  require_tool iconutil
  require_tool plutil
  require_tool sips
  require_tool shasum
  require_tool spctl
  require_tool xcrun
}

retry_hdiutil_verify() {
  local image="$1"
  local attempts=10
  local delay=2
  local output

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if output="$(hdiutil verify "$image" 2>&1)"; then
      return 0
    fi

    if [[ "$attempt" -eq "$attempts" ]]; then
      printf '%s\n' "$output" >&2
      return 1
    fi

    log "hdiutil verify is not ready yet; retrying in ${delay}s ($attempt/$attempts)"
    sleep "$delay"
  done
}

validate_inputs() {
  [[ -f "$ICON_SOURCE" ]] || fail "icon source does not exist: $ICON_SOURCE"
  [[ -x "$BINARY_DIR/codex-plus-plus" ]] || fail "launcher binary is missing or not executable: $BINARY_DIR/codex-plus-plus"
  [[ -x "$BINARY_DIR/codex-plus-plus-manager" ]] || fail "manager binary is missing or not executable: $BINARY_DIR/codex-plus-plus-manager"
  if [[ -n "$ENTITLEMENTS" && ! -f "$ENTITLEMENTS" ]]; then
    fail "MACOS_ENTITLEMENTS points to a missing file: $ENTITLEMENTS"
  fi
}

prepare_workdir() {
  rm -rf "$WORK" "$DMG" "$DMG.sha256"
  mkdir -p "$STAGE"
}

notary_auth_configured() {
  if [[ -n "${APPLE_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    return 0
  fi
  if [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    return 0
  fi
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    return 0
  fi
  return 1
}

should_notarize() {
  case "$NOTARIZE_MODE" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    0|false|FALSE|no|NO)
      return 1
      ;;
    auto|"")
      [[ -n "$SIGNING_IDENTITY" ]] && notary_auth_configured
      ;;
    *)
      fail "APPLE_NOTARIZE must be one of auto, 1, true, yes, 0, false, no"
      ;;
  esac
}

codesign_app() {
  local app_dir="$1"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    log "ad-hoc signing $app_dir"
    codesign --force --sign - "$app_dir"
  else
    log "Developer ID signing $app_dir"
    local args=(--force --timestamp --options runtime --sign "$SIGNING_IDENTITY")
    if [[ -n "$ENTITLEMENTS" ]]; then
      args+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${args[@]}" "$app_dir"
  fi
  codesign --verify --deep --strict --verbose=2 "$app_dir"
}

codesign_dmg() {
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    log "skipping DMG Developer ID signature because APPLE_SIGNING_IDENTITY is not set"
    return
  fi
  log "Developer ID signing $DMG"
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
}

prepare_icon() {
  local iconset="$WORK/codex-plus-plus.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"

  sips -z 16 16 "$ICON_SOURCE" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$iconset/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset" -o "$ICON_ICNS"
}

create_app() {
  local app_name="$1"
  local executable_name="$2"
  local binary_path="$3"
  local bundle_id="$4"
  local lsui_element="${5:-false}"
  local app_dir="$STAGE/$app_name.app"

  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  cp "$binary_path" "$app_dir/Contents/MacOS/$executable_name"
  cp "$ICON_ICNS" "$app_dir/Contents/Resources/$ICON_NAME"
  chmod +x "$app_dir/Contents/MacOS/$executable_name"
  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>$executable_name</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <$lsui_element/>
</dict>
</plist>
PLIST
  plutil -lint "$app_dir/Contents/Info.plist" >/dev/null
}

create_dmg() {
  log "creating $DMG"
  hdiutil create -volname "Codex++" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  retry_hdiutil_verify "$DMG"
  shasum -a 256 "$DMG" > "$DMG.sha256"
}

submit_notarization() {
  if ! should_notarize; then
    log "notarization skipped; set APPLE_NOTARIZE=1 and provide Apple credentials to require it"
    return
  fi
  [[ -n "$SIGNING_IDENTITY" ]] || fail "notarization requires APPLE_SIGNING_IDENTITY"

  log "submitting $DMG for notarization"
  if [[ -n "${APPLE_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" \
      --keychain-profile "$APPLE_NOTARY_KEYCHAIN_PROFILE" \
      --wait
  elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" \
      --key "$APPLE_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID" \
      --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  else
    fail "notarization requested, but no notarytool credentials are configured"
  fi

  log "stapling notarization ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
}

require_macos_tools
validate_inputs
prepare_workdir
prepare_icon
create_app "Codex++" "CodexPlusPlus" "$BINARY_DIR/codex-plus-plus" "com.bigpizzav3.codexplusplus" "true"
create_app "Codex++ 管理工具" "CodexPlusPlusManager" "$BINARY_DIR/codex-plus-plus-manager" "com.bigpizzav3.codexplusplus.manager" "false"
ln -s /Applications "$STAGE/Applications"

codesign_app "$STAGE/Codex++.app"
codesign_app "$STAGE/Codex++ 管理工具.app"

create_dmg
codesign_dmg
submit_notarization
echo "$DMG"
