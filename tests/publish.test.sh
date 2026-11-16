#!/usr/bin/env bash
# Tests scripts/publish.sh without Google Cloud: gcloud, docker, date and sleep are stubs, and
# the clock only moves when the script sleeps. Run: tests/publish.test.sh

set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/publish.sh"
failures=0

setup() {
  stub="$(mktemp -d)"
  echo 0 > "$stub/clock"
  : > "$stub/calls"
  export STUB_DIR="$stub" PATH="$stub/bin:$PATH"
  # How many token requests are refused before one succeeds.
  export STUB_REFUSE_TOKEN=0
  mkdir "$stub/bin"
  cat > "$stub/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls"
if [ "$1 $2" = "auth print-access-token" ]; then
  n=$(( $(cat "$STUB_DIR/token.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/token.count"
  if [ "$n" -le "$STUB_REFUSE_TOKEN" ]; then echo "ERROR: PERMISSION_DENIED iam.serviceAccounts.getAccessToken" >&2; exit 1; fi
  echo token
fi
EOF
  cat > "$stub/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_DIR/calls"
EOF
  cat > "$stub/bin/date" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_DIR/clock"
EOF
  cat > "$stub/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $1" >> "$STUB_DIR/calls"
echo $(( $(cat "$STUB_DIR/clock") + $1 )) > "$STUB_DIR/clock"
EOF
  chmod +x "$stub/bin/"*
  unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY
}

run() {
  out="$("$script" "$@" 2> "$stub/stderr")"
  status=$?
  err="$(cat "$stub/stderr")"
}

check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}

contains() { grep -qF -- "$2" <<< "$1"; }
count() { grep -cF -- "$2" <<< "$1" || true; }
calls() { cat "$stub/calls"; }

ready="This app is still being set up on Tiro: its deploy account is not ready yet. Retrying."
setup_url="https://ehr.tiro.health/platform/setup"
unlinked="This repository is not linked to a Tiro app, or the app is suspended. Link it on the EHR's setup page: $setup_url"
target="europe-west1-docker.pkg.dev/ehr-factory-apps/apps-notes/app:abc123"
deploy_args=(deploy --app notes --image "notes:abc123" --tag abc123)

test_check_app_empty() {
  setup
  GITHUB_ACTIONS=true GITHUB_OUTPUT="$stub/output" GITHUB_STEP_SUMMARY="$stub/summary" run check-app --app ""
  check "check-app empty: succeeds" [ "$status" -eq 0 ]
  check "check-app empty: a notice, not an error or warning" contains "$err" "::notice title=Not published%3A link this repository on Tiro::"
  check "check-app empty: points to the run summary" contains "$err" "See the run summary for the setup link."
  check "check-app empty: summary has a heading" grep -qx "### Not published yet" "$stub/summary"
  check "check-app empty: summary links the setup page" grep -qF "[EHR setup page]($setup_url)" "$stub/summary"
  check "check-app empty: links the setup page" contains "$err" "$setup_url"
  check "check-app empty: names the variable" contains "$err" "TIRO_EHR_APP_NAME"
  check "check-app empty: skips the publish steps" grep -qx "publish=false" "$stub/output"
  check "check-app empty: says so in the job summary" grep -qF "$setup_url" "$stub/summary"
  check "check-app empty: no gcloud call" [ ! -s "$stub/calls" ]
}

test_check_app_invalid() {
  setup
  GITHUB_OUTPUT="$stub/output" run check-app --app "REPLACE-WITH-YOUR-APP-NAME"
  check "check-app invalid: fails" [ "$status" -ne 0 ]
  check "check-app invalid: links the setup page" contains "$err" "$setup_url"
  check "check-app invalid: writes no output" [ ! -s "$stub/output" ]
  check "check-app invalid: no gcloud call" [ ! -s "$stub/calls" ]
}

test_check_app_valid() {
  setup
  GITHUB_OUTPUT="$stub/output" run check-app --app notes
  check "check-app valid: succeeds" [ "$status" -eq 0 ]
  check "check-app valid: runs the publish steps" grep -qx "publish=true" "$stub/output"
}

test_deploy_empty_app() {
  setup
  run deploy --app "" --image "notes:abc123" --tag abc123
  check "deploy without app: fails" [ "$status" -ne 0 ]
  check "deploy without app: names the setup page" contains "$err" "EHR's setup page"
  check "deploy without app: no gcloud call" [ ! -s "$stub/calls" ]
}

test_deploy() {
  setup
  GITHUB_STEP_SUMMARY="$stub/summary" run "${deploy_args[@]}"
  check "deploy: succeeds" [ "$status" -eq 0 ]
  check "deploy: no retry" [ "$(count "$err" "$ready")" -eq 0 ]
  check "deploy: pushes to the app's repository" contains "$(calls)" "docker push $target"
  check "deploy: replaces only the app container image" contains "$(calls)" \
    "gcloud run services update notes --region europe-west1 --project ehr-factory-apps --container app --image $target"
  check "deploy: writes the URL to the job summary" grep -qF "https://notes.tirohealth.app" "$stub/summary"
  check "deploy: prints the URL" [ "$out" = "https://notes.tirohealth.app" ]
}

test_retry_until_account_ready() {
  setup
  export STUB_REFUSE_TOKEN=3
  run "${deploy_args[@]}"
  check "retry: succeeds once the account can be used" [ "$status" -eq 0 ]
  check "retry: prints the setup message per retry" [ "$(count "$err" "$ready")" -eq 3 ]
  check "retry: backs off exponentially" \
    [ "$(grep '^sleep' "$stub/calls" | paste -sd ' ' -)" = "sleep 5 sleep 10 sleep 20" ]
  check "retry: pushes only after the account is ready" \
    [ "$(grep -n 'docker push' "$stub/calls" | cut -d: -f1)" -gt "$(grep -n 'print-access-token' "$stub/calls" | tail -n 1 | cut -d: -f1)" ]
}

test_account_never_ready_times_out() {
  setup
  export STUB_REFUSE_TOKEN=1000
  run "${deploy_args[@]}"
  check "timeout: fails" [ "$status" -ne 0 ]
  check "timeout: ends with the not-linked message" [ "$(tail -n 1 <<< "$err")" = "$unlinked" ]
  check "timeout: gives up after 10 minutes" [ "$(cat "$stub/clock")" -eq 600 ]
  check "timeout: delay capped at 60s" \
    [ "$(grep '^sleep' "$stub/calls" | sort -t' ' -k2 -n | tail -n 1)" = "sleep 60" ]
  check "timeout: never pushes or rolls" [ "$(count "$(calls)" "docker push")$(count "$(calls)" "services update")" = "00" ]
  check "timeout: prints nothing on stdout" [ -z "$out" ]
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done

if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
