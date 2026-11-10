#!/usr/bin/env bash
#
# tests/vm/multipass-test.sh - runs the installer in a clean Ubuntu 24.04 VM
# (Multipass), CPU profile, twice: the second run checks idempotency.
#
# Usage: tests/vm/multipass-test.sh [--stages P0,P1] [--keep] [--name <vm>]
#                                   [--yes] [--check-deps]
#
# First checks that make and multipass are installed. A missing tool is
# installed (snap/apt on Linux, Homebrew on macOS) when the script has the
# rights to do it (root or sudo) and the operator confirms, or --yes is
# given; otherwise it prints the command to run. --check-deps stops after
# this check.
#
# Environment: AAI_VM_CPUS (4), AAI_VM_MEMORY (16G), AAI_VM_DISK (80G).
# With less than 16G (e.g. AAI_VM_MEMORY=8G on a small host) the P0 RAM
# threshold is lowered inside the VM so P0/P1 can still be tested; later
# stages (Dify + model) need more than 12 GB.
# Exit code 0 = all checks passed.

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VM_NAME="aai-test-$(date +%Y%m%d-%H%M%S)"
STAGES='P0,P1'
KEEP=0
VM_CPUS=${AAI_VM_CPUS:-4}
VM_MEMORY=${AAI_VM_MEMORY:-16G}
VM_DISK=${AAI_VM_DISK:-80G}
KIT_DIR=/home/ubuntu/kit
FAILURES=0
INSTALL_ENV=()
ASSUME_YES=0
CHECK_DEPS_ONLY=0
REQUIRED_TOOLS=(make multipass)

say() { printf '\n== %s ==\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() {
  printf '[EROARE] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --stages) STAGES=$2; shift 2 ;;
      --keep) KEEP=1; shift ;;
      --name) VM_NAME=$2; shift 2 ;;
      --yes | -y) ASSUME_YES=1; shift ;;
      --check-deps) CHECK_DEPS_ONLY=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'Opțiune necunoscută: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Host prerequisites: make, multipass
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Snap installs binaries in /snap/bin, which may not be on PATH yet.
[[ -d /snap/bin && ":$PATH:" != *:/snap/bin:* ]] && PATH="$PATH:/snap/bin"

# Prints the shell commands that install a tool on this host, one per line;
# nothing if the host has no supported package manager.
install_commands() {
  local tool=$1
  case "$(uname -s)" in
    Darwin)
      have brew || return 0
      case "$tool" in
        multipass) printf 'brew install --cask multipass\n' ;;
        make) printf 'xcode-select --install\n' ;;
      esac
      ;;
    Linux)
      case "$tool" in
        multipass) have snap && printf 'snap install multipass\n' ;;
        make)
          if have apt-get; then
            printf 'apt-get update\napt-get install -y make\n'
          elif have dnf; then
            printf 'dnf install -y make\n'
          fi
          ;;
      esac
      ;;
  esac
  return 0
}

manual_hint() {
  case "$1" in
    multipass) printf 'instrucțiuni: https://canonical.com/multipass/install' ;;
    make) printf 'instalați pachetul „make” cu managerul de pachete al sistemului' ;;
  esac
}

# Sets PRIV to the prefix needed for system-wide installs: empty when root
# (or on macOS, where Homebrew must not run as root), "sudo" when available.
# Returns 1 when the script cannot get the rights.
privilege_prefix() {
  PRIV=()
  [[ "$(uname -s)" == Darwin || "$EUID" -eq 0 ]] && return 0
  have sudo || return 1
  PRIV=(sudo)
}

confirm() {
  local answer
  ((ASSUME_YES == 1)) && return 0
  [[ -t 0 ]] || return 1
  read -r -p "$1 [d/N] " answer || return 1
  [[ "${answer,,}" == d || "${answer,,}" == da || "${answer,,}" == y || "${answer,,}" == yes ]]
}

# Waits until the multipass daemon answers (it starts after the snap install).
wait_for_multipass() {
  local i
  for ((i = 0; i < 30; i++)); do
    multipass version >/dev/null 2>&1 && multipass list >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Prefixes every line of $2 with $1.
indent() {
  local prefix=$1 text=$2
  printf '%s%s' "$prefix" "${text//$'\n'/$'\n'$prefix}"
}

# Installs one tool. Returns 1 if it is still missing afterwards.
install_tool() {
  local tool=$1 cmds line shown
  cmds=$(install_commands "$tool")
  if [[ -z "$cmds" ]]; then
    printf '[EROARE] Lipsește %s și nu îl pot instala automat pe acest sistem (%s).\n' "$tool" "$(manual_hint "$tool")" >&2
    return 1
  fi
  if ! privilege_prefix; then
    printf '[EROARE] Lipsește %s; pentru instalare e nevoie de root sau sudo. Rulați ca root:\n%s\n' \
      "$tool" "$(indent '    ' "$cmds")" >&2
    return 1
  fi
  shown=$(indent "    ${PRIV[*]:+${PRIV[*]} }" "$cmds")
  if ! confirm "Lipsește ${tool}. Îl instalez acum cu:"$'\n'"${shown}"$'\n'"Continuați?"; then
    printf '[EROARE] Lipsește %s. Instalați-l cu:\n%s\n' "$tool" "$shown" >&2
    printf '  (sau rulați din nou cu --yes ca să-l instaleze scriptul)\n' >&2
    return 1
  fi
  printf '[INFO] Instalez %s...\n' "$tool"
  while IFS= read -r line; do
    # The commands come from install_commands above, never from user input.
    if ! "${PRIV[@]}" bash -c "$line"; then
      printf '[EROARE] Comanda a eșuat: %s\n' "$line" >&2
      return 1
    fi
  done <<<"$cmds"
  if ! have "$tool"; then
    printf '[EROARE] %s tot nu este disponibil după instalare (deschideți un terminal nou și reîncercați).\n' "$tool" >&2
    return 1
  fi
  if [[ "$tool" == multipass ]] && ! wait_for_multipass; then
    printf '[EROARE] multipass este instalat, dar serviciul nu răspunde încă (reîncercați în câteva minute).\n' >&2
    return 1
  fi
  printf '[OK] %s instalat\n' "$tool"
}

check_prerequisites() {
  local tool missing=0
  say "Verific programele necesare: ${REQUIRED_TOOLS[*]}"
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if have "$tool"; then
      ok "$tool este instalat"
    elif ! install_tool "$tool"; then
      missing=$((missing + 1))
    fi
  done
  if ((missing > 0)); then
    printf '[EROARE] Testul în VM nu poate porni: lipsesc programe necesare (vezi mai sus).\n' >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------

vm() { multipass exec "$VM_NAME" -- "$@"; }

cleanup() {
  if ((KEEP == 1)); then
    printf '\nVM-ul %s a fost păstrat (multipass shell %s; ștergere: multipass delete --purge %s).\n' \
      "$VM_NAME" "$VM_NAME" "$VM_NAME"
  else
    multipass delete --purge "$VM_NAME" >/dev/null 2>&1 || true
  fi
}

# Converts a Multipass size (8G, 8192M, 16GiB) to MiB.
size_to_mib() {
  local v=${1^^}
  v=${v%IB}
  v=${v%B}
  case "$v" in
    *G) printf '%s' "$((${v%G} * 1024))" ;;
    *M) printf '%s' "${v%M}" ;;
    *K) printf '%s' "$((${v%K} / 1024))" ;;
    *) printf '%s' "$((v / 1048576))" ;;
  esac
}

# Fails early (with advice) when the host cannot give the VM its memory.
check_host_memory() {
  local want avail_kb avail
  want=$(size_to_mib "$VM_MEMORY")
  [[ -r /proc/meminfo ]] || return 0   # macOS: let Multipass decide
  avail_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
  avail=$((avail_kb / 1024))
  if ((avail < want + 1024)); then
    printf '[EROARE] Gazda are doar %s MiB RAM disponibili; VM-ul cere %s MiB.\n' "$avail" "$want" >&2
    printf '→ Ce trebuie făcut: închideți alte aplicații/VM-uri sau rulați cu mai puțină memorie, ex.:\n' >&2
    printf '    AAI_VM_MEMORY=%sM %s\n' "$(((avail - 1024) / 512 * 512))" "$0" >&2
    printf '  (pentru P0/P1 ajung 4–8 GB; etapele următoare cer cel puțin 16 GB)\n' >&2
    exit 2
  fi
}

# Below 16G the P0 RAM check would stop the installer; lower its threshold
# for this test only (MemTotal is a bit under the nominal size).
set_install_env() {
  local mib
  mib=$(size_to_mib "$VM_MEMORY")
  if ((mib < 16384)); then
    INSTALL_ENV=("AAI_RAM_MIN_MIB=$((mib * 3 / 4))")
    printf '[AVERTISMENT] VM cu %s RAM: pragul de RAM din P0 e coborât la %s MiB doar pentru acest test.\n' \
      "$VM_MEMORY" "$((mib * 3 / 4))"
  fi
}

launch_vm() {
  say "Pornesc VM-ul $VM_NAME (Ubuntu 24.04, ${VM_CPUS} CPU, ${VM_MEMORY} RAM, ${VM_DISK} disc)"
  # Set before launch so a VM that fails to start is removed as well.
  trap cleanup EXIT
  if ! multipass launch 24.04 --name "$VM_NAME" --cpus "$VM_CPUS" --memory "$VM_MEMORY" --disk "$VM_DISK"; then
    printf '[EROARE] VM-ul nu a pornit (vezi mesajul Multipass de mai sus).\n' >&2
    printf '→ Ce trebuie făcut: dacă eroarea e „Cannot allocate memory”, rulați cu mai puțină memorie, ex. AAI_VM_MEMORY=8G.\n' >&2
    KEEP=0
    exit 2
  fi
}

copy_kit() {
  local archive
  say "Copiez kitul în VM"
  archive=$(mktemp --suffix=.tar.gz)
  tar -C "$ROOT" --exclude=.git --exclude='./clients/*' -czf "$archive" .
  multipass transfer "$archive" "$VM_NAME:/home/ubuntu/kit.tar.gz"
  rm -f -- "$archive"
  vm bash -c "mkdir -p $KIT_DIR && tar -C $KIT_DIR -xzf /home/ubuntu/kit.tar.gz"
}

# Runs the installer in the VM. Usage: run_install <label>
run_install() {
  local label=$1 rc=0
  say "Rulare $label: install.sh --only $STAGES"
  vm sudo env "${INSTALL_ENV[@]}" "$KIT_DIR/install.sh" --config "$KIT_DIR/config/client.example.yaml" \
    --only "$STAGES" --non-interactive \
    --set inference.profile=cpu --set tls.mode=none --set domain=asistent.example.test \
    --set admin.allowed_ips=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 || rc=$?
  if ((rc == 0)); then
    ok "Rularea $label s-a terminat cu cod 0"
  else
    fail "Rularea $label s-a terminat cu cod $rc"
  fi
}

# Files P1 manages; their checksums must not change on the second run.
fingerprint_state() {
  vm sudo bash -c 'sha256sum /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc /etc/docker/daemon.json 2>/dev/null; ufw status numbered | grep -c "^\[" || true'
}

check_p1() {
  local rules
  say "Verific rezultatul P1"
  if vm sudo docker run --rm hello-world >/dev/null 2>&1; then ok "docker run hello-world"; else fail "docker run hello-world"; fi
  if vm docker compose version >/dev/null 2>&1; then ok "Docker Compose v2"; else fail "Docker Compose v2 lipsește"; fi
  if vm sudo ufw status | grep -q '^Status: active'; then ok "ufw activ"; else fail "ufw nu este activ"; fi
  rules=$(vm sudo ufw status | awk '/ALLOW/ { print $1 }' | sed 's#/tcp##; s# (v6)##' | sort -un | paste -sd ',' -)
  if [[ "$rules" == 22,80,443 ]]; then ok "ufw permite doar 22, 80, 443"; else fail "ufw permite: $rules"; fi
  if vm sudo dpkg-query -W docker-desktop >/dev/null 2>&1; then fail "Docker Desktop instalat"; else ok "fără Docker Desktop"; fi
  if [[ "$(vm sudo jq -r '."log-opts"."max-size"' /etc/docker/daemon.json)" == 50m ]]; then
    ok "rotația logurilor Docker configurată"
  else
    fail "rotația logurilor Docker lipsește din /etc/docker/daemon.json"
  fi
}

check_log() {
  local mode
  say "Verific jurnalul"
  mode=$(vm sudo stat -c %a /var/log/asistent-ai/install.log 2>/dev/null || echo lipsă)
  if [[ "$mode" == 640 ]]; then ok "jurnal /var/log/asistent-ai/install.log (640)"; else fail "jurnal: $mode"; fi
  if vm sudo grep -Eq '[0-9a-fA-F]{32,}' /var/log/asistent-ai/install.log; then
    fail "jurnalul conține șiruri care arată a secrete"
  else
    ok "jurnalul nu conține secrete"
  fi
}

main() {
  local before after
  parse_args "$@"
  check_prerequisites
  ((CHECK_DEPS_ONLY == 1)) && exit 0
  check_host_memory
  set_install_env
  launch_vm
  copy_kit
  run_install "1"
  [[ "$STAGES" == *P1* ]] && check_p1
  before=$(fingerprint_state)
  run_install "2 (idempotență)"
  after=$(fingerprint_state)
  if [[ "$before" == "$after" ]]; then
    ok "A doua rulare nu a modificat fișierele gestionate și regulile ufw"
  else
    fail "A doua rulare a modificat starea:"$'\n'"$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  fi
  check_log
  say "Rezultat"
  if ((FAILURES == 0)); then
    ok "Toate verificările au trecut"
  else
    fail "$FAILURES verificări au eșuat"
    exit 1
  fi
}

main "$@"
