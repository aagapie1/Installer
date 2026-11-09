#!/usr/bin/env bats
# Tests for lib/preflight.sh (P0). All system inputs are stubbed.

# Globals set here are read by the sourced libraries.
# Each @test runs in its own subshell by design (SC2030/SC2031).
# shellcheck disable=SC2034,SC2030,SC2031

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  aai_test_setup
  source "${AAI_ROOT}/lib/preflight.sh"
  use_stubs
  config_load "${AAI_ROOT}/config/client.example.yaml"
}

os_release() {
  export AAI_OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  printf '%s\n' "$@" >"$AAI_OS_RELEASE_FILE"
}

meminfo_kb() {
  export AAI_MEMINFO_FILE="${BATS_TEST_TMPDIR}/meminfo"
  printf 'MemTotal:       %s kB\nMemFree: 1 kB\n' "$1" >"$AAI_MEMINFO_FILE"
}

@test "os: Ubuntu 24.04 OK, other Ubuntu warning, other distro error" {
  os_release 'ID=ubuntu' 'VERSION_ID="24.04"' 'PRETTY_NAME="Ubuntu 24.04.1 LTS"'
  preflight_check_os >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  os_release 'ID=ubuntu' 'VERSION_ID="22.04"'
  preflight_check_os >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
  os_release 'ID=debian' 'VERSION_ID="12"' 'PRETTY_NAME="Debian GNU/Linux 12"'
  preflight_check_os >/dev/null 2>&1
  [ "$(last_status)" = EROARE ]
}

@test "arch: non x86_64 is an error" {
  printf '#!/usr/bin/env bash\necho aarch64\n' >"${BATS_TEST_TMPDIR}/bin/uname"
  chmod +x "${BATS_TEST_TMPDIR}/bin/uname"
  run preflight_check_arch
  [[ "$output" == *"[EROARE] Arhitectură nesuportată: aarch64"* ]]
}

@test "ram: thresholds (32 GB ok, 16 GB warning, 8 GB error)" {
  export AAI_RAM_OK_MIB=30720 AAI_RAM_MIN_MIB=15360
  meminfo_kb 32791424
  preflight_check_ram >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  meminfo_kb 16384000
  preflight_check_ram >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
  meminfo_kb 8192000
  run preflight_check_ram
  [[ "$output" == *"[EROARE] RAM: 7.8 GB"* ]]
}

# The stub reads $STUB_DF_AVAIL at run time, so it must stay literal.
# shellcheck disable=SC2016
@test "disk: thresholds use free space in decimal GB" {
  printf '#!/usr/bin/env bash\necho "Filesystem 1-blocks Used Available Capacity Mounted"\necho "/dev/sda1 0 0 %s 1%% /"\n' '${STUB_DF_AVAIL}' >"${BATS_TEST_TMPDIR}/bin/df"
  chmod +x "${BATS_TEST_TMPDIR}/bin/df"
  export AAI_DISK_OK_GB=180 AAI_DISK_MIN_GB=50
  STUB_DF_AVAIL=250000000000 preflight_check_disk >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  STUB_DF_AVAIL=60000000000 preflight_check_disk >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
  export STUB_DF_AVAIL=20000000000
  run preflight_check_disk
  [[ "$output" == *"[EROARE] Disc liber pentru"*"20 GB"* ]]
}

@test "cpu: fewer than 8 cores is a warning" {
  STUB_NPROC=4 preflight_check_cpu >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
  STUB_NPROC=16 preflight_check_cpu >/dev/null 2>&1
  [ "$(last_status)" = OK ]
}

@test "gpu: nvidia-smi output is parsed, multiple cards summed" {
  export STUB_NVIDIA_OUT=$'NVIDIA L4, 23034\nNVIDIA L4, 23034'
  use_stubs
  preflight_detect_gpu
  [ "$AAI_GPU_DRIVER" -eq 1 ]
  [ "$AAI_GPU_COUNT" -eq 2 ]
  [ "$AAI_GPU_VRAM_MIB" -eq 46068 ]
  [ "$AAI_GPU_NAMES" = "NVIDIA L4, NVIDIA L4" ]
}

@test "profile auto: 80 GB card -> gpu" {
  export STUB_NVIDIA_OUT='NVIDIA A100 80GB PCIe, 81920'
  use_stubs
  preflight_check_gpu >/dev/null 2>&1
  [ "$AAI_PROFILE" = gpu ]
  [ "$(last_status)" = OK ]
}

@test "profile auto: 16 GB card -> cpu with warning" {
  export STUB_NVIDIA_OUT='Tesla T4, 15360'
  use_stubs
  run preflight_check_gpu
  [[ "$output" == *"Profil ales automat: cpu (placa Tesla T4 are doar 15.0 GB VRAM"* ]]
  preflight_check_gpu >/dev/null 2>&1
  [ "$AAI_PROFILE" = cpu ]
}

@test "profile auto: NVIDIA on PCI without driver -> gpu (driver in P1)" {
  fake_pci 0x10de 0x030200
  preflight_check_gpu >/dev/null 2>&1
  [ "$AAI_GPU_PRESENT" -eq 1 ]
  [ "$AAI_GPU_DRIVER" -eq 0 ]
  [ "$AAI_PROFILE" = gpu ]
  [ "$(last_status)" = AVERTISMENT ]
}

@test "profile auto: NVIDIA audio function or other vendors are ignored" {
  fake_pci 0x10de 0x040300
  fake_pci 0x8086 0x030000
  preflight_check_gpu >/dev/null 2>&1
  [ "$AAI_GPU_PRESENT" -eq 0 ]
  [ "$AAI_PROFILE" = cpu ]
}

@test "profile gpu requested without a card is an error; cpu requested is OK" {
  config_set inference.profile gpu
  preflight_check_gpu >/dev/null 2>&1
  [ "$(last_status)" = EROARE ]
  config_set inference.profile cpu
  export STUB_NVIDIA_OUT='NVIDIA A100 80GB PCIe, 81920'
  use_stubs
  preflight_check_gpu >/dev/null 2>&1
  [ "$AAI_PROFILE" = cpu ]
  [ "$(last_status)" = OK ]
}

@test "ensure_profile: decides silently" {
  preflight_ensure_profile
  [ "$AAI_PROFILE" = cpu ]
  [ "${#AAI_SUMMARY[@]}" -eq 0 ]
}

@test "ports: free, taken by another service, taken by our Dify" {
  preflight_check_ports >/dev/null 2>&1
  [ "$(aai_summary_count OK)" -eq 2 ]

  export STUB_SS_OUT='LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=10,fd=6),("nginx",pid=11,fd=6))'
  run preflight_check_ports
  [[ "$output" == *"[EROARE] Portul 80 este ocupat de: nginx"* ]]
  [[ "$output" == *"[OK] Portul 443 este liber"* ]]

  export STUB_SS_OUT=$'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("docker-proxy",pid=5,fd=7))\nLISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("docker-proxy",pid=6,fd=7))'
  run preflight_check_ports
  [[ "$output" == *"[EROARE] Portul 80 este ocupat de: docker-proxy"* ]]
  mkdir -p "${AAI_INSTALL_DIR}/dify"
  run preflight_check_ports
  [[ "$output" == *"[OK] Portul 80 este folosit de instalarea existentă"* ]]
  [[ "$output" == *"[OK] Portul 443 este folosit de instalarea existentă"* ]]
}

@test "dns: matches public IP or a local IP" {
  export STUB_GETENT_OUT='203.0.113.10 STREAM x' STUB_PUBLIC_IP=203.0.113.10
  preflight_check_dns >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  export STUB_GETENT_OUT='10.0.0.5 STREAM x' STUB_PUBLIC_IP=198.51.100.1
  preflight_check_dns >/dev/null 2>&1
  [ "$(last_status)" = OK ]
}

@test "dns: pointing elsewhere is a warning (client reverse proxy)" {
  export STUB_GETENT_OUT='198.51.100.77 STREAM x' STUB_PUBLIC_IP=203.0.113.10
  run preflight_check_dns
  [[ "$output" == *"[AVERTISMENT] Domeniul asistent.primariabuzau.ro rezolvă la 198.51.100.77"*"203.0.113.10"* ]]
  [[ "$output" == *"reverse proxy"* ]]
}

@test "dns: not resolving is an error only for letsencrypt" {
  export STUB_GETENT_OUT=''
  preflight_check_dns >/dev/null 2>&1
  [ "$(last_status)" = EROARE ]
  config_set tls.mode none
  preflight_check_dns >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
}

@test "endpoints: any HTTP status is reachable; none is an error" {
  AAI_PROFILE=cpu
  STUB_CURL_CODE=401 preflight_check_endpoints >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  export STUB_CURL_CODE=000
  run preflight_check_endpoints
  [[ "$output" == *"[EROARE] Servicii inaccesibile"*"registry.ollama.ai"* ]]
}

@test "endpoints: list depends on profile" {
  AAI_PROFILE=gpu
  run preflight_endpoints
  [[ "$output" == *huggingface.co* && "$output" == *nvidia.github.io* && "$output" != *ollama* ]]
  AAI_PROFILE=cpu
  run preflight_endpoints
  [[ "$output" == *registry.ollama.ai* && "$output" != *huggingface* ]]
}

@test "download: ok, slow, short" {
  AAI_PROFILE=gpu
  preflight_check_download >/dev/null 2>&1
  [ "$(last_status)" = OK ]
  STUB_CURL_DL='52428800 102400' preflight_check_download >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
  STUB_CURL_DL='1000 10485760' preflight_check_download >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
}

@test "download: bad record MAC shows the ethtool remedy" {
  AAI_PROFILE=gpu
  export STUB_CURL_FAIL=1 STUB_CURL_ERR='curl: (56) OpenSSL SSL_read: error:0A000119:SSL routines::decryption failed or bad record mac'
  run preflight_check_download
  [[ "$output" == *"[EROARE] Testul de descărcare a eșuat: bad record MAC"* ]]
  [[ "$output" == *"ethtool -K"*"tx off rx off"* ]]
}

@test "download: failure is only a warning on the cpu profile" {
  AAI_PROFILE=cpu
  STUB_CURL_FAIL=1 preflight_check_download >/dev/null 2>&1
  [ "$(last_status)" = AVERTISMENT ]
}

@test "download: skipped in dry-run" {
  AAI_DRY_RUN=1
  run preflight_check_download
  [[ "$output" == *"(dry-run) descarc ~50 MB"* ]]
  preflight_check_download >/dev/null
  [ "${#AAI_SUMMARY[@]}" -eq 0 ]
}
