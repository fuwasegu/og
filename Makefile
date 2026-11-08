.PHONY: all check quick build release test run install-hooks clean

all: check

## Full verification harness (Static guardrails + Debug build + Unit/Fuzz/SLA tests + Release build)
check:
	./scripts/harness.sh

## Fast verification harness for pre-commit / rapid AI agent iteration
quick:
	./scripts/harness.sh --quick

## Build debug executable
build:
	CLANG_MODULE_CACHE_PATH=/tmp/og-clang-module-cache swift build --disable-sandbox

## Build release executable
release:
	CLANG_MODULE_CACHE_PATH=/tmp/og-clang-module-cache swift build --disable-sandbox -c release

## Run unit, fuzz, and performance SLA test suite
test:
	./scripts/harness.sh --quick

## Run og native macOS Go editor
run:
	CLANG_MODULE_CACHE_PATH=/tmp/og-clang-module-cache swift run --disable-sandbox og

## Install git pre-commit and pre-push guardrail hooks
install-hooks:
	./scripts/install-hooks.sh

clean:
	swift package clean
