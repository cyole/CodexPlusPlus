#!/usr/bin/env bash
set -euo pipefail

REPO=""
CERTIFICATE=""
CERTIFICATE_PASSWORD=""
SIGNING_IDENTITY=""
API_KEY=""
API_KEY_ID=""
API_ISSUER_ID=""
KEYCHAIN_PASSWORD=""

log() {
  printf '[github-signing-secrets] %s\n' "$*"
}

fail() {
  printf '[github-signing-secrets] error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  scripts/installer/macos/setup-github-signing-secrets.sh [options]

Required:
  --repo OWNER/REPO
  --certificate /path/to/developer-id-application.p12
  --certificate-password PASSWORD
  --signing-identity "Developer ID Application: Name (TEAMID)"
  --api-key /path/to/AuthKey_XXXXXXXXXX.p8
  --api-key-id XXXXXXXXXX
  --api-issuer-id UUID

Optional:
  --keychain-password PASSWORD
  -h, --help

Secrets written:
  APPLE_CERTIFICATE_P12_BASE64
  APPLE_CERTIFICATE_PASSWORD
  APPLE_SIGNING_IDENTITY
  APPLE_API_KEY_P8_BASE64
  APPLE_API_KEY_ID
  APPLE_API_ISSUER_ID
  APPLE_KEYCHAIN_PASSWORD
USAGE
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

base64_file() {
  base64 < "$1" | tr -d '\n'
}

set_secret() {
  local name="$1"
  local value="$2"
  log "setting $name"
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" --body-file -
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || fail "--repo requires a value"
        REPO="$2"
        shift 2
        ;;
      --certificate)
        [[ $# -ge 2 ]] || fail "--certificate requires a value"
        CERTIFICATE="$2"
        shift 2
        ;;
      --certificate-password)
        [[ $# -ge 2 ]] || fail "--certificate-password requires a value"
        CERTIFICATE_PASSWORD="$2"
        shift 2
        ;;
      --signing-identity)
        [[ $# -ge 2 ]] || fail "--signing-identity requires a value"
        SIGNING_IDENTITY="$2"
        shift 2
        ;;
      --api-key)
        [[ $# -ge 2 ]] || fail "--api-key requires a value"
        API_KEY="$2"
        shift 2
        ;;
      --api-key-id)
        [[ $# -ge 2 ]] || fail "--api-key-id requires a value"
        API_KEY_ID="$2"
        shift 2
        ;;
      --api-issuer-id)
        [[ $# -ge 2 ]] || fail "--api-issuer-id requires a value"
        API_ISSUER_ID="$2"
        shift 2
        ;;
      --keychain-password)
        [[ $# -ge 2 ]] || fail "--keychain-password requires a value"
        KEYCHAIN_PASSWORD="$2"
        shift 2
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
  require_tool gh
  require_tool base64
  require_tool tr

  [[ -n "$REPO" ]] || fail "--repo is required"
  [[ -n "$CERTIFICATE" ]] || fail "--certificate is required"
  [[ -f "$CERTIFICATE" ]] || fail "certificate file does not exist: $CERTIFICATE"
  [[ -n "$CERTIFICATE_PASSWORD" ]] || fail "--certificate-password is required"
  [[ -n "$SIGNING_IDENTITY" ]] || fail "--signing-identity is required"
  [[ -n "$API_KEY" ]] || fail "--api-key is required"
  [[ -f "$API_KEY" ]] || fail "api key file does not exist: $API_KEY"
  [[ -n "$API_KEY_ID" ]] || fail "--api-key-id is required"
  [[ -n "$API_ISSUER_ID" ]] || fail "--api-issuer-id is required"
}

parse_args "$@"
validate

set_secret APPLE_CERTIFICATE_P12_BASE64 "$(base64_file "$CERTIFICATE")"
set_secret APPLE_CERTIFICATE_PASSWORD "$CERTIFICATE_PASSWORD"
set_secret APPLE_SIGNING_IDENTITY "$SIGNING_IDENTITY"
set_secret APPLE_API_KEY_P8_BASE64 "$(base64_file "$API_KEY")"
set_secret APPLE_API_KEY_ID "$API_KEY_ID"
set_secret APPLE_API_ISSUER_ID "$API_ISSUER_ID"

if [[ -n "$KEYCHAIN_PASSWORD" ]]; then
  set_secret APPLE_KEYCHAIN_PASSWORD "$KEYCHAIN_PASSWORD"
fi

log "done"
