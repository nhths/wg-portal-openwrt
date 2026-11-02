# wg-portal for OpenWrt — pack the release binary, measure it and build a
# .ipk package for the router.
#
# Measurements and install checks run inside a fully emulated arm64 guest
# (qemu-system-aarch64). qemu-user cannot be used: under it the generic
# netlink socket is unavailable, so wg-portal refuses to start.
#
# The WireGuard check runs in its own image: the emulated router with the
# portal inside and a WireGuard client next to it.

VER ?= v2.3.1
ARCH ?= aarch64_cortex-a53
DOCKER ?= docker
PLATFORM ?= linux/amd64
QEMU ?= qemu-system-aarch64
DIST ?= $(CURDIR)/dist
IMAGE ?= wg-portal-check
TAG ?= $(VER)

LINT_IMAGE ?= cr.knois.ru/pipelines/lint:latest
PODMAN ?= podman
# CI sets CI=true for every job: inside the lint image the tools are called
# directly, on a developer machine they run in the same image, so the result
# is the same everywhere.
ifeq ($(CI),true)
  RUN_LINT = $(1)
else
  RUN_LINT = $(PODMAN) run --rm -v "$$(pwd):/src:z" -w /src $(LINT_IMAGE) $(1)
endif

.PHONY: help dist bench check-install check-wireguard image build-src lint clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

dist: ## Pack the release binary with UPX and build the .ipk package
	./scripts/build-ipk.sh

bench: ## Measure size, startup time and RAM usage in an emulated arm64 guest
	./scripts/bench.sh

check-install: ## Install the .ipk into an emulated OpenWrt guest and start it
	./scripts/check-install.sh

image: dist ## Build the image of the WireGuard check
	$(DOCKER) build --platform $(PLATFORM) -t $(IMAGE):$(TAG) -f Dockerfile .

check-wireguard: image ## Check a real WireGuard tunnel in the image of the check
	$(DOCKER) run --rm --device /dev/net/tun --cap-add NET_ADMIN $(IMAGE):$(TAG)

build-src: ## Build wg-portal from source and compare the sizes
	./scripts/build-src.sh

lint: ## Run shellcheck, ansible-lint and markdownlint
	$(RUN_LINT) bash -c 'ansible-galaxy collection install -r ansible/requirements.yml \
	  && shellcheck -S warning scripts/*.sh scripts/vm/*.sh \
	  && ansible-lint ansible/ \
	  && markdownlint --config .markdownlint.json README.md wg-portal-upx-ipk-bench.md'

clean: ## Remove the build artifacts
	rm -rf $(DIST)
