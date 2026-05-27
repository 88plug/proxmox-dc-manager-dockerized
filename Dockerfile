# syntax=docker/dockerfile:1.7
#
# Proxmox Datacenter Manager (PDM) — Dockerized (all-in-one)
# Self-contained build: the extractor stage downloads the official Proxmox
# Datacenter Manager ISO and unpacks it. No host-side prep, no .iso-work,
# no separate `make get-iso` step. `docker compose up --build` and you're done.
#
# Layer caching: the ISO download lands in its own RUN, so Docker caches the
# 1.4 GB blob across rebuilds — a clean rebuild only re-downloads if the
# pinned URL or sha256 changes.
#
# Stages:
#   1. extractor — fetches the ISO, extracts pdm-base.squashfs + apt pool
#   2. pdm-base  — scratch image populated from the extracted Debian rootfs
#   3. final     — installs PDM from the local pool and layers s6-overlay
#

# ===========================================================================
# Stage 1: extractor — fetch the ISO and unpack the embedded squashfs rootfs.
# ===========================================================================
FROM debian:trixie-slim AS extractor

ARG PDM_ISO_URL=http://download.proxmox.com/iso/proxmox-datacenter-manager_1.0-2.iso
ARG PDM_ISO_SHA256=b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1
# Proxmox Trixie release signing key. Fetched live, but sha256-pinned and the
# OpenPGP fingerprint is re-verified after import. Rotation = bump both pins.
# Key fingerprint: 24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E
ARG PROXMOX_KEY_URL=https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg
ARG PROXMOX_KEY_SHA256=1bcd2d5bab556076c9ea756a84fe2b7445b13f4ef6e97b2e412b68778377ba6d
ARG PROXMOX_KEY_FPR=24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gpg \
        gpgv \
        squashfs-tools \
        libarchive-tools \
    ; \
    rm -rf /var/lib/apt/lists/*

# Fetch + verify the ISO. Three independent checks: sha256 against the pin,
# sha256 against the Proxmox release key, and a GPG signature verification
# of the ISO using gpgv against that pinned key. Using `gpg --show-keys` to
# read the fingerprint and `gpgv` for the signature check avoids spawning
# gpg-agent (which the slim base image doesn't ship), so no keyring import
# or homedir setup is needed.
RUN set -eux; \
    mkdir -p /iso /keys; \
    curl -fL --retry 3 --retry-delay 2 -o /iso/pdm.iso     "${PDM_ISO_URL}"; \
    curl -fL --retry 3 --retry-delay 2 -o /iso/pdm.iso.asc "${PDM_ISO_URL}.asc"; \
    curl -fL --retry 3 --retry-delay 2 -o /keys/proxmox-release.gpg "${PROXMOX_KEY_URL}"; \
    # 1. Pin-verify the ISO content.
    echo "${PDM_ISO_SHA256}  /iso/pdm.iso"             | sha256sum -c -; \
    # 2. Pin-verify the public key we just fetched.
    echo "${PROXMOX_KEY_SHA256}  /keys/proxmox-release.gpg" | sha256sum -c -; \
    # 3. Parse the key file directly (no import, no agent) and check the
    #    primary-key fingerprint against the pinned value.
    gpg --show-keys --with-colons /keys/proxmox-release.gpg \
      | awk -F: '$1=="fpr"{print $10; exit}' \
      | grep -qx "${PROXMOX_KEY_FPR}" \
      || { echo "FATAL: key fingerprint mismatch" >&2; exit 1; }; \
    # 4. Verify the detached signature with gpgv. Proxmox dual-signs their
    #    ISOs — the .asc contains a signature from the Trixie release key
    #    we trust AND a secondary signature from a build/CI key we don't.
    #    gpgv naturally exits non-zero whenever ANY signature can't be
    #    verified, so we instead require "at least one Good signature line
    #    from our pinned key" in the gpgv output. Anchoring on the key id
    #    in the BAD-signature line is impossible (gpgv prints nothing for
    #    unknown keys in some versions), so we anchor on the explicit
    #    "Good signature" line, which only appears if our pinned key
    #    successfully verified one of the signatures.
    gpgv_out=$(gpgv --keyring /keys/proxmox-release.gpg \
                    /iso/pdm.iso.asc /iso/pdm.iso 2>&1 || true); \
    printf '%s\n' "${gpgv_out}"; \
    printf '%s\n' "${gpgv_out}" \
      | grep -qE "^gpgv: Good signature .* ${PROXMOX_KEY_FPR}|^gpgv:[[:space:]]+using RSA key ${PROXMOX_KEY_FPR}$" \
      || { echo "FATAL: no good signature on ISO from pinned key" >&2; exit 1; }; \
    printf '%s\n' "${gpgv_out}" \
      | grep -qE "^gpgv: Good signature" \
      || { echo "FATAL: gpgv did not emit a Good signature line" >&2; exit 1; }

# Unpack the ISO and the embedded Debian rootfs.
RUN set -eux; \
    mkdir -p /tmp/iso /tmp/rootfs; \
    bsdtar -xf /iso/pdm.iso -C /tmp/iso; \
    test -f /tmp/iso/pdm-base.squashfs; \
    unsquashfs -f -d /tmp/rootfs -no-progress -no-xattrs \
        /tmp/iso/pdm-base.squashfs || true; \
    # Sanity: the squashfs unpack must produce a valid Debian rootfs.
    test -f /tmp/rootfs/etc/os-release; \
    test -d /tmp/rootfs/usr/bin; \
    # Copy the on-ISO apt pool into the rootfs so the next stage can install
    # PDM offline via file:///srv/pdm-pool. The .debs in
    # dists/trixie/pdm/binary-amd64/ are symlinks into ../../../../proxmox/
    # packages/, so the proxmox/ tree must be copied too for the symlinks to
    # resolve.
    mkdir -p /tmp/rootfs/srv/pdm-pool; \
    cp -a /tmp/iso/dists /tmp/rootfs/srv/pdm-pool/dists; \
    if [ -d /tmp/iso/proxmox ]; then \
        cp -a /tmp/iso/proxmox /tmp/rootfs/srv/pdm-pool/proxmox; \
    fi; \
    # Free everything we no longer need from this stage.
    rm -rf /tmp/iso /iso

# ===========================================================================
# Stage 2: pdm-base — a scratch image filled with the extracted Debian rootfs.
# ===========================================================================
FROM scratch AS pdm-base

COPY --from=extractor /tmp/rootfs/ /

# Fail fast if the rootfs copy did not yield a working Debian userspace.
RUN ["/bin/sh", "-c", "echo OK && cat /etc/os-release"]

# ===========================================================================
# Stage 3: final image.
# ===========================================================================
FROM pdm-base

# Build metadata — populated by CI / `make build`. Empty values are harmless;
# OCI clients show "unknown" rather than failing.
ARG GIT_REVISION=""
ARG BUILD_DATE=""

ENV DEBIAN_FRONTEND=noninteractive \
    S6_OVERLAY_VERSION=3.2.0.2 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_VERBOSITY=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# 1. Install policy-rc.d + systemctl shim BEFORE any apt installs that might
#    trigger service starts via postinst (invoke-rc.d / systemctl).
# ---------------------------------------------------------------------------
COPY rootfs/usr/sbin/policy-rc.d        /usr/sbin/policy-rc.d
COPY rootfs/usr/local/sbin/systemctl    /usr/local/sbin/systemctl
RUN chmod +x /usr/sbin/policy-rc.d /usr/local/sbin/systemctl \
 && ln -sf /usr/local/sbin/systemctl /usr/sbin/systemctl \
 && ln -sf /usr/local/sbin/systemctl /usr/bin/systemctl

# ---------------------------------------------------------------------------
# 2. Neutralise bare-metal-installer placeholders baked into the squashfs:
#    - /etc/machine-id must be empty so systemd-machine-id-setup regenerates
#      a unique id per container instance.
#    - /etc/hostname is removed so Docker can inject the container hostname.
#    - root is currently passwordless from the installer image; lock it. The
#      runtime entrypoint resets it from PDM_ROOT_PASSWORD.
# ---------------------------------------------------------------------------
# /etc/hostname can't be unlinked here — the classic Docker builder bind-mounts
# it into RUN containers. Truncate instead. (Docker overrides /etc/hostname at
# runtime with the actual container hostname regardless.)
RUN : > /etc/machine-id \
 && (: > /etc/hostname 2>/dev/null || true) \
 && (usermod -p '*' root || true)

# ---------------------------------------------------------------------------
# 3. Add the ISO-shipped local pool as an apt source. We keep the upstream
#    debian.sources file in place because pdm-base lacks ca-certificates and
#    a few other stock Debian packages PDM transitively needs. The local pool
#    is unsigned (no InRelease/Release.gpg), hence Trusted: yes. The on-disk
#    component is named "pdm" (not "main" as the Release file claims).
# ---------------------------------------------------------------------------
RUN set -eux; \
    install -d /etc/apt/sources.list.d; \
    { \
        echo 'Types: deb'; \
        echo 'URIs: file:///srv/pdm-pool'; \
        echo 'Suites: trixie'; \
        echo 'Components: pdm'; \
        echo 'Trusted: yes'; \
    } > /etc/apt/sources.list.d/pdm-local.sources

# ---------------------------------------------------------------------------
# 4. Install Proxmox Datacenter Manager from the local (offline) pool.
#    NOTE: do NOT install proxmox-datacenter-manager-meta — it depends on
#    proxmox-default-kernel which is useless and huge inside a container.
#    ca-certificates is needed for HTTPS to managed Proxmox VE/PBS nodes.
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        proxmox-datacenter-manager \
        proxmox-datacenter-manager-ui \
        proxmox-datacenter-manager-client \
        ca-certificates \
        wget \
        xz-utils \
        openssh-server \
    ; \
    # openssh-server is only run when PDM_SSH_ENABLED=1 at runtime (s6 service
    # exits early otherwise). Installed unconditionally so flipping the env var
    # doesn't require a rebuild. Host keys are persisted to pdm-data; daemon
    # config hardening lives in /etc/ssh/sshd_config.d/00-pdm-hardening.conf.
    # Remove the Debian-default sshd systemd units we won't use.
    rm -f /etc/systemd/system/multi-user.target.wants/ssh.service \
          /etc/systemd/system/sshd.service \
          /lib/systemd/system/ssh.service \
          /lib/systemd/system/ssh.socket 2>/dev/null || true; \
    # Wipe any host keys generated by the postinst — we regenerate per-volume
    # at runtime so they persist across container recreation.
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; \
    # PDM's postinst drops a pdm-enterprise.sources file that requires a paid
    # subscription. Remove it so future apt operations (and PDM's own daily
    # update probe) don't 401.
    rm -f /etc/apt/sources.list.d/pdm-enterprise.sources; \
    # Bloat removal: strip the mathjax payload (~45 MB). PDM's Yew/WASM UI
    # does not render math. The package metadata is left intact so apt's
    # dep graph (pdm → docs → libjs-mathjax → fonts-mathjax, all hard
    # Depends) stays satisfied for the runtime daily-update probe.
    # MUST happen in the same RUN as the install so the bytes are excluded
    # from the layer blob, not just whited-out by a later step.
    rm -rf /usr/share/javascript/mathjax \
           /usr/share/fonts/truetype/mathjax \
           /usr/share/fonts/otf/mathjax \
           /usr/share/fonts-mathjax \
           /usr/share/mathjax; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 4b. Roll the squashfs-frozen Debian base forward to current Trixie security
#    + point updates. Without this, glibc/openssl/etc. stay pinned to whatever
#    state the ISO snapshot froze them at on its build date, and the CVE
#    window grows linearly until Proxmox publishes a new ISO. Running this
#    while debian.sources is still present (the section below removes it)
#    lets apt fetch from deb.debian.org one time per build. Tradeoff: strict
#    reproducibility loosens — two builds on different days with the same
#    pinned ISO can diverge by however much Debian has shipped between them.
#    --no-install-recommends prevents new recommends from being pulled in if
#    a package's dep graph changes across the upgrade.
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get -y --no-install-recommends dist-upgrade; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 5. Strip installer-only packages and bloat (~180 MB savings). The squashfs
#    rootfs ships ZFS, GRUB, initramfs tooling, etc. — none useful in a
#    container. The `|| true` hedges against package list drift between ISOs.
# ---------------------------------------------------------------------------
RUN set -eux; \
    # udev is dead weight in containers (no host devices to manage); chrony was
    # kept by mistake but the host kernel's clock is authoritative and PDM
    # doesn't ship its own NTP service in our supervision tree.
    apt-get -y purge --auto-remove \
        grub-common grub-efi-amd64-bin grub-efi-amd64-unsigned grub-pc-bin \
        efibootmgr initramfs-tools initramfs-tools-bin initramfs-tools-core \
        dracut-install klibc-utils libklibc cpio busybox \
        zfsutils-linux zfs-initramfs lvm2 dmeventd dmsetup \
        libzpool6linux \
        btrfs-progs xfsprogs gdisk dosfstools \
        bind9-dnsutils bind9-host pciutils usbutils \
        udev chrony \
        2>/dev/null || true; \
    rm -rf /usr/share/locale/* /usr/share/man/* /usr/share/doc/* \
           /usr/share/info/* /usr/share/grub /usr/lib/grub \
           /var/lib/apt/lists/* /var/cache/apt/archives/*.deb \
           /var/log/* /srv/pdm-pool /tmp/*; \
    # The local pool is gone; nuke the apt source that referenced it so future
    # apt-get update calls don't fail. Also drop debian.sources so PDM's
    # "Updates" panel and apt-get update API endpoint don't hit deb.debian.org
    # per click — the panel will show "no updates available" instead of 27
    # unapplyable Debian package upgrades. Finally, remove orphaned cron
    # snippets (no cron daemon installed).
    rm -f /etc/apt/sources.list.d/pdm-local.sources \
          /etc/apt/sources.list.d/debian.sources \
          /etc/cron.d/e2scrub_all \
          /etc/cron.daily/apt-compat \
          /etc/cron.daily/dpkg; \
    # Truncate the bare-metal-installer banner — cosmetic; never displayed in
    # a container without a TTY but it's a clean detail.
    : > /etc/issue || true

# ---------------------------------------------------------------------------
# 6. Install s6-overlay v3 (noarch + x86_64), checksum-verified.
#    pdm-base already ships wget, xz-utils, and tar; only install them if a
#    future ISO refresh drops one.
# ---------------------------------------------------------------------------
RUN set -eux; \
    missing=""; \
    for cmd in wget xz tar sha256sum; do \
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"; \
    done; \
    if [ -n "$missing" ]; then \
        echo "Bootstrapping missing tools:$missing"; \
        apt-get update; \
        apt-get install -y --no-install-recommends wget xz-utils tar coreutils; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    cd /tmp; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    WGET_OPTS="--tries=5 --waitretry=3 --retry-connrefused --timeout=30"; \
    for pkg in "s6-overlay-noarch.tar.xz" \
               "s6-overlay-x86_64.tar.xz"; do \
        wget $WGET_OPTS "${base}/${pkg}"; \
        wget $WGET_OPTS "${base}/${pkg}.sha256"; \
        sha256sum -c "${pkg}.sha256"; \
        tar -C / -Jxpf "${pkg}"; \
        rm -f "${pkg}" "${pkg}.sha256"; \
    done

# ---------------------------------------------------------------------------
# 6b. Restore the public, no-subscription PDM apt source so PDM's daily-update
#    probe surfaces real available updates in the UI's Updates panel between
#    ISO releases. Scoped to Proxmox's release key via Signed-By; no other
#    apt sources are present in the runtime image. *Applying* these updates
#    inside the container is ephemeral — they survive only until container
#    recreation, so treat the panel populating as a "go rebuild" signal,
#    not as a working live-upgrade mechanism.
# ---------------------------------------------------------------------------
COPY --from=extractor /keys/proxmox-release.gpg /usr/share/keyrings/proxmox-release-trixie.gpg
RUN set -eux; \
    chmod 0644 /usr/share/keyrings/proxmox-release-trixie.gpg; \
    { \
        echo 'Types: deb'; \
        echo 'URIs: http://download.proxmox.com/debian/pdm'; \
        echo 'Suites: trixie'; \
        echo 'Components: pdm-no-subscription'; \
        echo 'Signed-By: /usr/share/keyrings/proxmox-release-trixie.gpg'; \
    } > /etc/apt/sources.list.d/pdm-public.sources

# ---------------------------------------------------------------------------
# 7. Overlay the project rootfs (s6 services, cont-init scripts, shims).
# ---------------------------------------------------------------------------
COPY rootfs/ /

# Re-assert exec bits in case COPY metadata was lost on the host filesystem.
RUN chmod +x /usr/local/sbin/systemctl \
             /usr/sbin/policy-rc.d \
             /usr/local/bin/pdm-init.sh \
             /etc/s6-overlay/s6-rc.d/sshd/run

# ---------------------------------------------------------------------------
# 8. Final cleanup.
# ---------------------------------------------------------------------------
RUN rm -rf /var/lib/apt/lists/* /tmp/* /var/cache/apt/archives/*.deb 2>/dev/null || true

EXPOSE 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q --no-check-certificate -O- https://127.0.0.1:8443/api2/json/ping >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/init"]

# ---------------------------------------------------------------------------
# 9. OCI / Proxmox metadata.
# ---------------------------------------------------------------------------
LABEL org.opencontainers.image.title="Proxmox Datacenter Manager" \
      org.opencontainers.image.description="Proxmox Datacenter Manager 1.0 (ISO Refresh, 2025-12-10) repackaged from the official ISO into a container image" \
      org.opencontainers.image.version="1.0-iso2" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.vendor="Proxmox (repackaged)" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.source="https://www.proxmox.com/en/downloads/proxmox-datacenter-manager" \
      org.opencontainers.image.url="https://pdm.proxmox.com/" \
      org.opencontainers.image.documentation="https://pdm.proxmox.com/docs/" \
      com.proxmox.product="pdm" \
      com.proxmox.iso.release="1.0" \
      com.proxmox.iso.isorelease="2" \
      com.proxmox.iso.kernel="6.17" \
      com.proxmox.iso.debian="13.2-trixie"
