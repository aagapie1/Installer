# shellcheck shell=bash
# Shared setup for unit tests: sources the libraries with a temporary log dir.

AAI_ROOT=$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)
export AAI_ROOT
export LC_ALL=C.UTF-8
export NO_COLOR=1

aai_test_setup() {
  export AAI_LOG_DIR="${BATS_TEST_TMPDIR}/log"
  export AAI_LOG_FILE="${AAI_LOG_DIR}/install.log"
  export AAI_LOCK_FILE="${BATS_TEST_TMPDIR}/install.lock"
  # shellcheck source=../../lib/common.sh
  source "${AAI_ROOT}/lib/common.sh"
  # shellcheck source=../../lib/config.sh
  source "${AAI_ROOT}/lib/config.sh"
  # shellcheck source=../../lib/stages.sh
  source "${AAI_ROOT}/lib/stages.sh"
}

# Writes a valid config (the example) to $1, then applies "key: value"
# replacements given as further arguments via sed expressions.
write_config() {
  local dest=$1
  shift
  cp "${AAI_ROOT}/config/client.example.yaml" "$dest"
  local expr
  for expr in "$@"; do
    sed -i -E "$expr" "$dest"
  done
}

# Puts fake versions of the commands P0/P1 read on PATH, so tests never touch
# the network or depend on this machine. Behaviour is driven by STUB_* vars:
#   STUB_CURL_CODE      HTTP code printed by curl -w '%{http_code}' (default 200)
#   STUB_CURL_FAIL      1 = curl exits 35 with STUB_CURL_ERR on stderr
#   STUB_GETENT_OUT     output of getent ahostsv4 (empty = exit 2)
#   STUB_HOSTNAME_I     output of hostname -I
#   STUB_SS_OUT         output of ss (empty = nothing listening)
#   STUB_NVIDIA_OUT     output of nvidia-smi --query-gpu (unset = no nvidia-smi)
#   STUB_NPROC          output of nproc (default 16)
use_stubs() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${STUB_CURL_FAIL:-0}" == 1 ]]; then
  printf '%s\n' "${STUB_CURL_ERR:-curl: (35) error}" >&2
  exit 35
fi
args="$*"
if [[ "$args" == *"%{http_code}"* ]]; then printf '%s' "${STUB_CURL_CODE:-200}"; exit 0; fi
if [[ "$args" == *"%{size_download}"* ]]; then printf '%s' "${STUB_CURL_DL:-52428800 10485760}"; exit 0; fi
if [[ "$args" == *ipify* || "$args" == *ifconfig.me* ]]; then printf '%s' "${STUB_PUBLIC_IP:-203.0.113.10}"; exit 0; fi
exit 0
SH
  cat >"$bin/getent" <<'SH'
#!/usr/bin/env bash
[[ -n "${STUB_GETENT_OUT:-}" ]] || exit 2
printf '%s\n' "$STUB_GETENT_OUT"
SH
  cat >"$bin/hostname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_HOSTNAME_I:-10.0.0.5}"
SH
  cat >"$bin/ss" <<'SH'
#!/usr/bin/env bash
# Honours the "sport = :N" filter used by preflight_port_listeners.
[[ -n "${STUB_SS_OUT:-}" ]] || exit 0
if [[ "$*" =~ sport\ =\ :([0-9]+) ]]; then
  grep -E ":${BASH_REMATCH[1]}[[:space:]]" <<<"$STUB_SS_OUT" || true
else
  printf '%s\n' "$STUB_SS_OUT"
fi
SH
  cat >"$bin/nproc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_NPROC:-16}"
SH
  if [[ -v STUB_NVIDIA_OUT ]]; then
    cat >"$bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$STUB_NVIDIA_OUT"
SH
  fi
  chmod +x "$bin"/*
  export PATH="$bin:$PATH"
  # No real NVIDIA device and generous thresholds unless a test says otherwise.
  export AAI_SYSFS_PCI="${BATS_TEST_TMPDIR}/pci"
  mkdir -p "$AAI_SYSFS_PCI"
  export AAI_DISK_MIN_GB=0 AAI_DISK_OK_GB=0 AAI_RAM_MIN_MIB=0 AAI_RAM_OK_MIB=0
  export AAI_APT_SOURCES_DIR="${BATS_TEST_TMPDIR}/sources.list.d"
  export AAI_INSTALL_DIR="${BATS_TEST_TMPDIR}/opt"
  mkdir -p "$AAI_APT_SOURCES_DIR"
}

# Adds a fake PCI device to $AAI_SYSFS_PCI. Usage: fake_pci <vendor> <class>
fake_pci() {
  local dev="${AAI_SYSFS_PCI}/0000:0$((RANDOM % 9)):00.0"
  mkdir -p "$dev"
  printf '%s\n' "$1" >"$dev/vendor"
  printf '%s\n' "$2" >"$dev/class"
}

# Status of the last summary row.
last_status() {
  local row=${AAI_SUMMARY[-1]}
  printf '%s' "${row%%$'\t'*}"
}
