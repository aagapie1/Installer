#!/usr/bin/env bash
#
# install.sh - installs an on-premise AI assistant (Dify + local model) for
# one client on a fresh Ubuntu Server 24.04. See SPEC.md.
#
# Usage: sudo ./install.sh --config client.yaml [--dry-run] [--non-interactive]
#                          [--skip <stage>] [--only <stage>] [--set key=value]

set -Eeuo pipefail
# C.UTF-8 is always present on Ubuntu 24.04; gives consistent tool output
# and character-based string lengths for Romanian text.
export LC_ALL=C.UTF-8

AAI_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export AAI_ROOT
AAI_VERSION='0.1.0-dev'

# shellcheck source=lib/common.sh
source "${AAI_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${AAI_ROOT}/lib/config.sh"
# shellcheck source=lib/stages.sh
source "${AAI_ROOT}/lib/stages.sh"
# shellcheck source=lib/preflight.sh
source "${AAI_ROOT}/lib/preflight.sh"
# shellcheck source=lib/system.sh
source "${AAI_ROOT}/lib/system.sh"
# shellcheck source=lib/docker.sh
source "${AAI_ROOT}/lib/docker.sh"

OPT_CONFIG=''
OPT_ONLY=''
OPT_SKIP=''
OPT_SETS=()

usage() {
  cat <<EOF
Kit de instalare asistent virtual AI (versiunea ${AAI_VERSION})

Utilizare:
  sudo ./install.sh --config <client.yaml> [opțiuni]

Opțiuni:
  --config <fișier>     fișierul de configurare al clientului (obligatoriu)
  --dry-run             afișează ce s-ar face, fără să modifice sistemul
  --non-interactive     nu pune întrebări; folosește răspunsurile implicite
  --only <etape>        rulează doar etapele date (ex. P0,P1 sau preflight)
  --skip <etape>        sare peste etapele date
  --set <cheie=valoare> suprascrie o valoare din client.yaml
                        (ex. --set inference.profile=cpu;
                         listele separate prin virgulă:
                         --set admin.allowed_ips=10.0.0.0/8,192.0.2.10)
  -h, --help            afișează acest mesaj
  --version             afișează versiunea kitului

Coduri de ieșire: 0 = OK, 1 = eroare, 2 = utilizare greșită,
                  3 = e nevoie de repornire (rulați din nou după reboot)

Etape: $(aai_stage_list_help)
Jurnal: ${AAI_LOG_FILE}
EOF
}

# Exits with code 2 (usage error).
usage_error() {
  aai_error "$1"
  printf 'Rulați ./install.sh --help pentru detalii.\n' >&2
  exit 2
}

_append_csv() {
  local current=$1 add=$2
  printf '%s' "${current:+${current},}${add}"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --config)
        (($# >= 2)) || usage_error "Opțiunea --config necesită un fișier."
        OPT_CONFIG=$2
        shift 2
        ;;
      --config=*) OPT_CONFIG=${1#*=}; shift ;;
      --dry-run) AAI_DRY_RUN=1; shift ;;
      --non-interactive) AAI_NON_INTERACTIVE=1; shift ;;
      --only | --skip | --set)
        (($# >= 2)) || usage_error "Opțiunea $1 necesită o valoare."
        _store_opt "$1" "$2"
        shift 2
        ;;
      --only=* | --skip=* | --set=*) _store_opt "${1%%=*}" "${1#*=}"; shift ;;
      -h | --help) usage; exit 0 ;;
      --version) printf '%s\n' "${AAI_VERSION}"; exit 0 ;;
      *) usage_error "Opțiune necunoscută: $1" ;;
    esac
  done
  [[ -n "$OPT_CONFIG" ]] || usage_error "Lipsește --config <client.yaml>."
}

_store_opt() {
  case "$1" in
    --only) OPT_ONLY=$(_append_csv "$OPT_ONLY" "$2") ;;
    --skip) OPT_SKIP=$(_append_csv "$OPT_SKIP" "$2") ;;
    --set) OPT_SETS+=("$2") ;;
  esac
}

# ---------------------------------------------------------------------------
# Stages. Each one prints its plan in dry-run mode and records its result
# in the summary. Stages not implemented yet report AVERTISMENT.
# ---------------------------------------------------------------------------

plan() {
  aai_is_dry_run && printf '  • %s\n' "$*"
  return 0
}

not_implemented() {
  local stage=$1 milestone=$2
  aai_summary_add AVERTISMENT "${AAI_STAGE_CODE[$stage]}" \
    "etapa nu este încă implementată (${milestone})" "rulați pașii manual sau așteptați versiunea următoare a kitului"
}

stage_preflight() {
  preflight_run
}

stage_system() {
  system_stage
}

stage_inference() {
  plan "Pornesc serviciile de inferență în rețeaua Docker a Dify (fără porturi expuse)"
  plan "Modele: chat=$(config_get inference.chat_model), embeddings=$(config_get inference.embedding_model), rerank=$(config_get inference.rerank_model)"
  not_implemented inference M3
}

stage_dify() {
  plan "Clonez langgenius/dify la tag-ul $(config_get dify_version) în /opt/asistent-ai/dify/"
  plan "Generez .env cu secrete noi în /opt/asistent-ai/secrets/ (600, root)"
  plan "Setez URL-urile publice la https://$(config_get domain); TLS: $(config_get tls.mode)"
  plan "docker compose up -d și aștept containerele healthy"
  not_implemented dify M4
}

stage_assistant() {
  plan "Creez contul de administrator $(config_get admin.email) și configurez providerii de modele"
  plan "Creez colecția Knowledge și încarc documentele din $(config_path documents_dir)"
  plan "Import Chatflow-ul din $(config_get assistant.template), îl public și generez codul de embed"
  not_implemented assistant M5
}

stage_hardening() {
  plan "Restricționez /console, /install, /signin la IP-urile: $(config_list admin.allowed_ips | paste -sd ' ' -)"
  plan "limit_req pe rutele publice de chat; antete de securitate; fără înregistrare liberă"
  not_implemented hardening M7
}

stage_operations() {
  plan "Instalez backup.sh (cron zilnic, rotație), status.sh, update.sh, retenție $(config_get retention_days) zile, logrotate"
  not_implemented operations M8
}

stage_report() {
  plan "Scriu /opt/asistent-ai/INSTALL-REPORT.md (600) și afișez rezumatul fără secrete"
  not_implemented report M8
}

# Runs one stage. Stops the installation (exit 1) when the stage recorded an
# error, or cleanly (exit 3) when it asked the operator to act first, e.g.
# reboot after the NVIDIA driver install. In dry-run it only reports this.
run_stage() {
  local stage=$1 errors_before label
  label=$(aai_stage_label "$stage")
  errors_before=$(aai_summary_count EROARE)
  aai_step "$label"
  "stage_${stage}"
  if (($(aai_summary_count EROARE) > errors_before)); then
    if aai_is_dry_run; then
      aai_warn "În rularea reală, instalarea s-ar opri aici (etapa ${label} are erori)."
      return 0
    fi
    aai_summary_print
    aai_error "Instalarea s-a oprit la etapa ${label}. Corectați problemele de mai sus și rulați din nou aceeași comandă."
    exit 1
  fi
  if [[ "$AAI_STOP_REASON" == reboot ]]; then
    aai_summary_print
    aai_warn "Instalarea s-a oprit pentru repornire. După sudo reboot, rulați din nou aceeași comandă; etapele deja făcute nu se repetă inutil."
    exit 3
  fi
}

# ---------------------------------------------------------------------------

load_config() {
  local kv
  config_load "$OPT_CONFIG" || aai_die "Configurarea nu a putut fi încărcată." \
    "Corectați fișierul $OPT_CONFIG (model: config/client.example.yaml)."
  for kv in "${OPT_SETS[@]+"${OPT_SETS[@]}"}"; do
    config_set_kv "$kv" || exit 2
  done
  config_validate || aai_die "Configurarea are erori." "Corectați valorile de mai sus și rulați din nou."
}

main() {
  parse_args "$@"
  trap 'aai_on_error $? $LINENO "$BASH_COMMAND"' ERR

  local selected stage
  selected=$(aai_stage_select "$OPT_ONLY" "$OPT_SKIP") || exit 2
  [[ -n "$selected" ]] || usage_error "Nicio etapă selectată (verificați --only / --skip)."

  aai_require_root
  aai_lock_acquire
  AAI_RUN_LABEL="install.sh ${AAI_VERSION}${AAI_DRY_RUN:+ dry-run=${AAI_DRY_RUN}}"
  aai_log_init

  if aai_is_dry_run; then
    aai_info "Mod simulare (--dry-run): sistemul nu va fi modificat."
  fi

  load_config
  aai_step "Configurare"
  config_print_summary

  while IFS= read -r stage; do
    run_stage "$stage"
  done <<<"$selected"

  aai_summary_print
  if aai_summary_has_errors; then
    exit 1
  fi
}

main "$@"
