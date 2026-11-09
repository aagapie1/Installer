#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/common.sh - logging, user-facing messages (in Romanian), error handling,
# dry-run aware command execution and the end-of-run summary.
#
# Sourced by install.sh and the operation scripts. It does not change shell
# options; callers are expected to run with `set -Eeuo pipefail`.
#
# Environment variables (all optional):
#   AAI_LOG_DIR          log directory            (default /var/log/asistent-ai)
#   AAI_LOG_FILE         log file                 (default $AAI_LOG_DIR/install.log)
#   AAI_DRY_RUN          1 = print actions only   (default 0)
#   AAI_NON_INTERACTIVE  1 = never prompt         (default 0)
#   NO_COLOR             set = no ANSI colors on the console

if [[ -n "${AAI_COMMON_LOADED:-}" ]]; then
  return 0
fi
AAI_COMMON_LOADED=1

: "${AAI_LOG_DIR:=/var/log/asistent-ai}"
: "${AAI_LOG_FILE:=${AAI_LOG_DIR}/install.log}"
: "${AAI_DRY_RUN:=0}"
: "${AAI_NON_INTERACTIVE:=0}"
: "${AAI_LOCK_FILE:=/run/lock/asistent-ai-install.lock}"

AAI_LOG_ENABLED=0
# Summary rows: "STATUS<TAB>stage<TAB>message<TAB>action"
AAI_SUMMARY=()

# ---------------------------------------------------------------------------
# Console colors
# ---------------------------------------------------------------------------

aai_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
  else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
  fi
}
aai_init_colors

# ---------------------------------------------------------------------------
# Secret redaction
# ---------------------------------------------------------------------------

# Reads stdin, writes it to stdout with anything that looks like a secret
# masked: NAME=value / NAME: value where NAME mentions a secret, bearer
# tokens and long hex strings (our generated secrets are 64 hex chars).
aai_redact() {
  sed -E \
    -e 's/([A-Za-z0-9_.-]*(SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|_KEY)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1***/Ig' \
    -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1***/Ig' \
    -e 's/[0-9a-fA-F]{32,}/***/g'
}

aai_redact_str() {
  printf '%s\n' "$*" | aai_redact
}

# ---------------------------------------------------------------------------
# Logging and messages
# ---------------------------------------------------------------------------

aai_is_dry_run() {
  [[ "${AAI_DRY_RUN}" == 1 ]]
}

# Writes one line to the log file (never to the console). Always redacted.
aai_log() {
  local level=$1
  shift
  [[ "${AAI_LOG_ENABLED}" == 1 ]] || return 0
  local line
  line=$(aai_redact_str "$*")
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$line" >>"${AAI_LOG_FILE}"
}

# Prints a console message and logs it. Warnings and errors go to stderr.
_aai_emit() {
  local level=$1 color=$2
  shift 2
  local msg
  msg=$(aai_redact_str "$*")
  aai_log "$level" "$msg"
  case "$level" in
    AVERTISMENT | EROARE) printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$msg" >&2 ;;
    *) printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$msg" ;;
  esac
}

aai_info() { _aai_emit INFO "$C_BLUE" "$@"; }
aai_ok() { _aai_emit OK "$C_GREEN" "$@"; }
aai_warn() { _aai_emit AVERTISMENT "$C_YELLOW" "$@"; }
aai_error() { _aai_emit EROARE "$C_RED" "$@"; }
aai_debug() { aai_log DEBUG "$@"; }

# Section header on the console.
aai_step() {
  aai_log STEP "$*"
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"
}

# Prints an error with what the operator has to do, then exits.
# Usage: aai_die "cause" ["what to do"] [exit code]
aai_die() {
  local cause=$1 action=${2:-} code=${3:-1}
  aai_error "$cause"
  if [[ -n "$action" ]]; then
    aai_error "Ce trebuie făcut: $action"
  fi
  if [[ "${AAI_LOG_ENABLED}" == 1 ]]; then
    printf 'Detalii în jurnal: %s\n' "${AAI_LOG_FILE}" >&2
  fi
  exit "$code"
}

# Opens the install log. In dry-run mode nothing is written to disk.
aai_log_init() {
  if aai_is_dry_run; then
    AAI_LOG_ENABLED=0
    return 0
  fi
  if ! mkdir -p "${AAI_LOG_DIR}" 2>/dev/null; then
    aai_die "Nu pot crea directorul de jurnal ${AAI_LOG_DIR}." \
      "Rulați cu sudo și verificați că discul nu este plin."
  fi
  chmod 750 "${AAI_LOG_DIR}"
  (umask 027 && : >>"${AAI_LOG_FILE}")
  chmod 640 "${AAI_LOG_FILE}"
  AAI_LOG_ENABLED=1
  printf '\n===== %s %s =====\n' "$(date -Is)" "${AAI_RUN_LABEL:-}" >>"${AAI_LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------

# Install with: trap 'aai_on_error $? $LINENO "$BASH_COMMAND"' ERR
aai_on_error() {
  local rc=$1 line=$2 cmd=$3
  trap - ERR
  aai_error "Eroare neașteptată (cod ${rc}) la linia ${line}, comanda: $(aai_redact_str "$cmd")"
  if [[ "${AAI_LOG_ENABLED}" == 1 ]]; then
    aai_error "Ce trebuie făcut: verificați jurnalul ${AAI_LOG_FILE}, corectați cauza și rulați din nou (instalarea este idempotentă)."
  fi
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

_aai_quote_cmd() {
  local out='' arg
  for arg in "$@"; do
    out+="$(printf '%q' "$arg") "
  done
  printf '%s' "${out% }"
}

# Runs a command with stdout+stderr redacted into the log file. Returns the
# command's own exit code whether or not pipefail/errexit are set: the exit
# code travels over fd 3 while the output goes through the redaction pipe.
_aai_exec_logged() {
  local rc
  rc=$({ { "$@" 3>&- 2>&1 && echo 0 >&3 || echo "$?" >&3; } |
    aai_redact >>"${AAI_LOG_FILE}"; } 3>&1)
  return "${rc:-1}"
}

# Runs a command; in dry-run mode only prints it. Output goes to the log
# (redacted) when the log is open, otherwise to the console.
# Returns the command's exit code.
aai_run() {
  (($# > 0)) || return 2
  local cmd rc=0
  cmd=$(_aai_quote_cmd "$@")
  if aai_is_dry_run; then
    printf '%s[dry-run]%s %s\n' "$C_BLUE" "$C_RESET" "$(aai_redact_str "$cmd")"
    return 0
  fi
  aai_debug "Rulez: $cmd"
  if [[ "${AAI_LOG_ENABLED}" == 1 ]]; then
    _aai_exec_logged "$@" || rc=$?
  else
    "$@" || rc=$?
  fi
  ((rc == 0)) || aai_debug "Comanda a eșuat (cod $rc): $cmd"
  return "$rc"
}

# Like aai_run, but the command line itself is never printed or logged
# (use when arguments contain secrets). Usage: aai_run_secret "description" cmd...
aai_run_secret() {
  local desc=$1
  shift
  (($# > 0)) || return 2
  local rc=0
  if aai_is_dry_run; then
    printf '%s[dry-run]%s %s\n' "$C_BLUE" "$C_RESET" "$desc"
    return 0
  fi
  aai_debug "Rulez (argumente ascunse): $desc"
  if [[ "${AAI_LOG_ENABLED}" == 1 ]]; then
    _aai_exec_logged "$@" || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi
  return "$rc"
}

# Retries a command with exponential backoff.
# Usage: aai_retry <attempts> <initial delay seconds> cmd...
aai_retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i < attempts)); then
      aai_warn "Încercarea ${i}/${attempts} a eșuat; reîncerc în ${delay}s."
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Interaction, privileges, locking
# ---------------------------------------------------------------------------

# Usage: aai_confirm "question" [default y|n]. Returns 0 for yes.
aai_confirm() {
  local question=$1 default=${2:-n} answer hint='[d/N]'
  [[ "$default" == y ]] && hint='[D/n]'
  if [[ "${AAI_NON_INTERACTIVE}" == 1 ]]; then
    [[ "$default" == y ]]
    return
  fi
  read -r -p "${question} ${hint} " answer || answer=''
  answer=${answer,,}
  [[ -z "$answer" ]] && answer=$default
  [[ "$answer" == d || "$answer" == da || "$answer" == y || "$answer" == yes ]]
}

aai_require_root() {
  aai_is_dry_run && return 0
  if [[ "${EUID}" -ne 0 ]]; then
    aai_die "Scriptul trebuie rulat ca root." "Rulați din nou cu sudo (sau folosiți --dry-run pentru o simulare)." 1
  fi
}

# Prevents two installer runs at the same time. Keeps fd 9 open until exit.
aai_lock_acquire() {
  aai_is_dry_run && return 0
  mkdir -p "$(dirname -- "${AAI_LOCK_FILE}")"
  exec 9>"${AAI_LOCK_FILE}"
  if ! flock -n 9; then
    aai_die "O altă rulare a kitului este deja în desfășurare." \
      "Așteptați să se termine sau verificați procesele cu: ps aux | grep install.sh"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

# Usage: aai_summary_add OK|AVERTISMENT|EROARE <stage> <message> [action]
aai_summary_add() {
  local status=$1 stage=$2 message=$3 action=${4:-}
  case "$status" in
    OK | AVERTISMENT | EROARE) ;;
    *) return 2 ;;
  esac
  message=${message//$'\t'/ }
  action=${action//$'\t'/ }
  AAI_SUMMARY+=("${status}"$'\t'"${stage}"$'\t'"${message}"$'\t'"${action}")
  aai_log SUMMARY "${status} ${stage}: ${message}${action:+ (${action})}"
}

aai_summary_count() {
  local wanted=$1 row n=0
  for row in "${AAI_SUMMARY[@]+"${AAI_SUMMARY[@]}"}"; do
    [[ "${row%%$'\t'*}" == "$wanted" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

aai_summary_has_errors() {
  [[ "$(aai_summary_count EROARE)" -gt 0 ]]
}

aai_summary_print() {
  local row status stage message action color
  aai_step "Rezumat"
  if ((${#AAI_SUMMARY[@]} == 0)); then
    printf '(nicio etapă rulată)\n'
    return 0
  fi
  for row in "${AAI_SUMMARY[@]}"; do
    IFS=$'\t' read -r status stage message action <<<"$row"
    case "$status" in
      OK) color=$C_GREEN ;;
      AVERTISMENT) color=$C_YELLOW ;;
      *) color=$C_RED ;;
    esac
    printf '%s%-12s%s %-12s %s\n' "$color" "$status" "$C_RESET" "$stage" "$message"
    [[ -n "$action" ]] && printf '%-25s → %s\n' '' "$action"
  done
  printf '\nOK: %s · AVERTISMENT: %s · EROARE: %s\n' \
    "$(aai_summary_count OK)" "$(aai_summary_count AVERTISMENT)" "$(aai_summary_count EROARE)"
}
