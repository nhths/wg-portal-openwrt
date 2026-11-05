# The image of the WireGuard check: an emulated OpenWrt router with the portal
# inside and a WireGuard client next to it.
#
#   docker build -t wg-portal-check .
#   docker run --rm --device /dev/net/tun --cap-add NET_ADMIN wg-portal-check
#
# The check needs the tun device (the tap between the host and the guest) and
# the right to create the network interfaces in the namespace of the container.

# The usign of OpenWrt: the tool that signs the feeds of opkg. It is a build
# of OpenWrt for musl, so it comes with its own loader and libraries.
FROM wg-portal-usign AS usign

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      e2fsprogs \
      ethtool \
      ipxe-qemu \
      iproute2 \
      iputils-ping \
      openssh-client \
      python3 \
      python3-venv \
      qemu-system-arm \
      util-linux \
      wireguard-tools \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/wg-portal

# Ansible configures the OpenWrt guest. The collection is the same one the LAN
# router is converged with: its modules are ucode scripts, so the guest needs
# no Python.
COPY ansible/requirements.yml /tmp/requirements.yml
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir "ansible-core>=2.16,<2.19" \
 && /opt/venv/bin/ansible-galaxy collection install \
      -p /usr/share/ansible/collections -r /tmp/requirements.yml \
 && rm /tmp/requirements.yml
ENV PATH=/opt/venv/bin:$PATH
ENV ANSIBLE_CONFIG=/opt/wg-portal/ansible/ansible.cfg
ENV ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
ENV ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote

# The usign of OpenWrt, with its loader and its libraries: the check signs
# the index of the feed of the portal with a throwaway key. The libraries are
# in the image of the usign itself (in /opt/usign/lib) — a wildcard in the
# source of a COPY is a Docker thing, podman does not do it.
COPY --from=usign /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
COPY --from=usign /opt/usign /opt/usign
RUN printf '#!/bin/sh\nexec /lib/ld-musl-x86_64.so.1 --library-path /opt/usign/lib /opt/usign/usign "$@"\n' > /usr/local/bin/usign \
 && chmod 755 /usr/local/bin/usign

COPY ansible/ /opt/wg-portal/ansible/
COPY scripts/ /opt/wg-portal/scripts/
COPY templates/ /opt/wg-portal/templates/
COPY dist/ /opt/wg-portal/dist/

# The OpenWrt guest: the rootfs, the kernel and the kernel modules. They are
# baked into the image, so the check does not need the network.
RUN /opt/wg-portal/scripts/guest.sh fetch /opt/wg-portal/guest \
 && rm -f /opt/wg-portal/guest/rootfs.img

# The dropbear of the guest generates its host keys on the first boot, and
# under the emulation that takes minutes. They are generated here instead.
RUN apt-get update \
 && apt-get install -y --no-install-recommends dropbear \
 && rm -rf /var/lib/apt/lists/* \
 && for t in ed25519 rsa; do \
      dropbearkey -t "$t" -f "/opt/wg-portal/guest/rootfs/etc/dropbear/dropbear_${t}_host_key"; \
    done \
 && chmod 600 /opt/wg-portal/guest/rootfs/etc/dropbear/*_host_key \
 && apt-get purge -y dropbear \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# The guest lives in the image, the check writes the flash and the console of
# the router next to it.
ENV VM=/opt/wg-portal/guest

# The check of the WireGuard tunnel, the check of the installation of the
# package — the mode is the argument of the container.
ENTRYPOINT ["/opt/wg-portal/scripts/check.sh"]
CMD ["wireguard"]
