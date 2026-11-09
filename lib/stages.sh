#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/stages.sh - the installation stages (SPEC.md §4) and --only/--skip
# selection. Stages are referred to by name (preflight) or code (P0).

if [[ -n "${AAI_STAGES_LOADED:-}" ]]; then
  return 0
fi
AAI_STAGES_LOADED=1

AAI_STAGES=(preflight system inference dify assistant hardening operations report)

declare -gA AAI_STAGE_CODE=(
  [preflight]=P0 [system]=P1 [inference]=P2 [dify]=P3
  [assistant]=P4 [hardening]=P5 [operations]=P6 [report]=P7
)

declare -gA AAI_STAGE_TITLE=(
  [preflight]='Verificări preliminare'
  [system]='Sistemul de bază'
  [inference]='Serviciile de inferență'
  [dify]='Dify'
  [assistant]='Configurarea asistentului'
  [hardening]='Securizare'
  [operations]='Operare'
  [report]='Raportul final'
)

# Prints the canonical stage name for a name or code (case-insensitive).
aai_stage_normalize() {
  local wanted=${1,,} stage
  for stage in "${AAI_STAGES[@]}"; do
    if [[ "$wanted" == "$stage" || "$wanted" == "${AAI_STAGE_CODE[$stage],,}" ]]; then
      printf '%s\n' "$stage"
      return 0
    fi
  done
  return 1
}

# Converts comma-separated stage lists to canonical names, one per line.
_aai_stage_parse_list() {
  local list=$1 item stage
  local -a items
  IFS=',' read -r -a items <<<"$list"
  for item in "${items[@]+"${items[@]}"}"; do
    item=${item//[[:space:]]/}
    [[ -z "$item" ]] && continue
    if ! stage=$(aai_stage_normalize "$item"); then
      aai_error "Etapă necunoscută: '$item'. Etape valide: $(aai_stage_list_help)"
      return 1
    fi
    printf '%s\n' "$stage"
  done
}

aai_stage_list_help() {
  local stage out=''
  for stage in "${AAI_STAGES[@]}"; do
    out+="${AAI_STAGE_CODE[$stage]}=${stage}, "
  done
  printf '%s' "${out%, }"
}

# Usage: aai_stage_select "<only csv>" "<skip csv>"
# Prints the selected stages in installation order. Empty "only" = all.
aai_stage_select() {
  local only_csv=$1 skip_csv=$2 stage only skip
  only=$(_aai_stage_parse_list "$only_csv") || return 1
  skip=$(_aai_stage_parse_list "$skip_csv") || return 1
  for stage in "${AAI_STAGES[@]}"; do
    if [[ -n "$only" ]] && ! grep -qxF -- "$stage" <<<"$only"; then
      continue
    fi
    if [[ -n "$skip" ]] && grep -qxF -- "$stage" <<<"$skip"; then
      continue
    fi
    printf '%s\n' "$stage"
  done
}

aai_stage_label() {
  printf '%s — %s' "${AAI_STAGE_CODE[$1]}" "${AAI_STAGE_TITLE[$1]}"
}
