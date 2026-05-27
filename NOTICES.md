# Third-party software notices

This image, produced by `docker build` from this repository, bundles software
from the following sources. The MIT license in `LICENSE` covers **only** the
packaging code in this repository (Dockerfile, scripts under `rootfs/`,
Makefile, compose.yaml, and supporting glue). The bundled software listed
below retains its own license.

For binaries shipped in the runtime image, the package's
`/usr/share/doc/<package>/copyright` file inside the image is the
authoritative Debian DEP-5 copyright record. The image preserves these
files specifically so this disclosure is verifiable from the artifact
itself.

---

## Proxmox Datacenter Manager (and related Proxmox packages)

- **License**: AGPL-3.0-or-later
- **Copyright**: 2023 – 2026 Proxmox Server Solutions GmbH `<support@proxmox.com>`
- **Upstream source**: <https://git.proxmox.com/?p=proxmox-datacenter-manager.git;a=summary>
- **Project home**: <https://pdm.proxmox.com/>
- **Trademark**: "Proxmox" is a trademark of Proxmox Server Solutions GmbH. This repository and the resulting image are not affiliated with, sponsored by, or endorsed by Proxmox Server Solutions GmbH.
- **What's bundled**: `proxmox-datacenter-manager`, `proxmox-datacenter-manager-ui`, `proxmox-datacenter-manager-client`, `proxmox-datacenter-manager-docs` (package metadata only — file payload stripped), `libproxmox-acme-plugins`, `proxmox-mini-journalreader`, `proxmox-termproxy`, `pve-xtermjs`, `pdm-i18n`.
- **In-image disclosures**: each package's `/usr/share/doc/<pkg>/copyright` is preserved verbatim from the upstream `.deb`. Most also ship a `SOURCE` file pointing at the upstream Git URL.

### AGPL §13 compliance (network use)

If you run this image and serve PDM over a network, AGPL §13 grants every user interacting with the program the right to receive the Corresponding Source. The Corresponding Source for Proxmox Datacenter Manager is published at:

> <https://git.proxmox.com/?p=proxmox-datacenter-manager.git;a=summary>

Proxmox keeps this Git repository public; we point downstream users there rather than mirroring. This is the same source-availability pattern Debian and Proxmox themselves use.

---

## Debian Trixie base userland

- **License**: a mix per package — predominantly GPL-2.0-or-later, GPL-3.0-or-later, LGPL-2.1-or-later, LGPL-3.0-or-later, BSD (2-clause and 3-clause), MIT, and Apache-2.0. A few packages use Artistic, MPL-2.0, or zlib.
- **Upstream source**: Debian publishes source for every binary it ships at <https://www.debian.org/distrib/packages> and via `apt source <package>`.
- **In-image disclosures**: `/usr/share/doc/<pkg>/copyright` is preserved for every package. License texts referenced by those copyright files live in `/usr/share/common-licenses/` inside the image (Apache-2.0, Artistic, BSD, CC0-1.0, GFDL, GPL-1, GPL-2, GPL-3, LGPL-2, LGPL-2.1, LGPL-3, MPL-1.1, MPL-2.0).
- **Note**: Debian's `base-files` package does not currently ship `/usr/share/common-licenses/AGPL-3`. Packages that use AGPL (like PDM) include the AGPL notice in their copyright file and point to <https://www.gnu.org/licenses/agpl-3.0.html> for the full license text. The image inherits this convention from upstream Debian and Proxmox unchanged.

---

## s6-overlay (just-containers)

- **License**: ISC
- **Upstream source**: <https://github.com/just-containers/s6-overlay>
- **Version pinned**: see `S6_OVERLAY_VERSION` in `Dockerfile`
- **Verification**: tarballs fetched from the upstream GitHub release are sha256-verified against the publisher's released `.sha256` sidecars at build time.
- **What's bundled**: s6-overlay-noarch and s6-overlay-x86_64, installed under `/command/`, `/init`, `/package/`, `/etc/s6-overlay/`.

---

## Proxmox Trixie release signing key

- **Type**: OpenPGP public key, RSA 4096-bit
- **Fingerprint**: `24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E`
- **User ID**: Proxmox Trixie Release Key `<proxmox-release@proxmox.com>`
- **Source**: <https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg>
- **Used for**: verifying the GPG signature on the PDM ISO at build time, and (in the runtime image) verifying signed apt metadata from `download.proxmox.com/debian/pdm`.
- **Redistribution**: public keys are intended to be redistributed; no license restriction applies.

---

## Build-time tooling (extractor stage only — not in final image)

- `debian:trixie-slim` (Docker official image) — see <https://hub.docker.com/_/debian>
- `curl`, `squashfs-tools`, `libarchive-tools`, `gpg`, `gpgv` — Debian Trixie packages, licenses as above

These are used only during `docker build` and are discarded before the final image is assembled.

---

## Trademark disclaimer

"Proxmox" is a trademark of Proxmox Server Solutions GmbH. "Debian" is a registered trademark of Software in the Public Interest, Inc.

This repository identifies the software it packages by its legal name as a matter of accurate description (nominative use). No endorsement by, affiliation with, or sponsorship of Proxmox Server Solutions GmbH, the Debian Project, or any other trademark holder mentioned here is asserted or implied.

For official Proxmox products and support, contact Proxmox Server Solutions GmbH directly at <https://www.proxmox.com/>.

---

## How to verify these notices match what's in the image

```sh
docker run --rm <image> sh -c 'cat /usr/share/doc/proxmox-datacenter-manager/copyright'
docker run --rm <image> sh -c 'ls /usr/share/doc/ | head -30'
docker run --rm <image> sh -c 'ls /usr/share/common-licenses/'
docker inspect <image> --format '{{ json .Config.Labels }}' | jq
```

If anything here disagrees with what the image actually carries, the image's
`/usr/share/doc/<pkg>/copyright` files are authoritative.
