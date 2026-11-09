#!/usr/bin/env bash
#
# tests/vm/multipass-test.sh - runs the installer in a clean Ubuntu 24.04 VM
# (Multipass), CPU profile, twice: the second run checks idempotency.
#
# Usage: tests/vm/multipass-test.sh [--stages P0,P1] [--keep] [--name <vm>]
#
# Environment: AAI_VM_CPUS (4), AAI_VM_MEMORY (16G), AAI_VM_DISK (80G).
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

say() { printf '\n== %s ==\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() {
  printf '[EROARE] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --stages) STAGES=$2; shift 2 ;;
      --keep) KEEP=1; shift ;;
      --name) VM_NAME=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) printf 'Opțiune necunoscută: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
}

vm() { multipass exec "$VM_NAME" -- "$@"; }

cleanup() {
  if ((KEEP == 1)); then
    printf '\nVM-ul %s a fost păstrat (multipass shell %s; ștergere: multipass delete --purge %s).\n' \
      "$VM_NAME" "$VM_NAME" "$VM_NAME"
  else
    multipass delete --purge "$VM_NAME" >/dev/null 2>&1 || true
  fi
}

launch_vm() {
  say "Pornesc VM-ul $VM_NAME (Ubuntu 24.04, ${VM_CPUS} CPU, ${VM_MEMORY} RAM, ${VM_DISK} disc)"
  multipass launch 24.04 --name "$VM_NAME" --cpus "$VM_CPUS" --memory "$VM_MEMORY" --disk "$VM_DISK"
  trap cleanup EXIT
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
  vm sudo "$KIT_DIR/install.sh" --config "$KIT_DIR/config/client.example.yaml" \
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
  command -v multipass >/dev/null || { printf 'Lipsește multipass: sudo snap install multipass\n' >&2; exit 2; }
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
