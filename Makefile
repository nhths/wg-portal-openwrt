# wg-portal for OpenWrt — pack the release binary, measure it and build a
# .ipk package for the router.
#
# Measurements and install checks run inside a fully emulated arm64 guest
# (qemu-system-aarch64).
#
# The WireGuard check runs in its own image: the emulated router with the
# portal inside and a WireGuard client next to it.

VER ?= v2.3.1
ARCH ?= aarch64_cortex-a53
REL ?= 1
DOCKER ?= docker
PLATFORM ?= linux/amd64
QEMU ?= qemu-system-aarch64
DIST ?= $(CURDIR)/dist
IMAGE ?= wg-portal-check
PKG_IMAGE ?= wg-portal-pkg
USIGN_IMAGE ?= wg-portal-usign
TAG ?= $(VER)

# The key of the feed: the public one is in the repository, the secret one is
# in the secrets of the CI and, for the local runs, in the file below.
PUBLIC_KEY ?= $(CURDIR)/keys/wg-portal.pub
SECRET_KEY ?= $(HOME)/.config/wg-portal/secret.key

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

# Rootless podman maps the ids of the users its own way: the id of the host
# has to be kept, or the container cannot write into the mounted directory.
# The root of the host is mapped to itself anyway, and there the flag is not
# needed — the runner of the CI builds with podman as root.
# Docker has no such mapping, it takes the id of the user as it is.
ifeq ($(DOCKER),podman)
  RUN_ID = $(shell [ "$$(id -u)" = 0 ] || echo --userns=keep-id)
else
  RUN_ID =
endif

.PHONY: help dist feed feed-index feed-sign bench check-install check-wireguard image usign-image build-src lint clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

dist: ## Pack the release binary with UPX and build the .ipk package
	mkdir -p $(DIST)
	$(DOCKER) build --platform $(PLATFORM) -f Dockerfile.pkg -t $(PKG_IMAGE):$(TAG) .
	$(DOCKER) run --rm --platform $(PLATFORM) $(RUN_ID) --user "$$(id -u):$$(id -g)" \
	  -e "VER=$(VER)" -e "ARCH=$(ARCH)" -e "REL=$(REL)" \
	  -v "$(DIST):/w" $(PKG_IMAGE):$(TAG)

usign-image: ## Build the image with the usign of OpenWrt
	$(DOCKER) build --platform $(PLATFORM) -f Dockerfile.usign -t $(USIGN_IMAGE) .

feed: dist ## Build the index of the feed of the portal and sign it
	$(MAKE) feed-index
	$(MAKE) feed-sign

feed-index: ## Build the index of the feed of the portal
	./scripts/make-feed.sh $(DIST) $(PUBLIC_KEY)

feed-sign: usign-image ## Sign the index of the feed of the portal
	$(DOCKER) run --rm --platform $(PLATFORM) $(RUN_ID) \
	  -v "$(DIST):/w" -v "$(SECRET_KEY):/key/secret.key:ro" \
	  $(USIGN_IMAGE) -S -m /w/Packages -s /key/secret.key -x /w/Packages.sig

bench: ## Measure size, startup time and RAM usage in an emulated arm64 guest
	./scripts/bench.sh

check-install: ## Install the .ipk into an emulated OpenWrt guest and start it
	./scripts/check.sh install

image: dist usign-image ## Build the image of the WireGuard check
	$(DOCKER) build --platform $(PLATFORM) -t $(IMAGE):$(TAG) -f Dockerfile .

check-wireguard: image ## Check a real WireGuard tunnel in the image of the check
	$(DOCKER) run --rm --device /dev/net/tun --cap-add NET_ADMIN --cap-add NET_RAW $(IMAGE):$(TAG)

build-src: ## Build wg-portal from source and compare the sizes
	./scripts/build-src.sh

lint: ## Run shellcheck, ansible-lint and markdownlint
	$(RUN_LINT) bash -c 'ansible-galaxy collection install -r ansible/requirements.yml \
	  && shellcheck -S warning scripts/*.sh \
	  && ansible-lint ansible/ \
	  && ansible-playbook -i ansible/inventory.ini --syntax-check ansible/site.yml \
	  && markdownlint --config .markdownlint.json README.md AGENTS.md wg-portal-upx-ipk-bench.md'

clean: ## Remove the build artifacts
	rm -rf $(DIST)
