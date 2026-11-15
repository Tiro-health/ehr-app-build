#!/usr/bin/env bash
# Publishes an app image to tirohealth.app. The publish job in .github/workflows/build.yml
# runs it in two steps, re-authenticating with Google Cloud in between:
#
#   scripts/publish.sh find-app --repository-id <id> [--app <name>]
#     Authenticated as the repository itself (direct workload identity). Finds the Cloud Run
#     service labelled tiro-repository-id=<id>, or takes --app, and waits until the app's
#     deploy account deploy-<app> can be impersonated. While either is missing it retries with
#     exponential backoff, for at most PUBLISH_TIMEOUT_SECONDS (default 600). Prints the app
#     name on stdout and writes app=<name> to $GITHUB_OUTPUT.
#
#   scripts/publish.sh deploy --app <name> --image <local ref> --tag <tag>
#     Authenticated as deploy-<app>. Pushes the image to the app's repository and rolls a new
#     revision that replaces only the `app` container's image; the smart-sidecar container is
#     left as it is. Prints the deploy URL and writes it to $GITHUB_STEP_SUMMARY.
#
# Needs gcloud (and docker for deploy). Progress goes to stderr.

set -euo pipefail

PROJECT="ehr-factory-apps"
REGION="europe-west1"
REGISTRY="$REGION-docker.pkg.dev"
TIMEOUT="${PUBLISH_TIMEOUT_SECONDS:-600}"
INITIAL_DELAY="${PUBLISH_INITIAL_DELAY_SECONDS:-5}"
MAX_DELAY="${PUBLISH_MAX_DELAY_SECONDS:-60}"

NOT_READY="This app is still being set up on Tiro: its deploy account is not ready yet. Retrying."
NOT_LINKED="This repository is not linked to a Tiro app, or the app is suspended. Link it on the EHR's setup page."

log() { echo "$@" >&2; }
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*" >&2; else echo "$*" >&2; fi
  exit 1
}
deploy_account() { echo "deploy-$1@$PROJECT.iam.gserviceaccount.com"; }

valid_app() { [[ "$1" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; }

# Sets `app` and returns 0 on exactly one match, returns 1 on none, exits on several.
lookup_app() {
  local repository_id="$1" names count
  names="$(gcloud run services list \
    --project "$PROJECT" --region "$REGION" \
    --filter "metadata.labels.tiro-repository-id=$repository_id" \
    --format "value(metadata.name)")" || fail "Could not list the Tiro apps (gcloud run services list failed)."
  names="$(printf '%s\n' "$names" | sed '/^[[:space:]]*$/d')"
  count="$(printf '%s' "$names" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then return 1; fi
  if [ "$count" -gt 1 ]; then
    fail "This repository is linked to more than one Tiro app ($(echo "$names" | paste -sd ',' - | sed 's/,/, /g')). Pass the one to deploy as the workflow input \`app\`."
  fi
  app="$names"
  valid_app "$app" || fail "The Tiro app name '$app' is not valid."
}

can_impersonate() {
  gcloud auth print-access-token --impersonate-service-account "$(deploy_account "$1")" >/dev/null 2>&1
}

find_app() {
  local repository_id="" app=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repository-id) repository_id="${2:?--repository-id needs a value}"; shift 2 ;;
      --app) app="${2-}"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$app" ] || [ -n "$repository_id" ] || { echo "find-app needs --repository-id or --app" >&2; exit 2; }
  if [ -n "$app" ]; then valid_app "$app" || fail "The app name '$app' is not valid."; fi

  local given="$app" deadline delay now wait
  deadline=$(( $(date +%s) + TIMEOUT ))
  delay="$INITIAL_DELAY"
  while :; do
    if [ -z "$given" ]; then app=""; lookup_app "$repository_id" || true; fi
    if [ -n "$app" ] && can_impersonate "$app"; then break; fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then fail "$NOT_LINKED"; fi
    log "$NOT_READY"
    wait=$(( deadline - now < delay ? deadline - now : delay ))
    sleep "$wait"
    delay=$(( delay * 2 > MAX_DELAY ? MAX_DELAY : delay * 2 ))
  done

  log "Deploying as $(deploy_account "$app")"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "app=$app" >> "$GITHUB_OUTPUT"; fi
  echo "$app"
}

deploy() {
  local app="" image="" tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app="${2:?--app needs a value}"; shift 2 ;;
      --image) image="${2:?--image needs a value}"; shift 2 ;;
      --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$app" ] && [ -n "$image" ] && [ -n "$tag" ] || { echo "deploy needs --app, --image and --tag" >&2; exit 2; }
  valid_app "$app" || fail "The app name '$app' is not valid."

  local target="$REGISTRY/$PROJECT/apps-$app/app:$tag"
  gcloud auth configure-docker "$REGISTRY" --quiet >&2
  docker tag "$image" "$target"
  docker push "$target" >&2
  gcloud run services update "$app" \
    --region "$REGION" --project "$PROJECT" \
    --container app --image "$target" >&2

  local url="https://$app.tirohealth.app"
  log "Deployed $target to $url"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # shellcheck disable=SC2016 # literal backticks: Markdown code span
    printf '### Deployed to Tiro\n\n%s\n\nImage: `%s`\n' "$url" "$target" >> "$GITHUB_STEP_SUMMARY"
  fi
  echo "$url"
}

case "${1:-}" in
  find-app) shift; find_app "$@" ;;
  deploy) shift; deploy "$@" ;;
  *) echo "Usage: $0 find-app|deploy ..." >&2; exit 2 ;;
esac
