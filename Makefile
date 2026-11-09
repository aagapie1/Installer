SHELL := /usr/bin/env bash
export LC_ALL := C.UTF-8
.SHELLFLAGS := -eu -o pipefail -c

SH_FILES := $(shell find . -path ./clients -prune -o -path ./.git -prune -o -type f -name '*.sh' -print | sort)
BATS_FILES := $(wildcard tests/unit/*.bats)

.PHONY: help lint test vm-test eval

help:
	@echo "Ținte: lint, test, vm-test, eval"

lint:
	@command -v shellcheck >/dev/null || { echo "Lipsește shellcheck: apt install -y shellcheck"; exit 1; }
	shellcheck -x $(SH_FILES)
	shellcheck -x -s bash $(BATS_FILES) tests/unit/test_helper.bash

test:
	@command -v bats >/dev/null || { echo "Lipsește bats: apt install -y bats"; exit 1; }
	bats tests/unit/

vm-test:
	@echo "make vm-test: testul în VM (tests/vm/multipass-test.sh) se adaugă în M2/M9."; exit 1

eval:
	@echo "make eval: scripts/run-eval.sh se adaugă în M6."; exit 1
