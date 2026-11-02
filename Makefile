# wg-portal for OpenWrt — pack the release binary, measure it and build a
# .ipk package for the router.
#
# Measurements and install checks run inside a fully emulated arm64 guest
# (qemu-system-aarch64). qemu-user cannot be used: under it the generic
# netlink socket is unavailable, so wg-portal refuses to start.

VER ?= v2.3.1
ARCH ?= aarch64_cortex-a53
DOCKER ?= docker
PLATFORM ?= linux/amd64
QEMU ?= qemu-system-aarch64
DIST ?= $(CURDIR)/dist

.PHONY: help dist bench check-install check-wireguard build-src lint clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

dist: ## Pack the release binary with UPX and build the .ipk package
	./scripts/build-ipk.sh

bench: ## Measure size, startup time and RAM usage in an emulated arm64 guest
	./scripts/bench.sh

check-install: ## Install the .ipk into an emulated OpenWrt guest and start it
	./scripts/check-install.sh

check-wireguard: ## Check a real WireGuard tunnel through the portal-managed interface
	./scripts/check-wireguard.sh

build-src: ## Build wg-portal from source and compare the sizes
	./scripts/build-src.sh

lint: ## Run shellcheck and markdownlint
	$(DOCKER) run --rm --platform $(PLATFORM) --entrypoint shellcheck -v $(CURDIR):/w -w /w \
		koalaman/shellcheck-alpine:stable -S warning scripts/*.sh scripts/vm/*.sh
	npx --yes markdownlint-cli@0.42.0 README.md wg-portal-upx-ipk-bench.md

clean: ## Remove the build artifacts
	rm -rf $(DIST)
