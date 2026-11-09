#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/preflight.sh - P0: read-only checks of the target server (SPEC.md §4.1).
#
# Every check records OK / AVERTISMENT / EROARE in the summary under "P0".
# Nothing here modifies the system, so P0 also runs in --dry-run (except the
# ~50 MB download test, which is only announced).
#
# Inputs that tests override:
#   AAI_OS_RELEASE_FILE, AAI_MEMINFO_FILE, AAI_SYSFS_PCI and PATH stubs for
#   uname, nproc, df, nvidia-smi, ss, getent, hostname, curl, ip.

if [[ -n "${AAI_PREFLIGHT_LOADED:-}" ]]; then
  return 0
fi
AAI_PREFLIGHT_LOADED=1

: "${AAI_OS_RELEASE_FILE:=/etc/os-release}"
: "${AAI_MEMINFO_FILE:=/proc/meminfo}"
: "${AAI_SYSFS_PCI:=/sys/bus/pci/devices}"
# Thresholds. RAM in MiB (MemTotal reports a bit less than the nominal size),
# disk in decimal GB, VRAM in MiB ("24 GB" cards report ~24 GiB minus reserve).
: "${AAI_RAM_OK_MIB:=30720}"
: "${AAI_RAM_MIN_MIB:=15360}"
: "${AAI_DISK_OK_GB:=180}"
: "${AAI_DISK_MIN_GB:=50}"
: "${AAI_CPU_OK_CORES:=8}"
: "${AAI_MIN_VRAM_MIB:=23000}"
# Download test: a large file from Hugging Face (where GPU models come from),
# fetched with a byte range. The size cap protects against servers that
# ignore ranges.
: "${AAI_DOWNLOAD_TEST_URL:=https://huggingface.co/BAAI/bge-m3/resolve/main/pytorch_model.bin}"
: "${AAI_DOWNLOAD_TEST_BYTES:=52428800}"
: "${AAI_DOWNLOAD_MIN_MBPS:=1}"
: "${AAI_PUBLIC_IP_URLS:=https://api.ipify.org https://ifconfig.me/ip}"

# Results of GPU detection and profile resolution, used by later stages.
AAI_GPU_PRESENT=0      # an NVIDIA device is on the PCI bus
AAI_GPU_DRIVER=0       # nvidia-smi works
AAI_GPU_COUNT=0
AAI_GPU_VRAM_MIB=0     # total over all cards
AAI_GPU_NAMES=''
AAI_PROFILE=''         # effective profile: cpu | gpu

_pf() { aai_check "$1" P0 "${@:2}"; }

# ---------------------------------------------------------------------------
# OS, architecture, RAM, disk, CPU
# ---------------------------------------------------------------------------

# Prints the value of KEY from an os-release file (without quotes).
_pf_os_field() {
  local key=$1 line value=''
  [[ -r "$AAI_OS_RELEASE_FILE" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" == "$key="* ]]; then
      value=${line#*=}
      value=${value#\"}
      value=${value%\"}
    fi
  done <"$AAI_OS_RELEASE_FILE"
  printf '%s' "$value"
}

preflight_check_os() {
  local id ver pretty
  id=$(_pf_os_field ID)
  ver=$(_pf_os_field VERSION_ID)
  pretty=$(_pf_os_field PRETTY_NAME)
  if [[ "$id" == ubuntu && "$ver" == 24.04 ]]; then
    _pf OK "Sistem de operare: ${pretty:-Ubuntu 24.04}"
  elif [[ "$id" == ubuntu ]]; then
    _pf AVERTISMENT "Sistem de operare: ${pretty:-Ubuntu $ver} (kitul este testat doar pe Ubuntu 24.04)" \
      "Recomandat: Ubuntu Server 24.04 LTS, instalare curată."
  else
    _pf EROARE "Sistem de operare nesuportat: ${pretty:-necunoscut}" \
      "Instalați Ubuntu Server 24.04 LTS (x86_64)."
  fi
}

preflight_check_arch() {
  local arch
  arch=$(uname -m)
  if [[ "$arch" == x86_64 ]]; then
    _pf OK "Arhitectură: x86_64"
  else
    _pf EROARE "Arhitectură nesuportată: $arch" "Folosiți un server x86_64 (amd64)."
  fi
}

# Formats MiB as GB with one decimal (binary GiB, as shown by `free -g`).
_pf_mib_to_gb() {
  awk -v m="$1" 'BEGIN { printf "%.1f", m / 1024 }'
}

preflight_check_ram() {
  local kb mib gb
  kb=$(awk '/^MemTotal:/ { print $2 }' "$AAI_MEMINFO_FILE" 2>/dev/null || true)
  if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
    _pf AVERTISMENT "Nu pot determina memoria RAM." "Verificați manual: free -g (minim recomandat 32 GB)."
    return 0
  fi
  mib=$((kb / 1024))
  gb=$(_pf_mib_to_gb "$mib")
  if ((mib >= AAI_RAM_OK_MIB)); then
    _pf OK "RAM: ${gb} GB"
  elif ((mib >= AAI_RAM_MIN_MIB)); then
    _pf AVERTISMENT "RAM: ${gb} GB (recomandat cel puțin 32 GB)" \
      "Suficient doar pentru teste cu modele mici; pentru producție măriți memoria la 32 GB sau mai mult."
  else
    _pf EROARE "RAM: ${gb} GB, insuficient (Dify + un model 8B au nevoie de peste 12 GB)" \
      "Măriți memoria serverului la cel puțin 16 GB (recomandat 32 GB)."
  fi
}

# Prints the deepest existing directory of a path (df needs an existing one).
_pf_existing_parent() {
  local p=$1
  while [[ ! -e "$p" && "$p" != / ]]; do
    p=$(dirname -- "$p")
  done
  printf '%s' "$p"
}

# Prints "<filesystem> <available bytes> <mount point>" for a path.
_pf_df() {
  { df -P -B1 -- "$1" 2>/dev/null || true; } | awk 'NR == 2 { print $1, $4, $6 }'
}

_pf_check_disk_path() {
  local label=$1 path=$2 avail mnt gb
  read -r _ avail mnt <<<"$(_pf_df "$(_pf_existing_parent "$path")")"
  if [[ ! "${avail:-}" =~ ^[0-9]+$ ]]; then
    _pf AVERTISMENT "Nu pot determina spațiul liber pentru $path." "Verificați manual: df -h $path"
    return 0
  fi
  gb=$((avail / 1000000000))
  if ((gb >= AAI_DISK_OK_GB)); then
    _pf OK "Disc liber pentru ${label}: ${gb} GB (${mnt})"
  elif ((gb >= AAI_DISK_MIN_GB)); then
    _pf AVERTISMENT "Disc liber pentru ${label}: ${gb} GB pe ${mnt} (recomandat cel puțin 200 GB)" \
      "Suficient pentru teste; pentru producție (modele, imagini, backup-uri) folosiți un disc de 200 GB sau mai mare."
  else
    _pf EROARE "Disc liber pentru ${label}: ${gb} GB pe ${mnt}, insuficient" \
      "Eliberați spațiu sau măriți discul (minim ${AAI_DISK_MIN_GB} GB liberi, recomandat 200 GB)."
  fi
}

# Checks the kit's directory and Docker's data directory (once if they share
# the same filesystem).
preflight_check_disk() {
  local fs_install fs_docker
  _pf_check_disk_path "${AAI_INSTALL_DIR}" "${AAI_INSTALL_DIR}"
  read -r fs_install _ <<<"$(_pf_df "$(_pf_existing_parent "${AAI_INSTALL_DIR}")")"
  read -r fs_docker _ <<<"$(_pf_df "$(_pf_existing_parent /var/lib/docker)")"
  if [[ -n "${fs_docker:-}" && "${fs_docker}" != "${fs_install:-}" ]]; then
    _pf_check_disk_path "Docker (/var/lib/docker)" /var/lib/docker
  fi
}

preflight_check_cpu() {
  local cores
  cores=$(nproc 2>/dev/null || echo 0)
  if ((cores >= AAI_CPU_OK_CORES)); then
    _pf OK "Procesor: ${cores} nuclee"
  else
    _pf AVERTISMENT "Procesor: ${cores} nuclee (recomandat cel puțin ${AAI_CPU_OK_CORES})" \
      "Funcționează, dar indexarea documentelor și profilul CPU vor fi lente."
  fi
}

# ---------------------------------------------------------------------------
# GPU and inference profile
# ---------------------------------------------------------------------------

# True when an NVIDIA display/3D controller is on the PCI bus (vendor 0x10de,
# class 0x03xxxx). Uses sysfs, so it works without pciutils or a driver.
_pf_nvidia_on_pci() {
  local dev vendor class
  for dev in "${AAI_SYSFS_PCI}"/*; do
    [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
    vendor=$(<"$dev/vendor")
    class=$(<"$dev/class")
    [[ "$vendor" == 0x10de && "$class" == 0x03* ]] && return 0
  done
  return 1
}

# Fills the AAI_GPU_* variables. Never fails.
preflight_detect_gpu() {
  local out line name mem
  AAI_GPU_PRESENT=0 AAI_GPU_DRIVER=0 AAI_GPU_COUNT=0 AAI_GPU_VRAM_MIB=0 AAI_GPU_NAMES=''
  if aai_have nvidia-smi &&
    out=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null) &&
    [[ -n "$out" ]]; then
    AAI_GPU_PRESENT=1 AAI_GPU_DRIVER=1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name=${line%,*}
      mem=${line##*,}
      mem=${mem//[[:space:]]/}
      [[ "$mem" =~ ^[0-9]+$ ]] || continue
      AAI_GPU_COUNT=$((AAI_GPU_COUNT + 1))
      AAI_GPU_VRAM_MIB=$((AAI_GPU_VRAM_MIB + mem))
      AAI_GPU_NAMES+="${AAI_GPU_NAMES:+, }${name}"
    done <<<"$out"
  elif _pf_nvidia_on_pci; then
    AAI_GPU_PRESENT=1
  fi
}

# Decision of preflight_resolve_profile: status, message, what to do.
AAI_PROFILE_DECISION=()

_pf_decide() {
  AAI_PROFILE=$1
  AAI_PROFILE_DECISION=("$2" "$3" "${4:-}")
}

# Decides AAI_PROFILE from inference.profile and the detected GPU and stores
# the explanation in AAI_PROFILE_DECISION.
preflight_resolve_profile() {
  local wanted vram_gb small='Vor putea rula doar modele mici; recomandat 48–80 GB VRAM.'
  local cpu_slow='Profilul CPU e lent, doar pentru demo/teste; pentru producție e nevoie de o placă NVIDIA cu 24 GB VRAM sau mai mult.'
  wanted=$(config_get inference.profile)
  vram_gb=$(_pf_mib_to_gb "$AAI_GPU_VRAM_MIB")
  case "$wanted" in
    cpu)
      _pf_decide cpu OK "Profil de inferență: cpu (ales în configurare; doar pentru demo/teste)"
      ;;
    gpu)
      if ((AAI_GPU_PRESENT == 0)); then
        _pf_decide gpu EROARE "Profil gpu cerut, dar nu am găsit nicio placă NVIDIA" \
          "Verificați placa video sau folosiți --set inference.profile=cpu (doar pentru teste)."
      elif ((AAI_GPU_DRIVER == 0)); then
        _pf_decide gpu OK "Profil de inferență: gpu (placă NVIDIA detectată; driverul se instalează în P1)"
      elif ((AAI_GPU_VRAM_MIB < AAI_MIN_VRAM_MIB)); then
        _pf_decide gpu AVERTISMENT "Profil gpu cu doar ${vram_gb} GB VRAM (${AAI_GPU_NAMES}); minimul recomandat este 24 GB" "$small"
      else
        _pf_decide gpu OK "Profil de inferență: gpu (${AAI_GPU_NAMES}, ${vram_gb} GB VRAM)"
      fi
      ;;
    *)
      if ((AAI_GPU_PRESENT == 1 && AAI_GPU_DRIVER == 0)); then
        _pf_decide gpu AVERTISMENT "Profil ales automat: gpu (placă NVIDIA fără driver; VRAM-ul se verifică după instalarea driverului)" \
          "Driverul se instalează în P1; după repornire, P0 reevaluează profilul."
      elif ((AAI_GPU_DRIVER == 1 && AAI_GPU_VRAM_MIB >= AAI_MIN_VRAM_MIB)); then
        _pf_decide gpu OK "Profil ales automat: gpu (${AAI_GPU_NAMES}, ${vram_gb} GB VRAM)"
      elif ((AAI_GPU_DRIVER == 1)); then
        _pf_decide cpu AVERTISMENT "Profil ales automat: cpu (placa ${AAI_GPU_NAMES} are doar ${vram_gb} GB VRAM, sub 24 GB)" "$cpu_slow"
      else
        _pf_decide cpu AVERTISMENT "Profil ales automat: cpu (nicio placă NVIDIA)" "$cpu_slow"
      fi
      ;;
  esac
}

preflight_check_gpu() {
  preflight_detect_gpu
  preflight_resolve_profile
  _pf "${AAI_PROFILE_DECISION[@]}"
}

# Sets AAI_PROFILE without recording anything (for stages run with --only).
preflight_ensure_profile() {
  [[ -n "$AAI_PROFILE" ]] && return 0
  preflight_detect_gpu
  preflight_resolve_profile
}

# ---------------------------------------------------------------------------
# Ports and DNS
# ---------------------------------------------------------------------------

# Prints the names of processes listening on a TCP port (one per line; "?"
# when unknown). Returns 1 if nothing listens, 2 if it cannot be determined.
preflight_port_listeners() {
  local port=$1 out
  aai_have ss || return 2
  out=$(ss -Htlnp "sport = :$port" 2>/dev/null) || return 2
  [[ -n "$out" ]] || return 1
  if grep -q 'users:' <<<"$out"; then
    grep -o 'users:(("[^"]*"' <<<"$out" | sed 's/users:(("//; s/"$//' | sort -u
  else
    printf '?\n'
  fi
}

preflight_check_ports() {
  local port procs rc
  for port in 80 443; do
    rc=0
    procs=$(preflight_port_listeners "$port") || rc=$?
    procs=$(paste -sd ',' - <<<"$procs")
    if ((rc == 1)); then
      _pf OK "Portul $port este liber"
    elif ((rc == 2)); then
      _pf AVERTISMENT "Nu pot verifica portul $port (lipsește comanda ss)" "Instalați iproute2 sau verificați manual: ss -tlnp"
    elif [[ "$procs" == docker-proxy && -d "${AAI_INSTALL_DIR}/dify" ]]; then
      _pf OK "Portul $port este folosit de instalarea existentă (Dify)"
    else
      _pf EROARE "Portul $port este ocupat de: ${procs}" \
        "Opriți serviciul care folosește portul $port (ex. systemctl disable --now apache2/nginx) și rulați din nou."
    fi
  done
}

_pf_resolve_ipv4() {
  { getent ahostsv4 "$1" 2>/dev/null || true; } | awk '{ print $1 }' | sort -u
}

_pf_local_ipv4() {
  { hostname -I 2>/dev/null || true; } | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' || true
}

# Prints the server's public IPv4 as seen from the internet (empty if unknown).
_pf_public_ipv4() {
  local url ip
  for url in ${AAI_PUBLIC_IP_URLS}; do
    ip=$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if aai_is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
}

preflight_check_dns() {
  local domain resolved local_ips public_ip ip
  domain=$(config_get domain)
  resolved=$(_pf_resolve_ipv4 "$domain")
  if [[ -z "$resolved" ]]; then
    if [[ "$(config_get tls.mode)" == letsencrypt ]]; then
      _pf EROARE "Domeniul $domain nu rezolvă la nicio adresă IPv4" \
        "Cereți IT-ului clientului înregistrarea DNS de tip A pentru $domain (Let's Encrypt nu poate emite certificatul fără ea)."
    else
      _pf AVERTISMENT "Domeniul $domain nu rezolvă la nicio adresă IPv4" \
        "Creați înregistrarea DNS de tip A pentru $domain înainte de punerea în funcțiune."
    fi
    return 0
  fi
  local_ips=$(_pf_local_ipv4)
  public_ip=$(_pf_public_ipv4)
  while IFS= read -r ip; do
    if [[ -n "$ip" && ( "$ip" == "$public_ip" ) ]] || grep -qxF -- "$ip" <<<"$local_ips"; then
      _pf OK "Domeniul $domain rezolvă la $ip (acest server)"
      return 0
    fi
  done <<<"$resolved"
  _pf AVERTISMENT "Domeniul $domain rezolvă la $(paste -sd ',' - <<<"$resolved"), dar IP-ul public al serverului este ${public_ip:-necunoscut}" \
    "Normal dacă se folosește reverse proxy-ul clientului; altfel corectați înregistrarea DNS (Let's Encrypt va eșua)."
}

# ---------------------------------------------------------------------------
# Outbound connectivity
# ---------------------------------------------------------------------------

# Endpoints the installation needs, by profile.
preflight_endpoints() {
  printf '%s\n' \
    https://download.docker.com/linux/ubuntu/gpg \
    https://registry-1.docker.io/v2/ \
    https://github.com/
  if [[ "$AAI_PROFILE" == gpu ]]; then
    printf '%s\n' https://huggingface.co/ https://nvidia.github.io/libnvidia-container/gpgkey
  else
    printf '%s\n' https://registry.ollama.ai/v2/
  fi
}

# True if the URL answers with any HTTP status (401/404 still mean reachable).
_pf_reachable() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null) || true
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]
}

# Default network interface (for the ethtool advice).
_pf_default_iface() {
  local iface
  iface=$({ ip route show default 2>/dev/null || true; } | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  printf '%s' "${iface:-eth0}"
}

preflight_bad_record_mac_advice() {
  local iface
  iface=$(_pf_default_iface)
  printf 'Eroare TLS „bad record MAC” (problemă cunoscută la plăcile de rețea virtuale, ex. WSL/VM): rulați sudo ethtool -K %s tx off rx off și reluați instalarea.' "$iface"
}

preflight_check_endpoints() {
  local url failed=()
  while IFS= read -r url; do
    _pf_reachable "$url" || failed+=("$url")
  done < <(preflight_endpoints)
  if ((${#failed[@]} == 0)); then
    _pf OK "Conectivitate de ieșire: toate serviciile necesare răspund"
  else
    _pf EROARE "Servicii inaccesibile: ${failed[*]}" \
      "Permiteți accesul HTTPS de ieșire către aceste adrese (firewall/proxy al clientului)."
  fi
}

# Downloads ~50 MB and reports the speed. Skipped in dry-run.
preflight_check_download() {
  local err out size speed mbps status_on_fail=EROARE rc=0
  [[ "$AAI_PROFILE" == cpu ]] && status_on_fail=AVERTISMENT
  if aai_is_dry_run; then
    printf '  • (dry-run) descarc ~%s MB de la %s pentru testul de viteză\n' \
      "$((AAI_DOWNLOAD_TEST_BYTES / 1048576))" "${AAI_DOWNLOAD_TEST_URL%%/resolve/*}"
    return 0
  fi
  err=$(mktemp)
  out=$(curl -fsSL --retry 2 --max-time 300 --range "0-$((AAI_DOWNLOAD_TEST_BYTES - 1))" \
    --max-filesize $((AAI_DOWNLOAD_TEST_BYTES + 10485760)) -o /dev/null \
    -w '%{size_download} %{speed_download}' "$AAI_DOWNLOAD_TEST_URL" 2>"$err") || rc=$?
  if ((rc != 0)); then
    if grep -qi 'bad record mac' "$err"; then
      _pf "$status_on_fail" "Testul de descărcare a eșuat: bad record MAC" "$(preflight_bad_record_mac_advice)"
    else
      _pf "$status_on_fail" "Testul de descărcare a eșuat (curl cod $rc: $(head -c 200 "$err" | tr '\n' ' '))" \
        "Verificați accesul la ${AAI_DOWNLOAD_TEST_URL%%/resolve/*} și stabilitatea conexiunii."
    fi
    rm -f -- "$err"
    return 0
  fi
  rm -f -- "$err"
  read -r size speed <<<"$out"
  mbps=$(awk -v s="${speed:-0}" 'BEGIN { printf "%.1f", s / 1048576 }')
  if ((${size%.*} < AAI_DOWNLOAD_TEST_BYTES * 9 / 10)); then
    _pf AVERTISMENT "Testul de descărcare a primit doar ${size} octeți" "Verificați conexiunea; descărcările mari pot eșua."
  elif awk -v m="$mbps" -v min="$AAI_DOWNLOAD_MIN_MBPS" 'BEGIN { exit !(m < min) }'; then
    _pf AVERTISMENT "Descărcare lentă: ${mbps} MB/s" "Descărcarea modelelor (zeci de GB) va dura mult; verificați conexiunea."
  else
    _pf OK "Test de descărcare: $((size / 1048576)) MB la ${mbps} MB/s"
  fi
}

# ---------------------------------------------------------------------------

preflight_run() {
  preflight_check_os
  preflight_check_arch
  preflight_check_ram
  preflight_check_disk
  preflight_check_cpu
  preflight_check_gpu
  preflight_check_ports
  preflight_check_dns
  preflight_check_endpoints
  preflight_check_download
}
