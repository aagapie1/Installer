#!/usr/bin/env bats
# Tests for lib/config.sh

# Globals set here are read by the sourced libraries.
# shellcheck disable=SC2034

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  aai_test_setup
  CFG="${BATS_TEST_TMPDIR}/client.yaml"
}

@test "load: example config parses with UTF-8 values" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  [ "$(config_get client.name)" = "Primăria Municipiului Buzău" ]
  [ "$(config_get domain)" = "asistent.primariabuzau.ro" ]
  [ "$(config_get retention_days)" = 90 ]
  [ "$(config_get dify_version)" = 1.19.0 ]
  config_validate
}

@test "load: lists are flattened with a length" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  [ "$(config_list_len admin.allowed_ips)" -eq 2 ]
  [ "$(config_list admin.allowed_ips | sed -n 2p)" = "192.0.2.10" ]
  [ "$(config_list assistant.starter_questions | head -1)" = "Care este programul cu publicul?" ]
}

@test "load: defaults fill missing optional keys" {
  write_config "$CFG" '/^inference:/,/rerank_model/d' '/^retention_days:/d' '/^dify_version:/d'
  config_load "$CFG"
  [ "$(config_get inference.profile)" = auto ]
  [ "$(config_get inference.embedding_model)" = bge-m3 ]
  [ "$(config_get retention_days)" = 90 ]
  [ "$(config_get dify_version)" = 1.19.0 ]
  config_validate
}

@test "load: missing file is a clear error" {
  run config_load "${BATS_TEST_TMPDIR}/nu-exista.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nu există"* ]]
}

@test "load: invalid YAML is reported in Romanian" {
  printf 'client:\n  name: "x\n  bad: [\n' >"$CFG"
  run config_load "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"YAML invalid"* ]]
}

@test "load: top-level list is rejected" {
  printf -- '- a\n- b\n' >"$CFG"
  run config_load "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dicționar"* ]]
}

# Literal $( ) and backticks are the point of this test.
# shellcheck disable=SC2016
@test "load: values with quotes, \$ and backticks are kept verbatim" {
  write_config "$CFG" 's/^(  name: ).*/\1"Primăria \\"X\\" $(touch pwned) `id`"/'
  config_load "$CFG"
  [ "$(config_get client.name)" = 'Primăria "X" $(touch pwned) `id`' ]
  [ ! -e pwned ]
}

@test "validate: missing required keys are all reported" {
  printf 'domain: "a.ro"\n' >"$CFG"
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"client.name"* ]]
  [[ "$output" == *"client.short_name"* ]]
  [[ "$output" == *"admin.email"* ]]
  [[ "$output" == *"documents_dir"* ]]
  [[ "$output" == *"admin.allowed_ips"* ]]
}

@test "validate: bad domain, short_name, mode and profile" {
  write_config "$CFG" 's#^domain:.*#domain: "https://Asistent.ro/"#' \
    's/short_name: .*/short_name: "Primaria Buzau"/' \
    's/mode: "letsencrypt"/mode: "selfsigned"/' \
    's/profile: "auto"/profile: "tpu"/'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"domain"* ]]
  [[ "$output" == *"short_name"* ]]
  [[ "$output" == *"tls.mode 'selfsigned' invalid"* ]]
  [[ "$output" == *"inference.profile 'tpu' invalid"* ]]
}

@test "validate: letsencrypt requires tls.email" {
  write_config "$CFG" 's/^(  email: "it@.*)$/  email: ""/'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"tls.email este obligatoriu"* ]]
}

@test "validate: custom TLS requires cert and key" {
  write_config "$CFG" 's/mode: "letsencrypt"/mode: "custom"/'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"tls.cert_file"* && "$output" == *"tls.key_file"* ]]
}

@test "validate: tls none is only a warning" {
  write_config "$CFG" 's/mode: "letsencrypt"/mode: "none"/'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"AVERTISMENT"*"teste interne"* ]]
}

@test "validate: rejects invalid IPs and empty allowed_ips" {
  write_config "$CFG" 's#allowed_ips: .*#allowed_ips: ["10.0.0.0/33", "300.1.1.1", "01.2.3.4"]#'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"10.0.0.0/33"* && "$output" == *"300.1.1.1"* && "$output" == *"01.2.3.4"* ]]

  write_config "$CFG" 's#allowed_ips: .*#allowed_ips: []#'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"cel puțin un IP"* ]]
}

@test "validate: unquoted dify_version (float) is rejected with a hint" {
  write_config "$CFG" 's/^dify_version: .*/dify_version: 1.19/'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghilimele"* ]]
}

@test "validate: wrong shapes and unknown keys" {
  write_config "$CFG" 's#allowed_ips: .*#allowed_ips: "10.0.0.0/8"#' '$ a\retenton_days: 30'
  config_load "$CFG"
  run config_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"'admin.allowed_ips' trebuie să fie o listă"* ]]
  [[ "$output" == *"cheie necunoscută 'retenton_days'"* ]]
}

@test "ip validation helper" {
  aai_is_ip_or_cidr 192.0.2.10
  aai_is_ip_or_cidr 10.0.0.0/8
  aai_is_ip_or_cidr 0.0.0.0/0
  aai_is_ip_or_cidr 2001:db8::/32
  aai_is_ip_or_cidr ::1
  run ! aai_is_ip_or_cidr 10.0.0/8
  run ! aai_is_ip_or_cidr 10.0.0.0/
  run ! aai_is_ip_or_cidr 2001:db8::/129
  run ! aai_is_ip_or_cidr "10.0.0.1; rm -rf /"
  run ! aai_is_ip_or_cidr ""
}

@test "set: overrides scalars and lists, rejects unknown keys" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  config_set_kv inference.profile=cpu
  [ "$(config_get inference.profile)" = cpu ]
  config_set_kv "admin.allowed_ips= 203.0.113.5 ,10.1.0.0/16,"
  [ "$(config_list_len admin.allowed_ips)" -eq 2 ]
  [ "$(config_list admin.allowed_ips | head -1)" = 203.0.113.5 ]
  config_validate
  run config_set_kv nu.exista=1
  [ "$status" -eq 1 ]
  run config_set_kv fara-egal
  [ "$status" -eq 1 ]
}

@test "set: value may contain '='" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  config_set_kv "assistant.opener=a=b"
  [ "$(config_get assistant.opener)" = "a=b" ]
}

@test "render: replaces placeholders, keeps Dify variables and '&'" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  config_set client.name "Primăria A & B"
  run config_render "Asistentul {client.name}, tel. {client.phone_public_relations}: {{#context#}}"
  [ "$output" = "Asistentul Primăria A & B, tel. 0238 411 015: {{#context#}}" ]
}

@test "path: relative paths resolve against the repo root" {
  config_load "${AAI_ROOT}/config/client.example.yaml"
  [ "$(config_path documents_dir)" = "${AAI_ROOT}/clients/primaria-buzau/docs" ]
  config_set documents_dir /srv/docs
  [ "$(config_path documents_dir)" = /srv/docs ]
}
