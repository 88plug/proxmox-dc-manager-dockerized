# Security policy

This is a community Docker repackaging of Proxmox Datacenter Manager (PDM). It is **not** affiliated with or supported by Proxmox Server Solutions GmbH. Vulnerabilities in upstream PDM itself should be reported to Proxmox via their official channels (<https://pdm.proxmox.com/>). This document covers vulnerabilities in the **repackaging** — the Dockerfile, the s6 service definitions, the init scripts, and the auxiliary tools (`scan-proxmox`).

## Reporting a vulnerability

Email the maintainer privately. Do not file public GitHub issues for unpatched vulnerabilities. Include:

- A description of the issue and the affected component (Dockerfile stage, init script, s6 service, scan-proxmox, Makefile target, etc.).
- Steps to reproduce, or a minimal proof-of-concept.
- Your assessment of impact (information disclosure, privilege escalation inside the container, escape to host, denial of service).
- Whether a public fix has been discussed elsewhere.

Expected response time:

- Acknowledgement within 5 business days.
- A first-pass severity assessment within 10 business days.
- Patch and coordinated disclosure timeline negotiated case-by-case. For high-severity issues with an active exploit path, expect a published fix and CVE request within 30 days of acknowledgement.

If a vulnerability affects upstream PDM, the Debian Trixie base, or s6-overlay, the maintainer will coordinate disclosure with the appropriate upstream rather than patching only in this repository.

## Trust model

What you have to trust to use this image safely, in decreasing order of unavoidability:

1. **Proxmox Server Solutions GmbH** — they build the ISO; we extract and run it. Mitigation: the build's three-check verification (sha256 pin, sha256 sidecar, GPG signature against `24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E`) proves the bytes came from Proxmox; it does not audit what Proxmox put in them.
2. **The Debian project** — `dist-upgrade` during build pulls security/point updates from `deb.debian.org` with apt's standard repo signing. Mitigation: Debian's archive keys are pre-shipped in the squashfs and transitively verified by the ISO GPG check.
3. **just-containers (s6-overlay)** — tarballs are sha256-verified against the publisher's released sidecars. Mitigation: ISC-licensed, small (~1k lines of C), independently auditable.
4. **The image maintainer** — packaging code, init scripts, scan-proxmox. Mitigation: source-only repo, every commit reviewable, signed releases (see "Verifying a release" below).
5. **GitHub Actions (if you use the published image)** — workflow logs are public, SLSA provenance attestations are published per build, image is signed via Cosign keyless OIDC. Mitigation: `gh attestation verify` + `cosign verify` against the OIDC issuer tie the image digest to a specific workflow run on a specific commit.

What is **not** in the trust model:

- No outbound calls at runtime to maintainer-controlled infrastructure. All outbound is to (a) registered Proxmox remotes you add yourself, (b) `download.proxmox.com` for the PDM updates probe, and (c) wherever you configure ACME to.
- No telemetry, no analytics, no auto-update.

## What's hardened by default

- `proxmox-datacenter-api` runs as `www-data`. Only `proxmox-datacenter-privileged-api` runs as root, in a single process that talks to the API daemon over a UNIX socket on a tmpfs.
- No `--privileged`, no `cap_add`, no host bind mounts in the default `compose.yaml`. `no-new-privileges:true` is set.
- Apt sources at runtime are scoped to the public PDM no-subscription repo, signed by the Proxmox Trixie release key (binding via `Signed-By:`).
- sshd is opt-in via `PDM_SSH_ENABLED=1`. When enabled: password auth disabled, key-only root login, no X11/agent/TCP forwarding, max 3 auth attempts, 30 s login grace. Host keys persist to `pdm-data` so fingerprints don't churn on container recreation.
- Subscription-enterprise apt source is deleted at build time, so apt operations can't hit `enterprise.proxmox.com` and 401-loop.
- `/sbin/{reboot,shutdown,halt,poweroff}` are stubbed because the upstream binaries would kill the container; PDM's UI buttons are no-ops by design.

## Verifying a release

The CI-published image at `ghcr.io/88plug/proxmox-dc-manager-dockerized` carries:

1. **OCI image signature** via Cosign keyless OIDC. **Requires cosign v3 or newer.** Verify:
   ```
   cosign verify ghcr.io/88plug/proxmox-dc-manager-dockerized:<tag> \
     --certificate-identity-regexp 'https://github.com/88plug/.*' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com
   ```

   > Cosign v3 attaches signatures as OCI referrers (Sigstore bundles). Cosign v2 only
   > looks for the legacy `sha256-<digest>.sig` tag, so it reports `no signatures found`
   > on these images even though the signature is present and valid. That is a client
   > version mismatch, not a missing signature — check `cosign version` before concluding
   > anything is wrong. Verified against v3.1.3 (passes) and v2.6.1 (false negative).
2. **SLSA build provenance**. Verify:
   ```
   gh attestation verify oci://ghcr.io/88plug/proxmox-dc-manager-dockerized:<tag> --owner 88plug
   ```
3. **SBOM** (SPDX, generated by syft via BuildKit) attached as an in-toto attestation on the image index. Inspect with:
   ```
   docker buildx imagetools inspect ghcr.io/88plug/proxmox-dc-manager-dockerized:<tag> \
     --format '{{ json .SBOM }}'
   ```

   > Not `cosign download sbom` — that command reads the legacy cosign SBOM *attachment*, which
   > this image does not carry (the format is deprecated upstream). Against these images it
   > reports "does not have an SBOM attached at the index level" even though the SBOM is present
   > as a BuildKit attestation. Verified: the command above returns 239 packages including
   > `proxmox-datacenter-manager 1.1.7`.

For local builds, the build itself runs the ISO sha256 + GPG verification before unpacking, so the same authenticity guarantees apply.

## Known accepted risks

These are documented limitations the maintainer has decided not to fix:

- **Subscription warning popup with zero / community-only remotes.** Upstream UI behavior; not caused by repackaging. Optional cosmetic patch is applied at build time; if it stops matching upstream's JS bundle, the popup will reappear until the patch is updated.
- **Reboot/Shutdown UI buttons do nothing.** Calling out to `/var/run/docker.sock` from inside the container would be equivalent to host root. Not worth the escalation.
- **Network/DNS/Time panel edits don't take effect.** Container filesystem semantics; not safely fixable without bind mounts that break portability.
- **Subscription "no valid subscription" header in API responses.** Same root cause as the popup; same patch applies cosmetically.

## Out of scope

- Vulnerabilities in upstream PDM, Debian Trixie packages, or s6-overlay (report to those projects).
- Misconfiguration of the host Docker daemon (host firewall, exposed Docker socket, etc.).
- Threats from a compromised host operating system — once an attacker controls the host kernel, container isolation is moot.
- Use of `network_mode: host` without a host firewall in front. Documented in the README.
