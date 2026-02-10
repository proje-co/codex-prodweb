#!/usr/bin/env bash
set -euo pipefail

# One-command SDLC bootstrap:
# - Create GitHub repo
# - Upload current workspace files (excluding local secrets)
# - Set GitHub Actions secrets for EasyPanel deploy trigger
# - Create/point EasyPanel prod service to GHCR image

need_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "Missing $f"
    exit 1
  fi
}

need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing command: $c"
    exit 1
  fi
}

need_file .deploy.env
# shellcheck disable=SC1091
source .deploy.env

need_file .secrets.env
# shellcheck disable=SC1091
source .secrets.env

: "${EASYPANEL_URL:?Missing EASYPANEL_URL in .deploy.env}"
: "${EASYPANEL_API_KEY:?Missing EASYPANEL_API_KEY in .secrets.env}"
: "${EASYPANEL_PROJECT:?Missing EASYPANEL_PROJECT in .deploy.env}"
: "${GITHUB_TOKEN:?Missing GITHUB_TOKEN in .secrets.env}"

SERVICE_NAME="${1:-codex-prodweb}"
REPO_NAME="${2:-codex-prodweb}"
REPO_PRIVATE="${3:-false}"   # true|false
PUBLISHED_PORT="${4:-18081}"
TARGET_PORT="${5:-80}"

if [[ "$SERVICE_NAME" != ${PROJECT_PREFIX}-* ]]; then
  echo "Refusing. SERVICE_NAME must start with '${PROJECT_PREFIX}-'"
  exit 1
fi

need_cmd ruby

GH_BIN="./.local/bin/gh"
if [[ ! -x "$GH_BIN" ]]; then
  echo "Missing $GH_BIN. Run the gh installer step first."
  exit 1
fi

export GH_TOKEN="$GITHUB_TOKEN"

OWNER=$($GH_BIN api user -q .login)
FULL_REPO="$OWNER/$REPO_NAME"

# Create repo if missing.
if $GH_BIN repo view "$FULL_REPO" >/dev/null 2>&1; then
  echo "repo-exists:$FULL_REPO"
else
  $GH_BIN api -X POST user/repos \
    -f name="$REPO_NAME" \
    -f private="$REPO_PRIVATE" \
    -f has_issues=true \
    -f has_projects=false \
    -f has_wiki=false \
    -f auto_init=false >/dev/null
  echo "repo-created:$FULL_REPO"
fi

# Upload files using Contents API (creates commits).
# Exclusions: local secrets, local tooling, and any build artifacts.
EXCLUDES=(
  './.secrets.env'
  './.deploy.env'
  './.local/'
  './.git/'
)

is_excluded() {
  local p="$1"
  for ex in "${EXCLUDES[@]}"; do
    # Directory exclusions are expressed with a trailing slash.
    if [[ "$ex" == */ ]]; then
      if [[ "$p" == "$ex"* ]]; then
        return 0
      fi
    else
      if [[ "$p" == "$ex" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

upload_file() {
  local file="$1"
  local rel="${file#./}"
  local b64
  b64=$(ruby -rbase64 -e 'print Base64.strict_encode64(File.binread(ARGV[0]))' "$file")

  # Idempotent update: include sha if the file already exists.
  local sha=""
  if existing_json=$($GH_BIN api "repos/${FULL_REPO}/contents/${rel}?ref=main" 2>/dev/null); then
    sha=$(ruby -rjson -e '
      begin
        d = JSON.parse(STDIN.read)
      rescue
        exit 0
      end
      if d.is_a?(Hash) && d["type"] == "file" && d["sha"].is_a?(String)
        print d["sha"]
      end
    ' <<<"$existing_json")
  fi

  if [[ -n "$sha" ]]; then
    $GH_BIN api -X PUT "repos/${FULL_REPO}/contents/${rel}" \
      -f message="bootstrap: update ${rel}" \
      -f content="$b64" \
      -f sha="$sha" \
      -f branch="main" >/dev/null
  else
    $GH_BIN api -X PUT "repos/${FULL_REPO}/contents/${rel}" \
      -f message="bootstrap: add ${rel}" \
      -f content="$b64" \
      -f branch="main" >/dev/null
  fi
}

# Ensure default branch exists by creating README first.
if [[ -f README.md ]]; then
  upload_file ./README.md
else
  tmp=/tmp/README_BOOTSTRAP.md
  printf '# %s\n' "$REPO_NAME" > "$tmp"
  b64=$(ruby -rbase64 -e 'print Base64.strict_encode64(File.binread(ARGV[0]))' "$tmp")
  $GH_BIN api -X PUT "repos/${FULL_REPO}/contents/README.md" \
    -f message="bootstrap: init" \
    -f content="$b64" \
    -f branch="main" >/dev/null
fi

# Upload the rest.
while IFS= read -r f; do
  if is_excluded "$f"; then
    continue
  fi
  if [[ "$f" == "./README.md" ]]; then
    continue
  fi
  upload_file "$f"
done < <(find . -type f \
  -not -path './.git/*' \
  -not -path './.local/*' \
  -not -path './node_modules/*' \
  -not -path './.secrets.env' \
  -not -path './.deploy.env' \
  | sort)

echo "uploaded"

# Set GitHub Actions secrets.
# These are used by .github/workflows/cd-easypanel.yml
$GH_BIN secret set EASYPANEL_URL -R "$FULL_REPO" -b"${EASYPANEL_URL%/}" >/dev/null
$GH_BIN secret set EASYPANEL_API_KEY -R "$FULL_REPO" -b"$EASYPANEL_API_KEY" >/dev/null
$GH_BIN secret set EASYPANEL_PROJECT -R "$FULL_REPO" -b"$EASYPANEL_PROJECT" >/dev/null
$GH_BIN secret set EASYPANEL_SERVICE -R "$FULL_REPO" -b"$SERVICE_NAME" >/dev/null

echo "secrets-set"

# Provision EasyPanel prod service (image-based).
IMAGE="ghcr.io/${FULL_REPO}:main"

if ./scripts/easypanel.sh list-services "$EASYPANEL_PROJECT" | grep -qx "$SERVICE_NAME"; then
  ./scripts/easypanel.sh set-image "$SERVICE_NAME" "$IMAGE" "$EASYPANEL_PROJECT" >/dev/null
else
  ./scripts/easypanel.sh create-image-service "$SERVICE_NAME" "$IMAGE" "$EASYPANEL_PROJECT" "$PUBLISHED_PORT" "$TARGET_PORT" >/dev/null
fi

./scripts/easypanel.sh deploy-service "$SERVICE_NAME" "$EASYPANEL_PROJECT" >/dev/null || true

echo "easypanel-configured:http://${VPS_HOST}:${PUBLISHED_PORT}/"
echo "repo:${FULL_REPO}"
