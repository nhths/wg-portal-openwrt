# wg-portal for OpenWrt — pack the release binary, measure it and build a
# .apk package for the router.
#
# Measurements and install checks run inside a fully emulated arm64 guest
# (qemu-system-aarch64).
#
# The WireGuard check runs in its own image: the emulated router with the
# portal inside and a WireGuard client next to it.

# The version of the portal (the tag of the upstream release).
VER ?= v2.3.1
# The revision of the packaging: the fourth number of the version of the
# package. It is bumped when the packaging changes — the three first numbers
# are the ones of the portal.
PKG_REV ?= 1
# The version of the package: the version of the portal and our revision.
PKG_VERSION := $(subst v,,$(VER)).$(PKG_REV)
ARCH ?= aarch64_cortex-a53
DOCKER ?= docker
PLATFORM ?= linux/amd64
QEMU ?= qemu-system-aarch64
DIST ?= $(CURDIR)/dist
IMAGE ?= wg-portal-check
PKG_IMAGE ?= wg-portal-pkg
TAG ?= $(VER)

# The keys of the feed: the public one is in the repository (the keys/ of it),
# the secret one is in the secrets of the CI and, for the local runs, in the
# file below. The package is signed with the secret key — apk installs nothing
# whose signature it cannot check.
SECRET_KEY ?= $(HOME)/.config/wg-portal/secret.pem

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

.PHONY: help version dist pkg-image feed bench check-install check-wireguard image build-src lint clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

version: ## Print the version of the package
	@echo $(PKG_VERSION)

pkg-image: ## Build the toolbox image: UPX, the apk-tools and Jinja2
	$(DOCKER) build --platform $(PLATFORM) -f Dockerfile.pkg -t $(PKG_IMAGE):$(TAG) .

dist: pkg-image ## Pack the release binary, build the .apk package and sign it
	mkdir -p $(DIST)
	$(DOCKER) run --rm --platform $(PLATFORM) $(RUN_ID) \
	  -e "VER=$(VER)" -e "PKG_REV=$(PKG_REV)" -e "ARCH=$(ARCH)" \
	  -e "HOST_UID=$$(id -u)" -e "HOST_GID=$$(id -g)" \
	  -v "$(DIST):/w" -v "$(SECRET_KEY):/key/secret.pem:ro" \
	  $(PKG_IMAGE):$(TAG)

feed: dist ## Build the index of the feed of the portal and sign it
	$(DOCKER) run --rm --platform $(PLATFORM) $(RUN_ID) \
	  --entrypoint /opt/wg-portal/make-feed.sh \
	  -e "HOST_UID=$$(id -u)" -e "HOST_GID=$$(id -g)" \
	  -v "$(DIST):/w" -v "$(CURDIR)/keys:/keys:ro" \
	  -v "$(SECRET_KEY):/key/secret.pem:ro" \
	  $(PKG_IMAGE):$(TAG)

bench: ## Measure size, startup time and RAM usage in an emulated arm64 guest
	./scripts/bench.sh

check-install: feed ## Install the .apk into an emulated OpenWrt guest and start it
	./scripts/check.sh install

image: feed pkg-image ## Build the image of the WireGuard check
	$(DOCKER) build --platform $(PLATFORM) \
	  -t $(IMAGE):$(TAG) -f Dockerfile .

check-wireguard: image ## Check a real WireGuard tunnel in the image of the check
	$(DOCKER) run --rm --device /dev/net/tun --cap-add NET_ADMIN --cap-add NET_RAW $(IMAGE):$(TAG)

build-src: ## Build wg-portal from source and compare the sizes
	./scripts/build-src.sh

lint: ## Run shellcheck, ansible-lint and markdownlint
	$(RUN_LINT) bash -c 'ansible-galaxy collection install -r ansible/requirements.yml \
	  && shellcheck -S warning scripts/*.sh \
	  && ansible-lint ansible/ \
	  && ansible-playbook -i ansible/inventory.ini --syntax-check ansible/site.yml \
	  && ansible-playbook -i ansible/inventory.ini --syntax-check ansible/router.yml \
	  && markdownlint --config .markdownlint.json README.md AGENTS.md wg-portal-upx-ipk-bench.md'

clean: ## Remove the build artifacts
	rm -rf $(DIST)
