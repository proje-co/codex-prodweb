#!/usr/bin/env bash
set -euo pipefail

# CI-friendly deploy trigger for EasyPanel.
# Expects env vars:
# - EASYPANEL_URL (e.g. http://72.60.23.237:3000)
# - EASYPANEL_API_KEY
# - EASYPANEL_PROJECT (e.g. app)
# - EASYPANEL_SERVICE (e.g. codex-myapp)

: "${EASYPANEL_URL:?}"
: "${EASYPANEL_API_KEY:?}"
: "${EASYPANEL_PROJECT:?}"
: "${EASYPANEL_SERVICE:?}"

BASE_URL="${EASYPANEL_URL%/}"

payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ENV.fetch("EASYPANEL_PROJECT"), serviceName: ENV.fetch("EASYPANEL_SERVICE"), forceRebuild: false}})')

curl -sS -H "Authorization: Bearer ${EASYPANEL_API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/api/trpc/services.app.deployService" \
  --data "$payload" \
  | ruby -rjson -e 'd=JSON.parse(STDIN.read) rescue (warn("non-json response"); exit 1); if d["error"]; warn(d.dig("error","json","message") || d["error"].to_s); exit 1; end; puts("deploy-triggered")'
