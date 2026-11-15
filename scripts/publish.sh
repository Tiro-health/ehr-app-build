#!/usr/bin/env bash
# Publishes an app image to tirohealth.app. The publish job in .github/workflows/build.yml
# always takes this script from the v2 tag, never from a ref the caller chooses, because it
# runs with the app's deploy identity.
#
#   scripts/publish.sh check-app --app <name>
#     Before signing in: fails at once when the caller passed no (or an invalid) app name.
#
#   scripts/publish.sh deploy --app <name> --image <local ref> --tag <tag>
#     Signed in (google-github-actions/auth) as the app's deploy account deploy-<app>. Waits
#     until that account can be used: while the impersonation is refused (the account or its
#     binding to this repository does not exist yet, or the app is suspended) it retries with
#     exponential backoff for at most PUBLISH_TIMEOUT_SECONDS (default 600). Then pushes the
#     image to the app's repository and rolls a new revision that replaces only the `app`
#     container's image; the smart-sidecar container is left as it is. Prints the deploy URL
#     and writes it to $GITHUB_STEP_SUMMARY.
#
# Needs gcloud and docker. Progress goes to stderr.

set -euo pipefail

PROJECT="ehr-factory-apps"
REGION="europe-west1"
REGISTRY="$REGION-docker.pkg.dev"
TIMEOUT="${PUBLISH_TIMEOUT_SECONDS:-600}"
INITIAL_DELAY="${PUBLISH_INITIAL_DELAY_SECONDS:-5}"
MAX_DELAY="${PUBLISH_MAX_DELAY_SECONDS:-60}"

NOT_READY="This app is still being set up on Tiro: its deploy account is not ready yet. Retrying."
NOT_LINKED="This repository is not linked to a Tiro app, or the app is suspended. Link it on the EHR's setup page."
NO_APP="No Tiro app given. Set the workflow input \`app\` to your app's name, as shown on the EHR's setup page, where you also link this repository to it."

log() { echo "$@" >&2; }
fail() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*" >&2; else echo "$*" >&2; fi
  exit 1
}
valid_app() { [[ "$1" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; }

check_app() {
  [ -n "$1" ] || fail "$NO_APP"
  valid_app "$1" || fail "The app name '$1' is not valid: use the name shown on the EHR's setup page."
}

# The active credential impersonates deploy-<app>; minting a token is what fails while the
# account or its binding is missing.
wait_for_account() {
  local deadline delay now wait
  deadline=$(( $(date +%s) + TIMEOUT ))
  delay="$INITIAL_DELAY"
  until gcloud auth print-access-token >/dev/null 2>&1; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then fail "$NOT_LINKED"; fi
    log "$NOT_READY"
    wait=$(( deadline - now < delay ? deadline - now : delay ))
    sleep "$wait"
    delay=$(( delay * 2 > MAX_DELAY ? MAX_DELAY : delay * 2 ))
  done
}

deploy() {
  local app="" image="" tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app="${2-}"; shift 2 ;;
      --image) image="${2:?--image needs a value}"; shift 2 ;;
      --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$image" ] && [ -n "$tag" ] || { echo "deploy needs --app, --image and --tag" >&2; exit 2; }
  check_app "$app"
  wait_for_account

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

check_app_command() {
  local app=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app="${2-}"; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  check_app "$app"
}

case "${1:-}" in
  check-app) shift; check_app_command "$@" ;;
  deploy) shift; deploy "$@" ;;
  *) echo "Usage: $0 check-app|deploy ..." >&2; exit 2 ;;
esac
