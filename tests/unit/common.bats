#!/usr/bin/env bats
# Tests for lib/common.sh

# Globals set here are read by the sourced libraries.
# Each @test runs in its own subshell by design (SC2030/SC2031).
# shellcheck disable=SC2034,SC2030,SC2031

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  aai_test_setup
}

@test "redact: masks KEY=value secrets" {
  run aai_redact_str "SECRET_KEY=abc123 DB_PASSWORD: hunter2 other=visible"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRET_KEY=***"* ]]
  [[ "$output" == *"DB_PASSWORD: ***"* ]]
  [[ "$output" == *"other=visible"* ]]
  [[ "$output" != *abc123* && "$output" != *hunter2* ]]
}

@test "redact: masks long hex strings and bearer tokens" {
  local hex
  hex=$(printf 'a%.0s' {1..64})
  run aai_redact_str "value $hex and Authorization: Bearer tok.en-123"
  [[ "$output" != *"$hex"* ]]
  [[ "$output" != *"tok.en-123"* ]]
}

@test "redact: leaves ordinary Romanian text alone" {
  run aai_redact_str "Instalez Docker Engine și Compose v2"
  [ "$output" = "Instalez Docker Engine și Compose v2" ]
}

@test "log_init: dry-run creates nothing on disk" {
  AAI_DRY_RUN=1
  aai_log_init
  [ "$AAI_LOG_ENABLED" -eq 0 ]
  [ ! -e "$AAI_LOG_DIR" ]
}

@test "log_init: creates log with restricted permissions and redacts" {
  aai_log_init
  [ -f "$AAI_LOG_FILE" ]
  [ "$(stat -c %a "$AAI_LOG_FILE")" = 640 ]
  [ "$(stat -c %a "$AAI_LOG_DIR")" = 750 ]
  aai_info "parola: REDIS_PASSWORD=supersecret" >/dev/null
  grep -q 'REDIS_PASSWORD=\*\*\*' "$AAI_LOG_FILE"
  run ! grep -q supersecret "$AAI_LOG_FILE"
}

@test "run: dry-run prints the command and does not execute it" {
  AAI_DRY_RUN=1
  run aai_run touch "${BATS_TEST_TMPDIR}/created"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"*"touch"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/created" ]
}

@test "run: executes and returns the command's exit code" {
  aai_log_init
  run aai_run bash -c 'echo out; exit 7'
  [ "$status" -eq 7 ]
  grep -q '^out$' "$AAI_LOG_FILE"
}

@test "run_secret: never shows the arguments" {
  AAI_DRY_RUN=1
  run aai_run_secret "setez parola" echo my-secret-arg
  [[ "$output" == *"setez parola"* ]]
  [[ "$output" != *my-secret-arg* ]]
}

@test "retry: succeeds after transient failures" {
  local counter="${BATS_TEST_TMPDIR}/n"
  echo 0 >"$counter"
  flaky() { local n; n=$(($(cat "$counter") + 1)); echo "$n" >"$counter"; ((n >= 3)); }
  run aai_retry 3 0 flaky
  [ "$status" -eq 0 ]
  [ "$(cat "$counter")" -eq 3 ]
}

@test "retry: fails after the last attempt" {
  run aai_retry 2 0 false
  [ "$status" -eq 1 ]
  [[ "$output" == *"Încercarea 1/2 a eșuat"* ]]
}

@test "confirm: non-interactive uses the default" {
  AAI_NON_INTERACTIVE=1
  aai_confirm "Continuăm?" y
  run ! aai_confirm "Continuăm?" n
}

@test "die: prints cause and action, exits with given code" {
  run aai_die "Ceva a eșuat." "Faceți X." 4
  [ "$status" -eq 4 ]
  [[ "$output" == *"[EROARE] Ceva a eșuat."* ]]
  [[ "$output" == *"Ce trebuie făcut: Faceți X."* ]]
}

@test "summary: counts statuses and rejects unknown ones" {
  aai_summary_add OK P0 "totul bine"
  aai_summary_add AVERTISMENT P1 "atenție" "verificați"
  aai_summary_add EROARE P2 "eșec" "reparați"
  run aai_summary_add GRESIT P3 "x"
  [ "$status" -eq 2 ]
  [ "$(aai_summary_count OK)" -eq 1 ]
  [ "$(aai_summary_count EROARE)" -eq 1 ]
  aai_summary_has_errors
  run aai_summary_print
  [[ "$output" == *"OK: 1 · AVERTISMENT: 1 · EROARE: 1"* ]]
  [[ "$output" == *"→ reparați"* ]]
}

@test "summary: no errors when empty" {
  run ! aai_summary_has_errors
}
