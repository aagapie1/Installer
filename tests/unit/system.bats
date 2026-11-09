#!/usr/bin/env bats
# Tests for lib/system.sh and lib/docker.sh (P1) helpers.

# Globals set here are read by the sourced libraries.
# Each @test runs in its own subshell by design (SC2030/SC2031).
# shellcheck disable=SC2034,SC2030,SC2031

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  aai_test_setup
  source "${AAI_ROOT}/lib/preflight.sh"
  source "${AAI_ROOT}/lib/system.sh"
  source "${AAI_ROOT}/lib/docker.sh"
  use_stubs
}

@test "write_file: creates with mode, then reports unchanged" {
  local f="${BATS_TEST_TMPDIR}/etc/x.conf"
  aai_write_file "$f" 600 <<<a
  [ "$AAI_FILE_CHANGED" -eq 1 ]
  [ "$(cat "$f")" = a ]
  [ "$(stat -c %a "$f")" = 600 ]
  aai_write_file "$f" 600 <<<a
  [ "$AAI_FILE_CHANGED" -eq 0 ]
  aai_write_file "$f" 600 <<<b
  [ "$AAI_FILE_CHANGED" -eq 1 ]
  [ "$(cat "$f")" = b ]
  [ -z "$(find "${BATS_TEST_TMPDIR}/etc" -name '.aai-write.*')" ]
}

@test "write_file: dry-run does not write" {
  AAI_DRY_RUN=1
  local f="${BATS_TEST_TMPDIR}/etc/y.conf"
  run aai_write_file "$f" 644 <<<"x"
  [[ "$output" == *"[dry-run] scriu fișierul"* ]]
  [ ! -e "$f" ]
}

@test "check: OK in dry-run outside P0 is marked as simulated" {
  AAI_DRY_RUN=1
  run aai_check OK P1 "Docker instalat"
  [[ "$output" == *"Docker instalat (simulat)"* ]]
  run aai_check OK P0 "RAM: 32 GB"
  [[ "$output" != *simulat* ]]
}

@test "firewall ports: default 22/80/443, plus a non-standard sshd port" {
  run system_firewall_ports
  [ "$output" = $'22\n80\n443' ]
  export STUB_SS_OUT='LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=4))'
  run system_firewall_ports
  [ "$output" = $'22\n2222\n80\n443' ]
}

@test "firewall: dry-run plan opens only the expected ports" {
  AAI_DRY_RUN=1
  run system_firewall
  [[ "$output" == *"ufw default deny incoming"* ]]
  [[ "$output" == *"ufw allow 22/tcp"* && "$output" == *"ufw allow 80/tcp"* && "$output" == *"ufw allow 443/tcp"* ]]
  [ "$(grep -c 'ufw allow' <<<"$output")" -eq 3 ]
  [[ "$output" == *"ufw --force enable"* ]]
}

@test "docker sources: deb822 with codename, arch and keyring" {
  run docker_sources noble amd64
  [[ "$output" == *"URIs: https://download.docker.com/linux/ubuntu"* ]]
  [[ "$output" == *"Suites: noble"* && "$output" == *"Architectures: amd64"* ]]
  [[ "$output" == *"Signed-By: /etc/apt/keyrings/docker.asc"* ]]
}

# shellcheck disable=SC2016  # $(ARCH) must stay literal
@test "nvidia sources: keeps the apt \$(ARCH) variable literal" {
  run nvidia_sources
  [[ "$output" == *'deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /'* ]]
}

@test "daemon.json: adds log rotation, keeps existing settings" {
  run docker_merge_daemon_json <<<'{}'
  [ "$(jq -r '."log-opts"."max-size"' <<<"$output")" = 50m ]
  [ "$(jq -r '."log-driver"' <<<"$output")" = json-file ]
  run docker_merge_daemon_json <<<'{"runtimes":{"nvidia":{"path":"nvidia-container-runtime"}},"log-opts":{"max-size":"10m"}}'
  [ "$(jq -r '.runtimes.nvidia.path' <<<"$output")" = nvidia-container-runtime ]
  [ "$(jq -r '."log-opts"."max-size"' <<<"$output")" = 10m ]
  run docker_merge_daemon_json <<<'not json'
  [ "$status" -ne 0 ]
}

@test "daemon.json: written once, docker restarted only on change" {
  export AAI_DOCKER_DAEMON_JSON="${BATS_TEST_TMPDIR}/docker/daemon.json"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/systemctl.calls"\n' "$BATS_TEST_TMPDIR" >"${BATS_TEST_TMPDIR}/bin/systemctl"
  chmod +x "${BATS_TEST_TMPDIR}/bin/systemctl"
  docker_configure_daemon
  [ "$(jq -r '."log-opts"."max-file"' "$AAI_DOCKER_DAEMON_JSON")" = 5 ]
  [ "$(grep -c 'restart docker' "${BATS_TEST_TMPDIR}/systemctl.calls")" -eq 1 ]
  docker_configure_daemon
  [ "$(grep -c 'restart docker' "${BATS_TEST_TMPDIR}/systemctl.calls")" -eq 1 ]
}

@test "daemon.json: invalid file is reported, not overwritten" {
  export AAI_DOCKER_DAEMON_JSON="${BATS_TEST_TMPDIR}/daemon.json"
  printf '{ broken' >"$AAI_DOCKER_DAEMON_JSON"
  run docker_configure_daemon
  [ "$status" -eq 1 ]
  [[ "$output" == *"nu este JSON valid"* ]]
  [ "$(cat "$AAI_DOCKER_DAEMON_JSON")" = '{ broken' ]
}

@test "nvidia utils package matches the installed driver" {
  [ "$(nvidia_utils_package_for <<<'nvidia-headless-no-dkms-570-server')" = nvidia-utils-570-server ]
  [ "$(nvidia_utils_package_for <<<'nvidia-driver-550')" = nvidia-utils-550 ]
  [ "$(nvidia_utils_package_for <<<'nvidia-driver-570-server-open')" = nvidia-utils-570-server ]
  [ -z "$(nvidia_utils_package_for <<<'nvidia-firmware-570')" ]
}

@test "gpg fingerprint check accepts the right key only" {
  command -v gpg >/dev/null || skip "lipsește gpg"
  local home="${BATS_TEST_TMPDIR}/gnupg" key="${BATS_TEST_TMPDIR}/key.asc" fpr
  mkdir -m 700 "$home"
  GNUPGHOME="$home" gpg --batch --passphrase '' --quick-gen-key test@example.invalid ed25519 sign never 2>/dev/null
  GNUPGHOME="$home" gpg --batch --armor --export test@example.invalid >"$key"
  fpr=$(GNUPGHOME="$home" gpg --batch --with-colons --list-keys test@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')
  aai_gpg_has_fingerprint "$key" "$fpr"
  aai_gpg_has_fingerprint "$key" "${fpr,,}"
  run ! aai_gpg_has_fingerprint "$key" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
}

@test "docker: Docker Desktop installed is an error" {
  printf '#!/usr/bin/env bash\n[[ "$*" == *docker-desktop* ]] && printf "install ok installed"\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/dpkg-query"
  chmod +x "${BATS_TEST_TMPDIR}/bin/dpkg-query"
  run docker_check_no_desktop
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker Desktop este instalat"* ]]
}

@test "nvidia driver: dry-run plans install and the reboot stop" {
  AAI_DRY_RUN=1
  printf '#!/usr/bin/env bash\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/dpkg-query"
  chmod +x "${BATS_TEST_TMPDIR}/bin/dpkg-query"
  run nvidia_ensure_driver
  [[ "$output" == *"ubuntu-drivers install --gpgpu"* ]]
  [[ "$output" == *"repornirea serverului"* ]]
  nvidia_ensure_driver >/dev/null
  [ -z "$AAI_STOP_REASON" ]
}

@test "nvidia driver: installed but not loaded asks for reboot" {
  printf '#!/usr/bin/env bash\necho "nvidia-headless-no-dkms-570-server install ok installed"\n' >"${BATS_TEST_TMPDIR}/bin/dpkg-query"
  chmod +x "${BATS_TEST_TMPDIR}/bin/dpkg-query"
  nvidia_ensure_driver >/dev/null 2>&1
  [ "$AAI_STOP_REASON" = reboot ]
  [ "$(last_status)" = AVERTISMENT ]
}
