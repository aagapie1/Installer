#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/system.sh - P1 base system: apt packages and the ufw firewall
# (SPEC.md §4.2). Docker and NVIDIA live in lib/docker.sh.
#
# Every step records its result with aai_check under "P1" and returns 1 when
# the installation cannot continue. Steps check each command explicitly and
# do not rely on errexit.

if [[ -n "${AAI_SYSTEM_LOADED:-}" ]]; then
  return 0
fi
AAI_SYSTEM_LOADED=1

AAI_BASE_PACKAGES=(
  curl git jq openssl zstd ufw unattended-upgrades ethtool
  ca-certificates gnupg python3-yaml iproute2
)

: "${AAI_REBOOT_REQUIRED_FILE:=/var/run/reboot-required}"

_sys() { aai_check "$1" P1 "${@:2}"; }

# apt-get without prompts; waits for the dpkg lock (unattended-upgrades may
# hold it right after boot) and keeps existing config files on upgrade.
aai_apt() {
  aai_run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get -q -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# apt-get with retries for network errors.
aai_apt_retry() {
  aai_retry 3 10 aai_apt "$@"
}

# True if a Debian package is installed.
aai_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

system_apt_base() {
  if ! aai_apt_retry update; then
    _sys EROARE "apt update a eșuat" "Verificați accesul la depozitele Ubuntu și detaliile din jurnal."
    return 1
  fi
  if ! aai_apt_retry -y upgrade; then
    _sys EROARE "apt upgrade a eșuat" "Rulați manual: sudo apt-get upgrade și corectați eroarea afișată."
    return 1
  fi
  if ! aai_apt_retry -y install "${AAI_BASE_PACKAGES[@]}"; then
    _sys EROARE "Instalarea pachetelor de bază a eșuat" \
      "Rulați manual: sudo apt-get install ${AAI_BASE_PACKAGES[*]}"
    return 1
  fi
  _sys OK "Sistem actualizat; pachete de bază instalate"
}

# Prints the TCP ports sshd listens on (from `ss`), one per line; falls back
# to 22. Opening them in ufw prevents locking the operator out.
system_ssh_ports() {
  local out ports=''
  if aai_have ss && out=$(ss -Htlnp 2>/dev/null); then
    ports=$(grep '"sshd"' <<<"$out" | awk '{ print $4 }' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)
  fi
  printf '%s\n' "${ports:-22}"
}

# Ports to allow: 22, any other sshd port, 80, 443 (unique, in order).
system_firewall_ports() {
  { printf '22\n'; system_ssh_ports; printf '80\n443\n'; } | awk '!seen[$0]++'
}

system_firewall() {
  local port extra=()
  if ! aai_run ufw default deny incoming || ! aai_run ufw default allow outgoing; then
    _sys EROARE "Nu pot configura politica implicită ufw" "Verificați: sudo ufw status verbose"
    return 1
  fi
  while IFS= read -r port; do
    if ! aai_run ufw allow "${port}/tcp" comment asistent-ai; then
      _sys EROARE "Nu pot deschide portul $port în ufw" "Verificați: sudo ufw status verbose"
      return 1
    fi
    [[ "$port" =~ ^(22|80|443)$ ]] || extra+=("$port")
  done < <(system_firewall_ports)
  if ! aai_run ufw --force enable; then
    _sys EROARE "Nu pot activa firewall-ul ufw" "Verificați: sudo ufw status verbose"
    return 1
  fi
  if ! aai_is_dry_run && ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    _sys EROARE "Firewall-ul ufw nu este activ după configurare" "Verificați: sudo ufw status verbose"
    return 1
  fi
  if ((${#extra[@]} > 0)); then
    _sys AVERTISMENT "Firewall activ: 22, 80, 443 și portul SSH ${extra[*]} (sshd ascultă pe el)" \
      "Dacă portul ${extra[*]} nu mai este necesar, închideți-l cu: sudo ufw delete allow <port>/tcp"
  else
    _sys OK "Firewall activ: permise doar 22, 80, 443"
  fi
}

system_check_reboot_required() {
  if [[ -f "$AAI_REBOOT_REQUIRED_FILE" ]]; then
    _sys AVERTISMENT "Actualizările instalate cer o repornire a serverului" \
      "Programați o repornire (sudo reboot) când este convenabil; instalarea poate continua."
  fi
}

# P1 entry point. Returns 0 even on failure: errors are in the summary and
# install.sh stops when the stage recorded any.
system_stage() {
  preflight_ensure_profile
  aai_info "Profil de inferență: ${AAI_PROFILE}"
  system_apt_base || return 0
  system_firewall || return 0
  docker_install_all || return 0
  if [[ "$AAI_PROFILE" == gpu ]]; then
    nvidia_ensure_driver || return 0
    [[ -n "$AAI_STOP_REASON" ]] && return 0
    nvidia_install_toolkit || return 0
    nvidia_verify_container || return 0
  fi
  system_check_reboot_required
}
