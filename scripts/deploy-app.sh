#!/usr/bin/env bash
# Pull + (re)start a single app stack. Watchtower already does this
# automatically for services running a mutable tag (:latest), so this
# script is mainly for: first deploy, manually rolling to a pinned
# :vX.Y.Z tag after editing the app's .env, or forcing a redeploy without
# waiting for Watchtower's poll interval.
#
# Usage: scripts/deploy-app.sh book-reservation
#        scripts/deploy-app.sh --list

set -euo pipefail

# Resolve the repo root from this script's own location rather than trusting
# $PWD — otherwise the relative apps/<app>/ path below only works when the
# script happens to be invoked from the repo root.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

list_apps() {
  # _template is scaffolding, not a deployable stack.
  find "${repo_root}/apps" -mindepth 1 -maxdepth 1 -type d ! -name '_template' \
    -printf '  %f\n' 2>/dev/null | sort
}

if [[ "${1:-}" == "--list" ]]; then
  echo "Deployable apps:"
  list_apps
  exit 0
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <app-name>   (a folder under apps/)" >&2
  echo "Deployable apps:" >&2
  list_apps >&2
  exit 1
fi

app="$1"
app_dir="${repo_root}/apps/${app}"
compose_file="${app_dir}/docker-compose.yml"

if [[ "$app" == "_template" ]]; then
  echo "error: _template is scaffolding for new apps, not a deployable stack." >&2
  echo "       Copy it to apps/<new-app>/ first (see CLAUDE.md)." >&2
  exit 1
fi

if [[ ! -f "$compose_file" ]]; then
  echo "error: $compose_file not found" >&2
  echo "Deployable apps:" >&2
  list_apps >&2
  exit 1
fi

# Every app stack reads its own .env (compose only auto-loads the one next to
# the file it's given). Missing it means ${DOMAIN} and friends silently expand
# to empty strings and the container comes up misrouted — fail loudly instead.
if [[ ! -f "${app_dir}/.env" ]]; then
  echo "error: ${app_dir}/.env not found — copy .env.example and fill it in:" >&2
  echo "       cp apps/${app}/.env.example apps/${app}/.env" >&2
  exit 1
fi

echo "==> Pulling latest image for ${app}"
docker compose -f "$compose_file" pull

echo "==> Recreating ${app}"
docker compose -f "$compose_file" up -d --force-recreate

echo "==> Done. Recent logs:"
docker compose -f "$compose_file" logs --tail=20
