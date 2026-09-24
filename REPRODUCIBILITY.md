# Reproducibility

This document spells out exactly what is bit-identical across builds and what isn't, so a reviewer can independently rebuild and know what to expect.

## Inputs

A build is uniquely determined by:

| Input                                | Pinning                                                                                 | Drift risk                    |
| ------------------------------------ | --------------------------------------------------------------------------------------- | ----------------------------- |
| `proxmox-datacenter-manager_1.1-1.iso` | sha256 in Dockerfile (`PDM_ISO_SHA256`) + GPG signature (`PROXMOX_KEY_FPR`)             | Frozen by Proxmox until next release |
| `proxmox-datacenter-manager` `1.1.7`  | Exact version in Dockerfile (`PDM_PKG_VERSION`, `PDM_UI_PKG_VERSION`) + apt GPG against the pinned release key, then `apt-mark hold` | Frozen until `pdm-version-detector` bumps the pin |
| Proxmox Trixie release GPG key       | sha256 in Dockerfile (`PROXMOX_KEY_SHA256`) + fingerprint check                          | Frozen until Proxmox rotates the key |
| s6-overlay v3                        | Version in Dockerfile (`S6_OVERLAY_VERSION`) + sha256 sidecar from upstream release      | Frozen until we bump          |
| BuildKit Dockerfile frontend         | Minor pin — `# syntax=docker/dockerfile:1.25`; bump deliberately, note in commit         | Frozen until we bump          |
| `debian:trixie-slim` (extractor)     | Tag only — Docker pulls the current digest unless `make refresh` or `--pull`             | Daily drift                   |
| `deb.debian.org` package versions    | Resolved at build time during `apt-get install` and `apt-get dist-upgrade`              | Drifts every Debian point/security release |
| Project source (`rootfs/`, Dockerfile) | Git commit — `org.opencontainers.image.revision` label                                  | Frozen by commit              |

## What's bit-identical

A second build, on the same commit, on the same day, on a similar machine:

- The extracted `pdm-base.squashfs` and ISO apt pool layers — Proxmox's bytes don't move.
- PDM packages — pinned to an exact version from the official `pdm-no-subscription` repository and held, so repeated builds resolve the same `.deb`s until the pin is bumped.
- s6-overlay binaries.
- The `rootfs/` overlay.

## What drifts

- **Debian base packages** picked up by `apt-get install` for cross-dependency resolution (e.g. `ca-certificates` if Debian published a new version).
- **All packages** lifted by the `dist-upgrade` step. This is the dominant source of drift; expect 30+ packages to differ between builds two weeks apart.
- **Proxmox support packages** — `novnc-pve`, `pve-xtermjs`, `proxmox-widget-toolkit`, `proxmox-termproxy` and friends. The `pdm-no-subscription` source is configured before `dist-upgrade`, so these roll forward with the repository rather than staying frozen at the ISO's build. That is deliberate: they are PDM's own dependencies and are meant to move with it. Only the four `proxmox-datacenter-manager*` packages are held.
- **Layer hashes** of every layer after the dist-upgrade step.
- **Final image digest** — different on any two builds where the Debian base or dist-upgrade pulled new versions.

The PDM packages themselves (the part most reviewers care about) are installed at an exact pinned version and then `apt-mark hold`-ed, so they don't drift between builds of the same commit — not even across the `dist-upgrade`.

## Reproducing a published build

For a build published by the project's CI (GHCR), the same commit + same date should produce the same image. Verify via:

1. Check out the commit referenced by `org.opencontainers.image.revision` on the published image:
   ```
   docker inspect <image> --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
   git checkout <revision>
   ```
2. Note the `created` label — Debian state drifts daily. Rebuilds on a later date will diverge.
   ```
   docker inspect <image> --format '{{ index .Config.Labels "org.opencontainers.image.created" }}'
   ```
3. Build locally:
   ```
   make build
   docker images proxmox-dc-manager:local --no-trunc --format '{{ .Digest }}'
   ```
4. The PDM-related layers should match. Debian-layer drift is expected if the published build is more than a few hours old.

For exact reproduction, snapshot `deb.debian.org` via a local apt mirror or `apt-cacher-ng` and pin the build to it. The project doesn't ship this — it's out of scope for a community Docker repackaging — but the build is structured so this can be added by a downstream consumer who needs strict reproducibility.

## Verifying integrity of a fresh build

After `make build`:

```sh
# Inspect labels.
docker inspect proxmox-dc-manager:local --format '{{ json .Config.Labels }}' | jq

# Confirm PDM is at the pinned version and held (so dist-upgrade can't
# have moved it).
docker run --rm proxmox-dc-manager:local sh -c \
  'dpkg -l | grep proxmox-datacenter-manager; apt-mark showhold'

# Confirm the dist-upgrade lifted Debian Trixie.
docker run --rm proxmox-dc-manager:local sh -c \
  'cat /etc/os-release; dpkg -l libc6 openssl libssl3 systemd | tail -n+5'
```

## Verifying a CI-built release

See [SECURITY.md](SECURITY.md) — Cosign signature + SLSA build provenance + SBOM attestation tie the image digest to a specific workflow run on a specific commit. That's the right way to prove "this image came from this code without any extra steps in between."
