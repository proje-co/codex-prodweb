#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <project-name>"
  echo "Example: $0 codex-api"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

PROJECT_NAME="$1"

if [[ ! -f .deploy.env ]]; then
  echo "Missing .deploy.env. Start from .deploy.env.example"
  exit 1
fi

# shellcheck disable=SC1091
source .deploy.env

required_vars=(VPS_HOST VPS_USER VPS_PORT PROJECT_PREFIX DEPLOY_NAMESPACE)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable in .deploy.env: $v"
    exit 1
  fi
done

if [[ "$PROJECT_NAME" != ${PROJECT_PREFIX}-* ]]; then
  echo "Refusing deploy. Project name must start with '${PROJECT_PREFIX}-'"
  exit 1
fi

REMOTE_CMD=$(cat <<REMOTE
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed on server"
  exit 1
fi

# Create isolated network for codex-managed apps only.
docker network inspect "$DEPLOY_NAMESPACE" >/dev/null 2>&1 || docker network create "$DEPLOY_NAMESPACE"

echo "Safe target confirmed: $PROJECT_NAME"
echo "Namespace/network: $DEPLOY_NAMESPACE"
echo "Next step: wire this script to your build+run flow or EasyPanel API deployment"
REMOTE
)

ssh -p "$VPS_PORT" "$VPS_USER@$VPS_HOST" "$REMOTE_CMD"
