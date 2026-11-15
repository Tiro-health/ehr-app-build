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
  # Stub knobs: list output per call (list.1, list.2, ...; list.default after), list errors
  # (list.<n>.err, list.err.default), and how many
  # impersonation attempts are refused before one succeeds.
  export STUB_REFUSE_IMPERSONATION=0
  mkdir "$stub/bin"
  cat > "$stub/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls"
case "$1 $2" in
  "run services")
    if [ "$3" = list ]; then
      n=$(( $(cat "$STUB_DIR/list.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/list.count"
      # list.<n>.err / list.err.default: print it to stderr and fail instead.
      for f in "$STUB_DIR/list.$n.err" "$STUB_DIR/list.err.default"; do
        if [ -f "$f" ]; then cat "$f" >&2; exit 1; fi
      done
      if [ -f "$STUB_DIR/list.$n" ]; then cat "$STUB_DIR/list.$n"; else cat "$STUB_DIR/list.default" 2>/dev/null; fi
    fi ;;
  "auth print-access-token")
    n=$(( $(cat "$STUB_DIR/token.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/token.count"
    if [ "$n" -le "$STUB_REFUSE_IMPERSONATION" ]; then echo "PERMISSION_DENIED" >&2; exit 1; fi
    echo token ;;
esac
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

ready="This app is still being set up on Tiro: its deploy account is not ready yet. Retrying."
unlinked="This repository is not linked to a Tiro app, or the app is suspended. Link it on the EHR's setup page."

test_one_match() {
  setup
  echo "notes" > "$stub/list.default"
  GITHUB_OUTPUT="$stub/output" run find-app --repository-id 42
  check "one match: succeeds" [ "$status" -eq 0 ]
  check "one match: prints the app" [ "$out" = notes ]
  check "one match: writes app to GITHUB_OUTPUT" grep -qx "app=notes" "$stub/output"
  check "one match: filters on the repository id" \
    contains "$(cat "$stub/calls")" "--filter metadata.labels.tiro-repository-id=42"
  check "one match: probes the deploy account" \
    contains "$(cat "$stub/calls")" "--impersonate-service-account deploy-notes@ehr-factory-apps.iam.gserviceaccount.com"
  check "one match: no retry" [ "$(count "$err" "$ready")" -eq 0 ]
}

test_retry_until_found() {
  setup
  : > "$stub/list.1"; : > "$stub/list.2"
  echo "notes" > "$stub/list.default"
  run find-app --repository-id 42
  check "retry: succeeds once the service appears" [ "$status" -eq 0 ]
  check "retry: prints the app" [ "$out" = notes ]
  check "retry: prints the setup message per retry" [ "$(count "$err" "$ready")" -eq 2 ]
  check "retry: backs off exponentially" \
    [ "$(grep '^sleep' "$stub/calls" | paste -sd ' ' -)" = "sleep 5 sleep 10" ]
}

test_retry_impersonation_refused() {
  setup
  echo "notes" > "$stub/list.default"
  export STUB_REFUSE_IMPERSONATION=3
  run find-app --repository-id 42
  check "refused: succeeds once the binding exists" [ "$status" -eq 0 ]
  check "refused: retried three times" [ "$(count "$err" "$ready")" -eq 3 ]
}

test_zero_matches_times_out() {
  setup
  : > "$stub/list.default"
  run find-app --repository-id 42
  check "zero matches: fails" [ "$status" -ne 0 ]
  check "zero matches: ends with the not-linked message" [ "$(tail -n 1 <<< "$err")" = "$unlinked" ]
  check "zero matches: gives up after 10 minutes" [ "$(cat "$stub/clock")" -eq 600 ]
  check "zero matches: delay capped at 60s" [ "$(grep '^sleep' "$stub/calls" | sort -t' ' -k2 -n | tail -n 1)" = "sleep 60" ]
  check "zero matches: never impersonates" [ "$(count "$(cat "$stub/calls")" "print-access-token")" -eq 0 ]
  check "zero matches: prints nothing on stdout" [ -z "$out" ]
}

test_impersonation_never_allowed_times_out() {
  setup
  echo "notes" > "$stub/list.default"
  export STUB_REFUSE_IMPERSONATION=1000
  run find-app --repository-id 42
  check "never allowed: fails with the not-linked message" [ "$(tail -n 1 <<< "$err")" = "$unlinked" ]
  check "never allowed: gives up after 10 minutes" [ "$(cat "$stub/clock")" -eq 600 ]
}

denied="ERROR: (gcloud.run.services.list) PERMISSION_DENIED: Permission 'run.services.list' denied on resource"

test_permission_denied_then_found() {
  setup
  echo "$denied" > "$stub/list.1.err"
  echo "ERROR: (gcloud.run.services.list) HTTPError 403: Forbidden" > "$stub/list.2.err"
  echo "notes" > "$stub/list.default"
  run find-app --repository-id 42
  check "denied: succeeds once the list is allowed" [ "$status" -eq 0 ]
  check "denied: prints the app" [ "$out" = notes ]
  check "denied: retried with the setup message (PERMISSION_DENIED and 403)" [ "$(count "$err" "$ready")" -eq 2 ]
  check "denied: same backoff" [ "$(grep '^sleep' "$stub/calls" | paste -sd ' ' -)" = "sleep 5 sleep 10" ]
  check "denied: gcloud's error not shown" [ "$(count "$err" "PERMISSION_DENIED")" -eq 0 ]
}

test_permission_denied_times_out() {
  setup
  echo "$denied" > "$stub/list.err.default"
  run find-app --repository-id 42
  check "always denied: fails" [ "$status" -ne 0 ]
  check "always denied: ends with the not-linked message" [ "$(tail -n 1 <<< "$err")" = "$unlinked" ]
  check "always denied: gives up after 10 minutes" [ "$(cat "$stub/clock")" -eq 600 ]
}

test_other_list_error_fails_at_once() {
  setup
  echo "ERROR: (gcloud.run.services.list) There was a problem refreshing your current auth tokens" > "$stub/list.err.default"
  run find-app --repository-id 42
  check "other list error: fails" [ "$status" -ne 0 ]
  check "other list error: no retry" [ "$(count "$err" "$ready")" -eq 0 ]
  check "other list error: no sleep" [ "$(grep -c '^sleep' "$stub/calls")" -eq 0 ]
  check "other list error: shows gcloud's error" contains "$err" "problem refreshing"
  check "other list error: says the list failed" contains "$err" "Could not list the Tiro apps"
  check "other list error: no not-linked message" [ "$(count "$err" "$unlinked")" -eq 0 ]
}

test_two_matches() {
  setup
  printf 'notes\nnotes-old\n' > "$stub/list.default"
  run find-app --repository-id 42
  check "two matches: fails" [ "$status" -ne 0 ]
  check "two matches: names both apps" contains "$err" "(notes, notes-old)"
  check "two matches: does not retry" [ "$(count "$err" "$ready")" -eq 0 ]
  check "two matches: no not-linked message" [ "$(count "$err" "$unlinked")" -eq 0 ]
}

test_app_input_skips_lookup() {
  setup
  run find-app --repository-id 42 --app notes
  check "app input: succeeds" [ "$out" = notes ]
  check "app input: no lookup" [ "$(count "$(cat "$stub/calls")" "services list")" -eq 0 ]
}

test_invalid_app_input() {
  setup
  run find-app --app "Bad_Name"
  check "invalid app input: fails" [ "$status" -ne 0 ]
  check "invalid app input: no gcloud call" [ ! -s "$stub/calls" ]
}

test_deploy() {
  setup
  GITHUB_STEP_SUMMARY="$stub/summary" run deploy --app notes --image "notes:abc123" --tag abc123
  local target="europe-west1-docker.pkg.dev/ehr-factory-apps/apps-notes/app:abc123"
  check "deploy: succeeds" [ "$status" -eq 0 ]
  check "deploy: pushes to the app's repository" contains "$(cat "$stub/calls")" "docker push $target"
  check "deploy: replaces only the app container image" contains "$(cat "$stub/calls")" \
    "gcloud run services update notes --region europe-west1 --project ehr-factory-apps --container app --image $target"
  check "deploy: writes the URL to the job summary" grep -qF "https://notes.tirohealth.app" "$stub/summary"
  check "deploy: prints the URL" [ "$out" = "https://notes.tirohealth.app" ]
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done

if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
