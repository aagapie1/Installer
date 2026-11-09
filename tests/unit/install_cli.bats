#!/usr/bin/env bats
# Tests for install.sh argument handling, stage selection and --dry-run.

# Globals set here are read by the sourced libraries.
# shellcheck disable=SC2034

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  aai_test_setup
  EXAMPLE="${AAI_ROOT}/config/client.example.yaml"
}

@test "stage: normalize names and codes" {
  [ "$(aai_stage_normalize P0)" = preflight ]
  [ "$(aai_stage_normalize p3)" = dify ]
  [ "$(aai_stage_normalize Hardening)" = hardening ]
  run aai_stage_normalize P9
  [ "$status" -eq 1 ]
}

@test "stage: select with --only and --skip keeps install order" {
  run aai_stage_select "P3,preflight" ""
  [ "$output" = $'preflight\ndify' ]
  run aai_stage_select "" "P1, P2,P3,P4,P5,P6,P7"
  [ "$output" = preflight ]
  run aai_stage_select "" ""
  [ "$(wc -l <<<"$output")" -eq 8 ]
  run aai_stage_select "P8" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"Etapă necunoscută"* ]]
}

@test "cli: --help exits 0 and is in Romanian" {
  run "${AAI_ROOT}/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Utilizare"* && "$output" == *"--dry-run"* ]]
}

@test "cli: missing --config is a usage error" {
  run "${AAI_ROOT}/install.sh" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"Lipsește --config"* ]]
}

@test "cli: unknown option is a usage error" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --bogus
  [ "$status" -eq 2 ]
}

@test "cli: --dry-run shows config and plan, writes no log" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --dry-run --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mod simulare"* ]]
  [[ "$output" == *"Primăria Municipiului Buzău"* ]]
  [[ "$output" == *"P0 — Verificări preliminare"* ]]
  [[ "$output" == *"P7 — Raportul final"* ]]
  [ ! -e "$AAI_LOG_DIR" ]
  [ ! -e "$AAI_LOCK_FILE" ]
}

@test "cli: --only limits the stages run" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --dry-run --only P0 --only=P2
  [ "$status" -eq 0 ]
  [[ "$output" == *"P0 — "* && "$output" == *"P2 — "* ]]
  [[ "$output" != *"P1 — "* && "$output" != *"P3 — "* ]]
}

@test "cli: --skip everything is a usage error" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --dry-run --skip P0,P1,P2,P3,P4,P5,P6,P7
  [ "$status" -eq 2 ]
}

@test "cli: --set overrides config values" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --dry-run --only P0 --set inference.profile=cpu
  [ "$status" -eq 0 ]
  [[ "$output" == *"profil: cpu"* ]]
}

@test "cli: --set with unknown key fails with code 2" {
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --dry-run --set foo=bar
  [ "$status" -eq 2 ]
  [[ "$output" == *"necunoscută"* ]]
}

@test "cli: invalid config stops with an error" {
  local cfg="${BATS_TEST_TMPDIR}/c.yaml"
  write_config "$cfg" 's/profile: "auto"/profile: "tpu"/'
  run "${AAI_ROOT}/install.sh" --config "$cfg" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Configurarea are erori"* ]]
}

@test "cli: real run (non dry-run) writes the log file" {
  [ "$EUID" -eq 0 ] || skip "necesită root"
  run "${AAI_ROOT}/install.sh" --config "$EXAMPLE" --only P0 --non-interactive
  [ "$status" -eq 0 ]
  [ -f "$AAI_LOG_FILE" ]
  grep -q "SUMMARY" "$AAI_LOG_FILE"
}
