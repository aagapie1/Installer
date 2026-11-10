#!/usr/bin/env bats
# Tests for the prerequisite check of tests/vm/multipass-test.sh, run as a
# black box with a minimal PATH and stubbed package managers.

# Each @test runs in its own subshell by design (SC2030/SC2031).
# shellcheck disable=SC2034,SC2030,SC2031

bats_require_minimum_version 1.5.0
load test_helper

SCRIPT="${BATS_TEST_DIRNAME}/../vm/multipass-test.sh"

setup() {
  BIN="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  CHMOD=$(command -v chmod)
  mkdir -p "$BIN"
  : >"$CALLS"
  local c
  for c in bash env date dirname uname sleep sed; do
    ln -s "$(command -v "$c")" "$BIN/$c"
  done
}

# stub <name> <body>: a fake command that logs its arguments, then runs body.
stub() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$CALLS" "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

fake_multipass() { stub multipass 'exit 0'; }
fake_make() { stub make 'exit 0'; }

run_check() {
  run env PATH="$BIN" bash "$SCRIPT" --check-deps "$@" </dev/null
}

@test "vm prereqs: all present -> exit 0" {
  fake_make
  fake_multipass
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK] make este instalat"* && "$output" == *"[OK] multipass este instalat"* ]]
}

@test "vm prereqs: missing multipass, non-interactive -> prints the command, installs nothing" {
  [ "$EUID" -eq 0 ] || skip "testul presupune root (fără prefix sudo)"
  fake_make
  stub snap 'exit 0'
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"Lipsește multipass. Instalați-l cu:"* ]]
  [[ "$output" == *"snap install multipass"* ]]
  [[ "$output" == *"--yes"* ]]
  run ! grep -q '^snap' "$CALLS"
}

@test "vm prereqs: --yes installs multipass with snap" {
  [ "$EUID" -eq 0 ] || skip "testul presupune root (fără prefix sudo)"
  fake_make
  # The fake snap "installs" multipass by creating its stub.
  stub snap "printf '#!/usr/bin/env bash\nexit 0\n' >'$BIN/multipass'; $CHMOD +x '$BIN/multipass'"
  run_check --yes
  [ "$status" -eq 0 ]
  grep -qx 'snap install multipass' "$CALLS"
  [[ "$output" == *"[OK] multipass instalat"* ]]
}

@test "vm prereqs: --yes installs make with apt-get" {
  [ "$EUID" -eq 0 ] || skip "testul presupune root (fără prefix sudo)"
  fake_multipass
  stub apt-get "[[ \"\$*\" == *install* ]] && { printf '#!/usr/bin/env bash\nexit 0\n' >'$BIN/make'; $CHMOD +x '$BIN/make'; }; exit 0"
  run_check --yes
  [ "$status" -eq 0 ]
  grep -qx 'apt-get update' "$CALLS"
  grep -qx 'apt-get install -y make' "$CALLS"
}

@test "vm prereqs: no package manager -> clear message with a link" {
  fake_make
  run_check --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"Lipsește multipass și nu îl pot instala automat"*"canonical.com/multipass/install"* ]]
  [[ "$output" == *"Testul în VM nu poate porni"* ]]
}

@test "vm prereqs: failed install is reported" {
  [ "$EUID" -eq 0 ] || skip "testul presupune root (fără prefix sudo)"
  fake_make
  stub snap 'exit 1'
  run_check --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"Comanda a eșuat: snap install multipass"* ]]
}
