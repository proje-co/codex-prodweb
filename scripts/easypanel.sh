#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $0 list-projects
  $0 list-services [project]
  $0 inspect-service <service> [project]

  $0 create-image-service <service> <image> [project]
  $0 create-upload-service <service> [project] [published_port] [target_port]
  $0 upload-archive <service> <archive_path> [project]
  $0 set-image <service> <image> [project]
  $0 set-env-file <service> <env_file> [project]
  $0 deploy-service <service> [project]
  $0 start-service <service> [project]
  $0 stop-service <service> [project]
  $0 restart-service <service> [project]
  $0 destroy-service <service> [project] --yes

Config:
- Reads .deploy.env and .secrets.env
- Uses EASYPANEL_URL (no trailing slash preferred)
- Uses EASYPANEL_PROJECT as default project when not provided

Safety:
- Any create/deploy/start/stop/restart operation enforces PROJECT_PREFIX (example: codex-*)
USAGE
}

need_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "Missing $f"
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
: "${PROJECT_PREFIX:?Missing PROJECT_PREFIX in .deploy.env}"

BASE_URL="${EASYPANEL_URL%/}"
DEFAULT_PROJECT="${EASYPANEL_PROJECT:-}"
AUTH_HEADER=( -H "Authorization: Bearer ${EASYPANEL_API_KEY}" )

require_prefix() {
  local name="$1"
  if [[ "$name" != ${PROJECT_PREFIX}-* ]]; then
    echo "Refusing operation. Name must start with '${PROJECT_PREFIX}-'"
    exit 1
  fi
}

require_project() {
  local p="$1"
  if [[ -z "$p" ]]; then
    echo "Missing project. Set EASYPANEL_PROJECT in .deploy.env or pass [project]"
    exit 1
  fi
}

ep_get() {
  local path="$1"
  curl -sS "${AUTH_HEADER[@]}" "${BASE_URL}${path}"
}

ep_post() {
  local path="$1"
  local data="$2"
  curl -sS "${AUTH_HEADER[@]}" -H 'Content-Type: application/json' -X POST "${BASE_URL}${path}" --data "$data"
}

json_urlencode() {
  ruby -ruri -e 'print URI.encode_www_form_component(ARGF.read)'
}

extract_trpc_error_message() {
  # Print a best-effort error message to stderr, return 0 if error else 1.
  ruby -rjson -e '
    begin
      d = JSON.parse(STDIN.read)
    rescue
      exit 2
    end
    if d["error"]
      msg = d.dig("error","json","message") || d.dig("error","message") || d["error"].to_s
      warn msg
      exit 0
    end
    exit 1
  '
}

trpc_post_or_die() {
  local path="$1"
  local payload="$2"

  local resp
  resp=$(ep_post "$path" "$payload")

  if echo "$resp" | extract_trpc_error_message >/dev/null; then
    exit 1
  fi

  echo "$resp" >/dev/null
}

cmd="${1:-}"
shift || true

case "$cmd" in
  list-projects)
    ep_get "/api/trpc/projects.listProjects" |
      ruby -rjson -e 'd=JSON.parse(STDIN.read); (d.dig("result","data","json")||[]).each{|p| puts p["name"]}'
    ;;

  list-services)
    project="${1:-$DEFAULT_PROJECT}"
    require_project "$project"

    input_json=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0]}})' "$project")
    input_enc=$(printf '%s' "$input_json" | json_urlencode)

    ep_get "/api/trpc/projects.inspectProject?input=${input_enc}" |
      ruby -rjson -e 'd=JSON.parse(STDIN.read); (d.dig("result","data","json","services")||[]).map{|s| s["name"]}.uniq.sort.each{|n| puts n}'
    ;;

	  inspect-service)
	    service="${1:-}"
	    project="${2:-$DEFAULT_PROJECT}"

    if [[ -z "$service" ]]; then
      usage
      exit 1
    fi
    require_project "$project"

    input_json=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1]}})' "$project" "$service")
    input_enc=$(printf '%s' "$input_json" | json_urlencode)

	    ep_get "/api/trpc/services.app.inspectService?input=${input_enc}" |
	      ruby -rjson -e '
	        d=JSON.parse(STDIN.read)
	        j=d.dig("result","data","json") || {}
	        # Avoid leaking deploy tokens or env secrets in default output.
	        redacted = j.dup
	        redacted.delete("token")
	        redacted.delete("deploymentUrl")
	        redacted["env"] = "<redacted>" if redacted.key?("env")
	        puts JSON.pretty_generate(redacted)
	      '
	    ;;

  create-image-service)
    service="${1:-}"
    image="${2:-}"
    project="${3:-$DEFAULT_PROJECT}"
    published_port="${4:-}"
    target_port="${5:-}"

    if [[ -z "$service" || -z "$image" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    # Conservative resource defaults to avoid overcommitting.
    payload=$(ruby -rjson -e '
      project, service, image, published, target = ARGV
      ports = []
      if published && !published.empty?
        ports << { published: published.to_i, target: (target && !target.empty? ? target.to_i : 80) }
      end
      body = {
        json: {
          projectName: project,
          serviceName: service,
          source: { type: "image", image: image },
          domains: [],
          ports: ports,
          mounts: [],
          resources: {
            memoryReservation: 128,
            memoryLimit: 512,
            cpuReservation: 0.1,
            cpuLimit: 1
          }
        }
      }
      puts JSON.dump(body)
    ' "$project" "$service" "$image" "$published_port" "$target_port")

    trpc_post_or_die "/api/trpc/services.app.createService" "$payload"
    echo "created"
    ;;

  create-upload-service)
    service="${1:-}"
    project="${2:-$DEFAULT_PROJECT}"
    published_port="${3:-}"
    target_port="${4:-}"

    if [[ -z "$service" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    # Upload-based development flow:
    # 1) create service with source=upload + build=dockerfile
    # 2) copy tar.gz to VPS under /etc/easypanel/codex-archives/<service>.tar.gz
    # 3) call upload-archive then deploy-service
    payload=$(ruby -rjson -e '
      project, service, published, target = ARGV
      ports = []
      if published && !published.empty?
        ports << { published: published.to_i, target: (target && !target.empty? ? target.to_i : 80) }
      end
      body = {
        json: {
          projectName: project,
          serviceName: service,
          source: { type: "upload" },
          build: { type: "dockerfile", file: "Dockerfile" },
          domains: [],
          ports: ports,
          mounts: [],
          resources: {
            memoryReservation: 128,
            memoryLimit: 512,
            cpuReservation: 0.1,
            cpuLimit: 1
          }
        }
      }
      puts JSON.dump(body)
    ' "$project" "$service" "$published_port" "$target_port")

    trpc_post_or_die "/api/trpc/services.app.createService" "$payload"
    echo "created"
    ;;

  upload-archive)
    service="${1:-}"
    archive_path="${2:-}"
    project="${3:-$DEFAULT_PROJECT}"

    if [[ -z "$service" || -z "$archive_path" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1], archivePath: ARGV[2]}})' "$project" "$service" "$archive_path")
    trpc_post_or_die "/api/trpc/services.app.uploadCodeArchive" "$payload"
    echo "ok"
    ;;

  set-image)
    service="${1:-}"
    image="${2:-}"
    project="${3:-$DEFAULT_PROJECT}"

    if [[ -z "$service" || -z "$image" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1], image: ARGV[2]}})' "$project" "$service" "$image")
    trpc_post_or_die "/api/trpc/services.app.updateSourceImage" "$payload"
    echo "ok"
    ;;

  set-env-file)
    service="${1:-}"
    env_file="${2:-}"
    project="${3:-$DEFAULT_PROJECT}"

    if [[ -z "$service" || -z "$env_file" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    if [[ ! -f "$env_file" ]]; then
      echo "Env file not found: $env_file"
      exit 1
    fi

    # EasyPanel expects a single string with KEY=VALUE lines.
    payload=$(ruby -rjson -e '
      project, service, path = ARGV
      env = File.read(path)
      puts JSON.dump({json:{projectName: project, serviceName: service, env: env, createDotEnv: false}})
    ' "$project" "$service" "$env_file")

    trpc_post_or_die "/api/trpc/services.app.updateEnv" "$payload"
    echo "ok"
    ;;

  deploy-service)
    service="${1:-}"
    project="${2:-$DEFAULT_PROJECT}"

    if [[ -z "$service" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1], forceRebuild: false}})' "$project" "$service")

    # Right after creation, deploy endpoint may briefly return "Not found.".
    for _ in $(seq 1 10); do
      resp=$(ep_post "/api/trpc/services.app.deployService" "$payload")
      if echo "$resp" | extract_trpc_error_message >/dev/null; then
        # If it's the transient case, retry.
        if echo "$resp" | grep -qi 'Not found'; then
          sleep 2
          continue
        fi
        exit 1
      fi
      echo "deploy-triggered"
      exit 0
    done

    echo "Deploy failed after retries" >&2
    exit 1
    ;;

  start-service|stop-service|restart-service)
    action="$cmd"
    service="${1:-}"
    project="${2:-$DEFAULT_PROJECT}"

    if [[ -z "$service" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"

    endpoint="/api/trpc/services.app.${action#*-Service}"
    # The endpoint names are startService/stopService/restartService.
    case "$action" in
      start-service) endpoint="/api/trpc/services.app.startService";;
      stop-service) endpoint="/api/trpc/services.app.stopService";;
      restart-service) endpoint="/api/trpc/services.app.restartService";;
    esac

    payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1]}})' "$project" "$service")
    trpc_post_or_die "$endpoint" "$payload"
    echo "ok"
    ;;

  destroy-service)
    service="${1:-}"
    project="${2:-$DEFAULT_PROJECT}"
    confirm="${3:-}"

    if [[ -z "$service" ]]; then
      usage
      exit 1
    fi
    require_project "$project"
    require_prefix "$service"
    if [[ "$confirm" != "--yes" ]]; then
      echo "Refusing destroy without --yes"
      exit 1
    fi

    payload=$(ruby -rjson -e 'puts JSON.dump({json:{projectName: ARGV[0], serviceName: ARGV[1]}})' "$project" "$service")
    trpc_post_or_die "/api/trpc/services.app.destroyService" "$payload"
    echo "ok"
    ;;

  ""|-h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd"
    usage
    exit 1
    ;;
esac
