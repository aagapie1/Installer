#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/docker.sh - P1: Docker Engine from Docker's official apt repository
# (never Docker Desktop), daemon settings, and for the GPU profile the NVIDIA
# driver and NVIDIA Container Toolkit (SPEC.md §4.2).
#
# Requires lib/common.sh, lib/system.sh (aai_apt*) and lib/preflight.sh
# (_pf_os_field).

if [[ -n "${AAI_DOCKER_LOADED:-}" ]]; then
  return 0
fi
AAI_DOCKER_LOADED=1

: "${AAI_APT_SOURCES_DIR:=/etc/apt/sources.list.d}"
: "${AAI_APT_KEYRINGS_DIR:=/etc/apt/keyrings}"
: "${AAI_DOCKER_DAEMON_JSON:=/etc/docker/daemon.json}"
: "${AAI_DOCKER_GPG_URL:=https://download.docker.com/linux/ubuntu/gpg}"
# Docker's release signing key, as published at docs.docker.com/engine/install/ubuntu.
: "${AAI_DOCKER_GPG_FPR:=9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
: "${AAI_NVIDIA_GPG_URL:=https://nvidia.github.io/libnvidia-container/gpgkey}"
# Optional: expected fingerprint of NVIDIA's key. Empty = trust the TLS
# download, as in NVIDIA's own instructions.
: "${AAI_NVIDIA_GPG_FPR:=}"
: "${AAI_NVIDIA_KEYRING:=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg}"
# Optional driver branch for `ubuntu-drivers install --gpgpu nvidia:<branch>`,
# e.g. "570-server". Empty = the version recommended by ubuntu-drivers.
: "${AAI_NVIDIA_DRIVER:=}"
: "${AAI_GPU_TEST_IMAGE:=ubuntu:24.04}"

AAI_DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
AAI_DOCKER_CONFLICTS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

# ---------------------------------------------------------------------------
# Pure helpers (unit tested)
# ---------------------------------------------------------------------------

# True if the OpenPGP key file contains the given fingerprint.
aai_gpg_has_fingerprint() {
  local file=$1 expected=${2^^} home rc=1
  home=$(mktemp -d)
  if GNUPGHOME="$home" gpg --batch --show-keys --with-colons "$file" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }' | grep -qxF -- "$expected"; then
    rc=0
  fi
  rm -rf -- "$home"
  return "$rc"
}

# deb822 source for Docker's repository. Usage: docker_sources <codename> <arch>
docker_sources() {
  cat <<EOF
# Managed by asistent-ai-installer.
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $1
Components: stable
Architectures: $2
Signed-By: ${AAI_APT_KEYRINGS_DIR}/docker.asc
EOF
}

nvidia_sources() {
  # $(ARCH) is an apt variable, not a shell expansion.
  # shellcheck disable=SC2016
  printf '# Managed by asistent-ai-installer.\ndeb [signed-by=%s] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n' \
    "${AAI_NVIDIA_KEYRING}"
}

# Reads daemon.json (may be empty) on stdin and prints it with log rotation
# added when missing; existing settings are never changed. Keys sorted.
docker_merge_daemon_json() {
  jq -S '(if . == null then {} else . end) as $c
    | $c + {
        "log-driver": ($c["log-driver"] // "json-file"),
        "log-opts": ($c["log-opts"] // {"max-size": "50m", "max-file": "5"})
      }'
}

# From installed NVIDIA driver package names (stdin), prints the matching
# nvidia-utils package (provides nvidia-smi), e.g. nvidia-utils-570-server.
nvidia_utils_package_for() {
  sed -nE 's/^nvidia-(headless(-no-dkms)?|driver)-([0-9]+)(-server)?(-open)?$/nvidia-utils-\3\4/p' | sort -u | tail -1
}

# ---------------------------------------------------------------------------
# Docker Engine
# ---------------------------------------------------------------------------

_dk() { aai_check "$1" P1 "${@:2}"; }

docker_check_no_desktop() {
  if aai_pkg_installed docker-desktop; then
    _dk EROARE "Docker Desktop este instalat; kitul folosește doar Docker Engine (licența Docker Desktop este comercială)" \
      "Dezinstalați-l: sudo apt-get purge docker-desktop, apoi rulați din nou."
    return 1
  fi
}

docker_remove_conflicts() {
  local pkg found=()
  for pkg in "${AAI_DOCKER_CONFLICTS[@]}"; do
    aai_pkg_installed "$pkg" && found+=("$pkg")
  done
  ((${#found[@]} == 0)) && return 0
  if ! aai_apt -y remove "${found[@]}"; then
    _dk EROARE "Nu pot elimina pachetele incompatibile: ${found[*]}" "Rulați manual: sudo apt-get remove ${found[*]}"
    return 1
  fi
  _dk AVERTISMENT "Am eliminat pachetele Docker din Ubuntu, incompatibile cu Docker Engine: ${found[*]}" \
    "Datele din /var/lib/docker au fost păstrate; verificați containerele existente, dacă erau."
}

# Downloads a key to a temp file and checks its fingerprint (when given).
# Prints the temp file path.
_dk_fetch_key() {
  local url=$1 fpr=$2 tmp
  tmp=$(mktemp)
  if ! aai_retry 3 5 curl -fsSL --max-time 60 -o "$tmp" "$url"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ -n "$fpr" ]] && ! aai_gpg_has_fingerprint "$tmp" "$fpr"; then
    rm -f -- "$tmp"
    return 2
  fi
  printf '%s' "$tmp"
}

# Sets DOCKER_REPO_CHANGED=1 when the key or source file changed.
DOCKER_REPO_CHANGED=0
docker_setup_repo() {
  local codename arch key rc=0 legacy="${AAI_APT_SOURCES_DIR}/docker.list"
  DOCKER_REPO_CHANGED=0
  codename=$(_pf_os_field UBUNTU_CODENAME)
  [[ -n "$codename" ]] || codename=$(_pf_os_field VERSION_CODENAME)
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  if aai_is_dry_run; then
    aai_run curl -fsSL -o "${AAI_APT_KEYRINGS_DIR}/docker.asc" "$AAI_DOCKER_GPG_URL"
    printf '  • (dry-run) verific amprenta cheii: %s\n' "$AAI_DOCKER_GPG_FPR"
  else
    key=$(_dk_fetch_key "$AAI_DOCKER_GPG_URL" "$AAI_DOCKER_GPG_FPR") || rc=$?
    if ((rc == 2)); then
      _dk EROARE "Cheia GPG descărcată de la Docker nu are amprenta așteptată" \
        "Nu continuați. Verificați rețeaua (proxy care modifică traficul?) și amprenta publicată pe docs.docker.com."
      return 1
    elif ((rc != 0)); then
      _dk EROARE "Nu pot descărca cheia GPG Docker" "Verificați accesul la download.docker.com."
      return 1
    fi
    aai_write_file "${AAI_APT_KEYRINGS_DIR}/docker.asc" 644 <"$key" || { rm -f -- "$key"; return 1; }
    rm -f -- "$key"
    ((AAI_FILE_CHANGED)) && DOCKER_REPO_CHANGED=1
  fi
  aai_write_file "${AAI_APT_SOURCES_DIR}/docker.sources" 644 < <(docker_sources "$codename" "$arch") || return 1
  ((AAI_FILE_CHANGED)) && DOCKER_REPO_CHANGED=1
  # A docker.list from a manual install with another Signed-By breaks apt.
  if [[ -f "$legacy" ]]; then
    aai_run mv -f -- "$legacy" "${legacy}.disabled-by-asistent-ai" || return 1
    DOCKER_REPO_CHANGED=1
    _dk AVERTISMENT "Am dezactivat ${legacy} (înlocuit de docker.sources)" ""
  fi
  return 0
}

_dk_all_installed() {
  local pkg
  for pkg in "$@"; do
    aai_pkg_installed "$pkg" || return 1
  done
}

docker_install_engine() {
  if ((DOCKER_REPO_CHANGED == 0)) && _dk_all_installed "${AAI_DOCKER_PACKAGES[@]}"; then
    aai_debug "Docker Engine este deja instalat."
  else
    if ! aai_apt_retry update || ! aai_apt_retry -y install "${AAI_DOCKER_PACKAGES[@]}"; then
      _dk EROARE "Instalarea Docker Engine a eșuat" "Verificați jurnalul și accesul la download.docker.com."
      return 1
    fi
  fi
  if ! aai_run systemctl enable --now docker; then
    _dk EROARE "Serviciul docker nu pornește" "Verificați: sudo journalctl -u docker --no-pager | tail -50"
    return 1
  fi
}

# Adds log rotation to /etc/docker/daemon.json (keeps everything else) and
# restarts Docker only if the file changed.
docker_configure_daemon() {
  local current merged
  if ! aai_have jq; then
    aai_is_dry_run && { printf '  • (dry-run) adaug rotația logurilor în %s\n' "$AAI_DOCKER_DAEMON_JSON"; return 0; }
    _dk EROARE "Lipsește jq" "sudo apt-get install -y jq"
    return 1
  fi
  current='{}'
  [[ -s "$AAI_DOCKER_DAEMON_JSON" ]] && current=$(<"$AAI_DOCKER_DAEMON_JSON")
  if ! merged=$(docker_merge_daemon_json <<<"$current" 2>/dev/null); then
    _dk EROARE "${AAI_DOCKER_DAEMON_JSON} nu este JSON valid" "Corectați fișierul (verificare: jq . ${AAI_DOCKER_DAEMON_JSON})."
    return 1
  fi
  if [[ "$(jq -S . <<<"$current")" == "$merged" ]]; then
    return 0
  fi
  aai_write_file "$AAI_DOCKER_DAEMON_JSON" 644 <<<"$merged" || return 1
  if ! aai_run systemctl restart docker; then
    _dk EROARE "Docker nu repornește după modificarea ${AAI_DOCKER_DAEMON_JSON}" \
      "Verificați: sudo journalctl -u docker --no-pager | tail -50"
    return 1
  fi
}

docker_verify() {
  local compose_version
  if ! aai_is_dry_run; then
    if ! compose_version=$(docker compose version --short 2>/dev/null); then
      _dk EROARE "Pluginul Docker Compose v2 lipsește" "sudo apt-get install -y docker-compose-plugin"
      return 1
    fi
  fi
  if ! aai_retry 3 5 aai_run docker run --rm hello-world; then
    _dk EROARE "docker run hello-world a eșuat" \
      "Verificați accesul la registry-1.docker.io și: sudo journalctl -u docker --no-pager | tail -50"
    return 1
  fi
  _dk OK "Docker Engine funcțional (docker run hello-world OK${compose_version:+; Compose $compose_version})"
}

docker_install_all() {
  docker_check_no_desktop &&
    docker_remove_conflicts &&
    docker_setup_repo &&
    docker_install_engine &&
    docker_configure_daemon &&
    docker_verify
}

# ---------------------------------------------------------------------------
# NVIDIA (GPU profile)
# ---------------------------------------------------------------------------

_nv_installed_driver_packages() {
  dpkg-query -W -f='${Package} ${Status}\n' 'nvidia-headless-*' 'nvidia-driver-*' 2>/dev/null |
    awk '/install ok installed$/ { print $1 }'
}

_nv_need_reboot() {
  aai_is_dry_run && {
    printf '  • (dry-run) după instalarea driverului, kitul s-ar opri și ar cere repornirea serverului\n'
    return 0
  }
  # shellcheck disable=SC2034  # read by install.sh
  AAI_STOP_REASON=reboot
  _dk AVERTISMENT "Driverul NVIDIA este instalat, dar e nevoie de repornirea serverului" \
    "Reporniți serverul (sudo reboot), apoi rulați din nou aceeași comandă de instalare."
}

nvidia_ensure_driver() {
  local version utils
  if aai_have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    _dk OK "Driver NVIDIA funcțional (versiunea ${version:-necunoscută})"
    return 0
  fi
  if [[ -n "$(_nv_installed_driver_packages)" ]] && ! aai_is_dry_run; then
    _nv_need_reboot
    return 0
  fi
  if ! aai_apt_retry -y install ubuntu-drivers-common ||
    ! aai_run ubuntu-drivers install --gpgpu ${AAI_NVIDIA_DRIVER:+"nvidia:${AAI_NVIDIA_DRIVER}"}; then
    _dk EROARE "Instalarea driverului NVIDIA a eșuat" \
      "Verificați: ubuntu-drivers list --gpgpu; puteți fixa versiunea cu AAI_NVIDIA_DRIVER=570-server."
    return 1
  fi
  if ! aai_is_dry_run; then
    utils=$(_nv_installed_driver_packages | nvidia_utils_package_for)
    if [[ -n "$utils" ]] && ! aai_apt_retry -y install "$utils"; then
      _dk EROARE "Nu pot instala $utils (nvidia-smi)" "Rulați manual: sudo apt-get install -y $utils"
      return 1
    fi
  fi
  _nv_need_reboot
}

nvidia_install_toolkit() {
  local key rc=0 changed=0 before after
  if aai_is_dry_run; then
    aai_run curl -fsSL -o "$AAI_NVIDIA_KEYRING" "$AAI_NVIDIA_GPG_URL"
  else
    key=$(_dk_fetch_key "$AAI_NVIDIA_GPG_URL" "$AAI_NVIDIA_GPG_FPR") || rc=$?
    if ((rc != 0)); then
      _dk EROARE "Nu pot descărca (sau verifica) cheia GPG NVIDIA" "Verificați accesul la nvidia.github.io."
      return 1
    fi
    if ! aai_write_file "$AAI_NVIDIA_KEYRING" 644 < <(gpg --batch --yes --dearmor <"$key"); then
      rm -f -- "$key"
      return 1
    fi
    rm -f -- "$key"
    changed=$AAI_FILE_CHANGED
  fi
  aai_write_file "${AAI_APT_SOURCES_DIR}/nvidia-container-toolkit.list" 644 < <(nvidia_sources) || return 1
  ((AAI_FILE_CHANGED)) && changed=1
  if ((changed == 1)) || ! aai_pkg_installed nvidia-container-toolkit; then
    if ! aai_apt_retry update || ! aai_apt_retry -y install nvidia-container-toolkit; then
      _dk EROARE "Instalarea NVIDIA Container Toolkit a eșuat" "Verificați jurnalul și accesul la nvidia.github.io."
      return 1
    fi
  fi
  before=$(cksum "$AAI_DOCKER_DAEMON_JSON" 2>/dev/null || true)
  if ! aai_run nvidia-ctk runtime configure --runtime=docker; then
    _dk EROARE "nvidia-ctk nu a putut configura Docker" "Rulați manual: sudo nvidia-ctk runtime configure --runtime=docker"
    return 1
  fi
  after=$(cksum "$AAI_DOCKER_DAEMON_JSON" 2>/dev/null || true)
  if [[ "$before" != "$after" ]] && ! aai_run systemctl restart docker; then
    _dk EROARE "Docker nu repornește după configurarea NVIDIA" "Verificați: sudo journalctl -u docker --no-pager | tail -50"
    return 1
  fi
}

nvidia_verify_container() {
  if ! aai_retry 2 5 aai_run docker run --rm --gpus all "$AAI_GPU_TEST_IMAGE" nvidia-smi -L; then
    _dk EROARE "Containerul de test nu vede placa NVIDIA" \
      "Verificați: sudo docker run --rm --gpus all ${AAI_GPU_TEST_IMAGE} nvidia-smi și jurnalul."
    return 1
  fi
  _dk OK "Containerele Docker văd placa NVIDIA (docker run --gpus all ... nvidia-smi OK)"
}
