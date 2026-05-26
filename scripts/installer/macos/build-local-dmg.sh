#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MANAGER_DIR="$ROOT/apps/codex-plus-manager"
PACKAGER="$ROOT/scripts/installer/macos/package-dmg-signed.sh"

VERSION="${VERSION:-}"
ARCH="${ARCH:-}"
TARGET="${TARGET:-}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-${CODESIGN_IDENTITY:-auto}}"
NOTARIZE="${APPLE_NOTARIZE:-auto}"
NOTARY_APPLE_ID="${APPLE_ID:-}"
NOTARY_APP_PASSWORD="${APPLE_PASSWORD:-}"
NOTARY_TEAM_ID="${APPLE_TEAM_ID:-}"
RUN_INSTALL=1
RUN_CHECK=1
CLEAN=0

log() {
  printf '[local-macos-build] %s\n' "$*"
}

fail() {
  printf '[local-macos-build] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  scripts/installer/macos/build-local-dmg.sh [options]

Options:
  --version VERSION       DMG/app version. Defaults to apps/codex-plus-manager/package.json.
  --arch ARCH             Artifact label, usually arm64 or x64. Defaults from current Mac.
  --target TARGET         Rust target triple, for example aarch64-apple-darwin.
  --identity ID           Code signing identity. Defaults to auto-detect Developer ID Application.
  --identity -            Force ad-hoc signing.
  --notarize MODE         auto, 1, or 0. Defaults to auto.
  --apple-id EMAIL        Apple ID used for notarytool notarization.
  --app-password PASSWORD App-specific password used for notarytool notarization.
  --team-id TEAM_ID       Apple Developer Team ID used for notarytool notarization.
  --skip-install          Do not run npm ci.
  --skip-check            Do not run TypeScript check.
  --clean                 Remove frontend dist and relevant release binaries before building.
  -h, --help              Show this help.

Environment overrides:
  VERSION, ARCH, TARGET, APPLE_SIGNING_IDENTITY, CODESIGN_IDENTITY,
  APPLE_NOTARIZE, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID,
  MACOS_ENTITLEMENTS, DIST, npm_config_*.

Notarization credentials are read by package-dmg-signed.sh:
  APPLE_NOTARY_KEYCHAIN_PROFILE
  or APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID
  or APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID
USAGE
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

notarization_requested() {
  case "$NOTARIZE" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

default_arch() {
  case "$(uname -m)" in
    arm64) printf 'arm64' ;;
    x86_64) printf 'x64' ;;
    *) uname -m ;;
  esac
}

default_target_for_arch() {
  case "$1" in
    arm64|aarch64) printf 'aarch64-apple-darwin' ;;
    x64|x86_64) printf 'x86_64-apple-darwin' ;;
    *) printf '' ;;
  esac
}

package_version() {
  node -p "require('$MANAGER_DIR/package.json').version" 2>/dev/null
}

auto_signing_identity() {
  if ! command -v security >/dev/null 2>&1; then
    return 0
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || fail "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --arch)
        [[ $# -ge 2 ]] || fail "--arch requires a value"
        ARCH="$2"
        shift 2
        ;;
      --target)
        [[ $# -ge 2 ]] || fail "--target requires a value"
        TARGET="$2"
        shift 2
        ;;
      --identity)
        [[ $# -ge 2 ]] || fail "--identity requires a value"
        SIGNING_IDENTITY="$2"
        shift 2
        ;;
      --notarize)
        [[ $# -ge 2 ]] || fail "--notarize requires a value"
        NOTARIZE="$2"
        shift 2
        ;;
      --apple-id)
        [[ $# -ge 2 ]] || fail "--apple-id requires a value"
        NOTARY_APPLE_ID="$2"
        shift 2
        ;;
      --app-password|--apple-password)
        [[ $# -ge 2 ]] || fail "$1 requires a value"
        NOTARY_APP_PASSWORD="$2"
        shift 2
        ;;
      --team-id)
        [[ $# -ge 2 ]] || fail "--team-id requires a value"
        NOTARY_TEAM_ID="$2"
        shift 2
        ;;
      --skip-install)
        RUN_INSTALL=0
        shift
        ;;
      --skip-check)
        RUN_CHECK=0
        shift
        ;;
      --clean)
        CLEAN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        ;;
    esac
  done
}

validate() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this script must run on macOS"
  [[ -f "$MANAGER_DIR/package.json" ]] || fail "missing package.json: $MANAGER_DIR/package.json"
  [[ -x "$PACKAGER" ]] || fail "missing executable packager: $PACKAGER"

  require_tool bash
  require_tool cargo
  require_tool node
  require_tool npm

  VERSION="${VERSION:-$(package_version)}"
  [[ -n "$VERSION" ]] || fail "could not determine version"

  ARCH="${ARCH:-$(default_arch)}"
  if [[ -z "$TARGET" ]]; then
    TARGET="$(default_target_for_arch "$ARCH")"
  fi

  if [[ -n "$NOTARY_APPLE_ID$NOTARY_APP_PASSWORD$NOTARY_TEAM_ID" ]]; then
    [[ -n "$NOTARY_APPLE_ID" ]] || fail "--apple-id or APPLE_ID is required when using app-specific password notarization"
    [[ -n "$NOTARY_APP_PASSWORD" ]] || fail "--app-password or APPLE_PASSWORD is required when using app-specific password notarization"
    [[ -n "$NOTARY_TEAM_ID" ]] || fail "--team-id or APPLE_TEAM_ID is required when using app-specific password notarization"
  fi
}

clean_outputs() {
  if [[ "$CLEAN" -ne 1 ]]; then
    return 0
  fi
  log "cleaning local build outputs"
  rm -rf "$MANAGER_DIR/dist"
  if [[ -n "$TARGET" ]]; then
    rm -f "$ROOT/target/$TARGET/release/codex-plus-plus"
    rm -f "$ROOT/target/$TARGET/release/codex-plus-plus-manager"
  else
    rm -f "$ROOT/target/release/codex-plus-plus"
    rm -f "$ROOT/target/release/codex-plus-plus-manager"
  fi
}

install_frontend_deps() {
  if [[ "$RUN_INSTALL" -eq 0 ]]; then
    log "skipping npm ci"
    return
  fi

  log "installing frontend dependencies"
  npm --prefix "$MANAGER_DIR" ci
}

build_frontend() {
  if [[ "$RUN_CHECK" -eq 1 ]]; then
    log "running TypeScript check"
    npm --prefix "$MANAGER_DIR" run check
  else
    log "skipping TypeScript check"
  fi

  log "building frontend"
  npm --prefix "$MANAGER_DIR" run vite:build
}

build_binaries() {
  local cargo_args=(build --release -p codex-plus-launcher -p codex-plus-manager)
  if [[ -n "$TARGET" ]]; then
    if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "$TARGET"; then
      log "installing Rust target: $TARGET"
      rustup target add "$TARGET"
    fi
    cargo_args+=(--target "$TARGET")
  fi

  log "building Rust release binaries"
  cargo "${cargo_args[@]}"
}

binary_dir() {
  if [[ -n "$TARGET" ]]; then
    printf '%s/target/%s/release' "$ROOT" "$TARGET"
  else
    printf '%s/target/release' "$ROOT"
  fi
}

resolve_signing_identity() {
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_IDENTITY=""
    if notarization_requested; then
      fail "notarization requires a Developer ID signing identity"
    fi
    log "using ad-hoc signing"
    return
  fi

  if [[ "$SIGNING_IDENTITY" == "auto" ]]; then
    SIGNING_IDENTITY="$(auto_signing_identity)"
    if [[ -n "$SIGNING_IDENTITY" ]]; then
      log "using signing identity: $SIGNING_IDENTITY"
    else
      if notarization_requested; then
        fail "notarization requires a Developer ID signing identity"
      fi
      log "no Developer ID Application identity found; using ad-hoc signing"
    fi
  else
    log "using signing identity: $SIGNING_IDENTITY"
  fi
}

package_dmg() {
  local binaries
  local -a package_env
  binaries="$(binary_dir)"
  [[ -x "$binaries/codex-plus-plus" ]] || fail "missing launcher binary: $binaries/codex-plus-plus"
  [[ -x "$binaries/codex-plus-plus-manager" ]] || fail "missing manager binary: $binaries/codex-plus-plus-manager"

  log "packaging DMG"
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    package_env=(
      APPLE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
      APPLE_NOTARIZE="$NOTARIZE"
      BINARY_DIR="$binaries"
    )
    if [[ -n "$NOTARY_APPLE_ID" ]]; then
      package_env+=(
        APPLE_ID="$NOTARY_APPLE_ID"
        APPLE_PASSWORD="$NOTARY_APP_PASSWORD"
        APPLE_TEAM_ID="$NOTARY_TEAM_ID"
      )
    fi
    env "${package_env[@]}" bash "$PACKAGER" "$VERSION" "$ARCH"
  else
    APPLE_NOTARIZE=0 \
    BINARY_DIR="$binaries" \
    bash "$PACKAGER" "$VERSION" "$ARCH"
  fi
}

parse_args "$@"
validate
clean_outputs
install_frontend_deps
build_frontend
build_binaries
resolve_signing_identity
package_dmg
