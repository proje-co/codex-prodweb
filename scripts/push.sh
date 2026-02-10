#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

usage() {
  cat <<USAGE
Usage:
  $0 <service> [project]

What it does:
- Creates a tar.gz archive of this repo (excluding secrets)
- Uploads it to the VPS under /etc/easypanel/codex-archives/<service>.tar.gz
- Calls EasyPanel uploadCodeArchive
- Triggers deploy

Requires:
- .deploy.env (VPS_HOST/VPS_USER/VPS_PORT, EASYPANEL_URL, EASYPANEL_PROJECT)
- .secrets.env (EASYPANEL_API_KEY)
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

SERVICE="$1"
PROJECT_OVERRIDE="${2:-}"

if [[ ! -f .deploy.env ]]; then
  echo "Missing .deploy.env"
  exit 1
fi
# shellcheck disable=SC1091
source .deploy.env

if [[ ! -f .secrets.env ]]; then
  echo "Missing .secrets.env"
  exit 1
fi
# shellcheck disable=SC1091
source .secrets.env

: "${VPS_HOST:?}"
: "${VPS_USER:?}"
: "${VPS_PORT:?}"
: "${PROJECT_PREFIX:?}"

PROJECT="${PROJECT_OVERRIDE:-${EASYPANEL_PROJECT:-}}"
if [[ -z "$PROJECT" ]]; then
  echo "Missing project. Set EASYPANEL_PROJECT in .deploy.env or pass [project]"
  exit 1
fi

if [[ "$SERVICE" != ${PROJECT_PREFIX}-* ]]; then
  echo "Refusing push. Service must start with '${PROJECT_PREFIX}-'"
  exit 1
fi

TMP_ARCHIVE="/tmp/${SERVICE}.tar.gz"
REMOTE_DIR="/etc/easypanel/codex-archives"
REMOTE_ARCHIVE="${REMOTE_DIR}/${SERVICE}.tar.gz"

rm -f "$TMP_ARCHIVE"

# If the service doesn't exist yet, create it (upload-based) and auto-publish a port.
# Note: EasyPanel may attempt an initial build before code upload; that can fail. We ignore that and proceed.
CREATED_PUBLISHED=""
if ! ./scripts/easypanel.sh list-services "$PROJECT" | grep -qx "$SERVICE"; then
  # Pick a free port on the VPS from a safe range.
  PUBLISHED=""
  for p in $(seq 18080 18150); do
    if ! ssh -p "$VPS_PORT" "$VPS_USER@$VPS_HOST" "ss -tuln | grep -q \":$p \" "; then
      PUBLISHED="$p"
      break
    fi
  done
  if [[ -z "$PUBLISHED" ]]; then
    echo "No free port found in 18080-18150"
    exit 1
  fi

  CREATED_PUBLISHED="$PUBLISHED"
  ./scripts/easypanel.sh create-upload-service "$SERVICE" "$PROJECT" "$PUBLISHED" "80" >/dev/null 2>/dev/null || true
fi

# BSD tar on macOS supports --exclude.
tar -czf "$TMP_ARCHIVE" \
  --exclude='.git' \
  --exclude='.secrets.env' \
  --exclude='.deploy.env' \
  --exclude='.local' \
  --exclude='node_modules' \
  .

ssh -p "$VPS_PORT" "$VPS_USER@$VPS_HOST" "mkdir -p '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR'"
scp -P "$VPS_PORT" "$TMP_ARCHIVE" "$VPS_USER@$VPS_HOST:$REMOTE_ARCHIVE" >/dev/null

./scripts/easypanel.sh upload-archive "$SERVICE" "$REMOTE_ARCHIVE" "$PROJECT" >/dev/null
./scripts/easypanel.sh deploy-service "$SERVICE" "$PROJECT" >/dev/null

if [[ -n "$CREATED_PUBLISHED" ]]; then
  echo "pushed+deployed (published http://$VPS_HOST:$CREATED_PUBLISHED/)"
else
  echo "pushed+deployed"
fi
