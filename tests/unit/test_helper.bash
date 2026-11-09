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
