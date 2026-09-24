# proxmox-dc-manager-dockerized

A community-maintained Docker repackaging of the official **Proxmox Datacenter Manager (PDM)** ISO. **This project is not affiliated with or endorsed by Proxmox Server Solutions GmbH.**

[![build-and-sign](https://github.com/88plug/proxmox-dc-manager-dockerized/actions/workflows/build-and-sign.yml/badge.svg)](https://github.com/88plug/proxmox-dc-manager-dockerized/actions/workflows/build-and-sign.yml)
[![release](https://img.shields.io/github/v/tag/88plug/proxmox-dc-manager-dockerized?label=release&color=informational)](https://github.com/88plug/proxmox-dc-manager-dockerized/tags)
[![packaging license](https://img.shields.io/badge/packaging-MIT-green)](LICENSE)

<!-- TODO(demo-video): drag docs/demo.mp4 into a GitHub editor box to mint a
     user-attachments URL, then paste that URL here on its own line — only
     user-attachments URLs render GitHub's inline video player. -->

![Demo: docker compose up, log in as root, and the Proxmox Datacenter Manager dashboard appears with remotes, resource usage, and task summaries](docs/demo.gif)

## Why this approach

The build downloads the official PDM ISO exactly once (sha256-pinned, GPG signature verified against the pinned Proxmox release key, cached as a Docker layer) and uses its squashfs root as the base filesystem — a real Proxmox-built userspace, not a Debian image with PDM bolted on.

PDM itself is then installed at an exact, pinned version from the official `pdm-no-subscription` repository, which is GPG-verified against the very same release key the ISO was checked with — no second trust root. This matters because Proxmox ships PDM fixes through apt rather than by re-cutting the ISO: ISO 1.1-1 froze PDM at `1.1.1`, while the repository had reached `1.1.7` two months later with no new ISO in sight. The packages are `apt-mark hold`-ed after install, so the weekly rebuild below cannot silently walk the product forward either — version changes are a reviewed pin bump, never a surprise.

The Debian base is separately rolled forward to current Trixie security state in a documented, deliberate step (see `REPRODUCIBILITY.md` for the tradeoff). Two daily detectors keep the pins honest with no human in the loop: [the PDM version detector](.github/workflows/pdm-version-detector.yml) watches the apt repository, [the ISO bump detector](.github/workflows/iso-bump-detector.yml) watches for a new ISO. Both verify a full build and a live `/api2/json/ping` before anything is published, and both fail loudly rather than going quietly stale.

## At a glance

- Base: `pdm-base.squashfs` extracted from the PDM ISO (Debian Trixie, rolled forward to current point release at build time)
- Supervisor: s6-overlay v3 (no systemd, no `--privileged` required)
- Web UI: HTTPS on port `8443`
- Volumes: `pdm-config` (`/etc/proxmox-datacenter-manager`), `pdm-data` (`/var/lib/proxmox-datacenter-manager`)
- Tmpfs: `/run/proxmox-datacenter-manager`
- Architecture: `linux/amd64` only (PDM has no upstream arm64 build)
- PDM package version: `1.1.7` — installed from the official `pdm-no-subscription` repository, GPG-verified against the same pinned Proxmox release key as the ISO, pinned and held so a rebuild can't drift it
- ISO: `proxmox-datacenter-manager_1.1-1.iso` (PDM 1.1, ISO release 1)
  - sha256 `11a55a069ba564220bd986241b57920a83781d40be18d6f2bf7b9b12696ae2cc`
  - GPG-signed by `24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E` (Proxmox Trixie Release Key); the build verifies the detached signature with gpgv before unpacking

## Quickstart

Prebuilt image (signed, attested — see `SECURITY.md` to verify):

```sh
docker run -d --name pdm -p 8443:8443 \
  -e PDM_ROOT_PASSWORD=changeme \
  -v pdm-config:/etc/proxmox-datacenter-manager \
  -v pdm-data:/var/lib/proxmox-datacenter-manager \
  ghcr.io/88plug/proxmox-dc-manager-dockerized:latest
```

Or build from source:

```sh
git clone https://github.com/88plug/proxmox-dc-manager-dockerized.git
cd proxmox-dc-manager-dockerized
docker compose up -d --build
```

The build's extractor stage downloads and verifies the official Proxmox Datacenter Manager ISO (~1.4 GB) automatically and caches it as a Docker layer.

Open `https://localhost:8443/`, accept the self-signed certificate, and log in:

- **User name:** `root`
- **Realm:** `Linux PAM` (`root@pam`)
- **Password:** `changeme` (the default in `compose.yaml`; **change it immediately** from the UI under Datacenter → Permissions → Users, or by editing `compose.yaml` and recreating with `PDM_ROOT_PASSWORD_FORCE=1`)

## Configuration

All configuration is set directly in the `environment:` block of `compose.yaml`. Edit it, then `docker compose up -d` to apply.

| Variable                    | Default       | Description                                                                                                  |
| --------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------ |
| `PDM_ROOT_PASSWORD`         | `changeme`    | Initial plaintext password for the container's Linux `root` user, used by the `pam` realm.                   |
| `PDM_ROOT_PASSWORD_HASHED`  | `""`          | Pre-hashed crypt(3) string for `root`. **Checked before** `PDM_ROOT_PASSWORD` and wins if both are set.      |
| `PDM_ROOT_PASSWORD_FORCE`   | `"0"`         | When `1`, re-seeds the root password on every container start (otherwise first-run only).                    |
| `PDM_ROOT_SSH_KEYS`         | `""`          | Newline-separated authorized SSH keys written to root's `authorized_keys` (no sshd is run by default).       |
| `PDM_FQDN`                  | `pdm.local`   | Fully-qualified hostname; appears in the UI and in the self-signed certificate's CN/SAN.                     |
| `PDM_FORCE_REGEN_CERT`      | `"0"`         | When `1`, auto-rotate the self-signed TLS cert when `PDM_FQDN` changes. CA-signed certs (subject != issuer) are never touched. |
| `PDM_ALLOW_NO_PASSWORD`     | `"0"`         | When `0` (default), refuse to start if no root password is set. Set to `1` only for debug / pre-seeded shadow scenarios. |
| `PDM_MAILTO`                | `""`          | Default address PDM uses for system notifications. Defaults to `root@${PDM_FQDN}` if empty.                  |
| `PDM_TZ` / `TZ`             | `Etc/UTC`     | Timezone for daemons and libc / log timestamps.                                                              |

The published port is hardcoded to `8443:8443/tcp` in `compose.yaml`'s `ports:` section — change it there if you need a different host port.

### TLS via env vars

`PDM_TLS_CERT_B64` and `PDM_TLS_KEY_B64` accept base64-encoded PEM. Both must be set, or both empty. On every boot, `pdm-init.sh` decodes them, validates the cert/key match by public-key digest, and writes them to `/etc/proxmox-datacenter-manager/auth/api.{pem,key}`. The cert is treated as CA-signed (subject != issuer), so the FQDN-mismatch auto-rotate logic leaves it alone. Generate with `base64 -w0 < fullchain.pem`.

### SSH access (opt-in)

`docker compose exec pdm bash` is the default way in. To enable a real sshd inside the container, set `PDM_SSH_ENABLED: "1"`, populate `PDM_ROOT_SSH_KEYS` (newline-separated public keys), and uncomment the `2222:22/tcp` port mapping in `compose.yaml`. The daemon is hardened: key-only root login (`PermitRootLogin prohibit-password`), password and challenge-response auth disabled, no X11/agent/TCP forwarding, max 3 auth attempts, 30 s login grace. Host keys are persisted to the `pdm-data` volume so the host fingerprint survives `docker compose up --force-recreate`. If `PDM_SSH_ENABLED=1` but no authorized_keys are present, the service refuses to start (otherwise password-auth-disabled sshd would be locked out).

## Volumes

Two named volumes hold all persistent state. Both must survive container recreation; losing them is destructive.

- **`pdm-config`** -> `/etc/proxmox-datacenter-manager`
  Holds auth keys (`auth/authkey.key`, `auth/authkey.pub`), the CSRF signing key, self-signed TLS material (`auth/api.pem`, `auth/api.key`), `user.cfg`, `access/acl.cfg`, `remotes.cfg`, and API tokens. **Deleting this volume is equivalent to a factory reset:** all federated remotes, ACLs, and signing keys are gone.
- **`pdm-data`** -> `/var/lib/proxmox-datacenter-manager`
  Metric/RRD cache, task logs, and the container init-completion flag.

A tmpfs is mounted at `/run/proxmox-datacenter-manager` for the privileged daemon's UNIX socket and other ephemeral runtime state.

## Architecture

PDM ships as two cooperating daemons, both supervised by s6-overlay v3:

```
   Browser
     |
     v
  :8443/HTTPS
     |
     v
   [s6-overlay]
     |
     +-- proxmox-datacenter-api          (www-data)  --+
     |                                                 |  UNIX socket
     +-- proxmox-datacenter-privileged-api (root)  <---+  /run/proxmox-datacenter-manager/
                  |
                  v
         /etc/proxmox-datacenter-manager   (auth keys, certs, ACLs)
```

On every start, the privileged daemon's `setup` subcommand runs first and is **idempotent**: it owns first-run filesystem bootstrap (creating the auth keypair, CSRF key, self-signed TLS cert, and directory permissions), and is a no-op if those already exist. The unprivileged API daemon then comes up, terminates HTTPS on `8443`, and talks to the privileged side over the local socket for anything requiring root (PAM auth, certificate writes).

s6-overlay is used instead of `systemd-in-a-container` because it does not require `--privileged`, cgroup mounts, or a host PID-1 substitute. ISO repackaging is preferred over an `apt`-only build because it pins every byte of the resulting image to a published Proxmox release artifact.

The s6-overlay scan dir runs the following services: `init-pdm` (oneshot, first-run filesystem bootstrap), `proxmox-datacenter-privileged-api` (longrun, runs `setup` first then stays as root for PAM auth + cert writes), `proxmox-datacenter-api` (longrun, drops to `www-data` and terminates HTTPS on `8443`), `journald` (longrun, standalone `systemd-journald` that satisfies PDM's syslog write path and powers the local Syslog UI), `pdm-log-forwarder` (longrun, tails `access.log` / `auth.log` to container stdout for log aggregators), and `proxmox-datacenter-manager-daily-update` (longrun, sleep-loop replacement for the upstream systemd timer).

## Logs and observability

Three logging surfaces:

- **`docker logs proxmox-dc-manager`** — daemon lifecycle messages from
  init/setup, plus tail of PDM's access and auth logs prefixed
  `[pdm-access]` / `[pdm-auth]` so log aggregators (Loki, Vector, Datadog)
  pick up HTTP and login events.
- **Inside the container** — `/var/log/proxmox-datacenter-manager/api/{access,auth}.log`
  and `/var/log/proxmox-datacenter-manager/tasks/`. PDM rotates these itself.
- **PDM UI → Datacenter → localhost → Syslog** — works via a standalone
  `systemd-journald` we run in-container; pure container output without
  persistent journal storage. To live-tail what would normally hit syslog:
  `docker compose exec pdm journalctl -f`.

## Adding a Proxmox VE / PBS remote

In the web UI, navigate to **Remotes -> Add** and register the target node. PDM will reach it over:

- TCP `8006` for Proxmox VE
- TCP `8007` for Proxmox Backup Server

Make sure those ports are reachable from the container's network namespace (typically the Docker bridge). Authentication uses an **API token** created on the remote node, not SSH; the token must have appropriate ACLs (`PVEAuditor` is enough for read-only inventory).

See the upstream documentation for current setup steps: <https://pdm.proxmox.com/docs/>.

### Auto-discover with the bundled scanner

The image ships a small companion script, `scan-proxmox`, that walks a CIDR, detects PVE/PBS endpoints, extracts each one's TLS fingerprint, mints an API token using the credentials you supply, and either prints the data needed for **Remotes -> Add** or registers the remotes into PDM directly.

```sh
# Print a table of every Proxmox endpoint on the LAN, ready to copy/paste.
make scan CIDR=192.168.1.0/24 USER=root@pam PASS=melloa

# Same scan, plus auto-register each finding into the running PDM.
make scan-register CIDR=192.168.1.0/24 USER=root@pam PASS=melloa
```

Variables:

- `CIDR` (default `192.168.1.0/24`)
- `USER` (default `root@pam`) — must already exist on each Proxmox endpoint
- `PASS` — required; the password for `USER`. Passed to the script via the `SCAN_PASSWORD` env var so it never appears in process listings on the host
- `TOKEN_NAME` (default `pdm-scanner`) — the API token id minted on each endpoint
- `SCAN_ARGS` — extra flags forwarded to the script (e.g. `SCAN_ARGS='--ports 8006 --workers 32 --timeout 1.0'`)

PVE clusters are detected automatically: if the scanner finds three nodes that all belong to cluster `prod-cluster`, they are grouped into a **single** PDM remote `prod-cluster` whose `nodes` list contains every member's address and per-node TLS fingerprint. Standalone PVE/PBS nodes each become their own remote.

The minted token has `privsep=0`, meaning it inherits the user's full ACLs (typically root@pam, which is superuser). Scope it down afterwards via the PVE/PBS UI if you want.

The script exits with `0` on partial-success (some hosts found, some skipped) and is safe to re-run — pass `--force-token` (already wired by `make scan-register`) to overwrite an existing `pdm-scanner` token without prompting. Run `docker compose exec pdm scan-proxmox --help` for the full flag list.

## Operations

The included `Makefile` wraps the most common workflows. Run `make help` for the full list.

```sh
make build         # build the image (extractor stage downloads the ISO automatically)
make refresh       # cache-busted rebuild: re-pulls Debian Trixie security updates
make up            # start container in background
make down          # stop & remove container (volumes kept)
make restart       # restart the pdm service
make logs          # tail container logs
make shell         # bash inside the running container
make init-shell    # bash inside a freshly-built image (debug)
make pdm-version   # print PDM version from inside the container
make set-password  # reset root password using compose.yaml's PDM_ROOT_PASSWORD
make lint          # validate compose syntax
make verify        # hadolint + shellcheck + compose lint (best-effort)
make cert-show     # print TLS subject/SAN/expiry from the running container
make journalctl    # live-tail the in-container systemd journal
make backup        # tar both volumes to ./pdm-backup-<timestamp>.tar.gz
make restore FILE=…  # restore both volumes from a backup (container must be stopped)
make clean         # remove image (keep volumes)
make reset         # DANGER: delete all volumes (factory reset)
```

## Backup and restore

`pdm-config` is irreplaceable — losing it factory-resets the install (auth keypair, registered remotes, ACLs, API tokens, TLS material all gone). `pdm-data` holds metrics and task logs (rebuildable but historically valuable). Back both up.

```sh
make backup                                   # writes pdm-backup-YYYYMMDDTHHMMSSZ.tar.gz
make down                                     # restore needs the container stopped
make restore FILE=pdm-backup-20260527T180000Z.tar.gz
make up
```

The backup is a single gzipped tar of both volume contents, taken via a one-shot container that shares the compose-managed volume bindings (so it works regardless of `COMPOSE_PROJECT_NAME`). The container can stay running during `make backup`; restore requires it stopped. Store the resulting tarball off-host — losing both volumes and the backup is unrecoverable.

## Network mode

Default `compose.yaml` uses bridge networking with an explicit `8443:8443/tcp` mapping. For most deployments this is correct. Switch to `network_mode: host` only when one of these applies:

- A managed PVE/PBS remote IP-allowlists by source address — bridge SNATs to the docker0 gateway, host mode preserves the real host IP.
- Remotes live on a VLAN/subnet the host can reach by routing but the docker bridge can't.
- `make scan CIDR=...` needs to see the real LAN for ARP-level discovery.

Tradeoffs in host mode:
- The UI binds to `:8443` on **every** host interface; if the host has a public IP, PDM is exposed unless you front it with a host-level firewall.
- DNS / Time / Network panels stay broken (they read container filesystem state regardless of network mode); the DNS panel can additionally be dangerous if Docker's resolv.conf handling bind-mounts the host's file in. Don't touch the DNS panel under host networking.
- The `ports:` block becomes a no-op (silently ignored) — drop it in your override.

A `compose.host.yaml` overlay opt-in pattern: keep the default `compose.yaml`, add `compose.host.yaml` with `network_mode: host` + empty `ports: []`, and start with `docker compose -f compose.yaml -f compose.host.yaml up -d`.

## Security model

What's verified end-to-end and what isn't:

- **ISO authenticity**: the extractor stage sha256-pins the ISO **and** GPG-verifies it against the Proxmox Trixie release key (`24B30F06ECC1836A4E5EFECBA7BCD1420BFE778E`). The key itself is fetched live from `enterprise.proxmox.com`, sha256-pinned at fetch time, and its fingerprint re-checked after import. Three independent checks before the ISO is unpacked.
- **s6-overlay**: tarballs fetched from the just-containers GitHub release, sha256-verified against the published `.sha256` sidecars in the same release.
- **Debian base updates**: pulled from `deb.debian.org` during build with apt's standard repo signing (Debian archive keys, pre-shipped in the squashfs).
- **Runtime apt sources**: all removed after the build's install + dist-upgrade. The runtime image has no apt sources; runtime apt-update is a no-op.
- **Process isolation**: `proxmox-datacenter-api` runs as `www-data`; only `proxmox-datacenter-privileged-api` runs as root, and only it has the auth keys + cert private key. They communicate over a UNIX socket on a tmpfs.
- **Capabilities**: no `--privileged`, no `cap_add`, `no-new-privileges:true` in compose, no host bind mounts.
- **Network**: only inbound `:8443` (and optional `:22` if `PDM_SSH_ENABLED=1`); outbound `:8006` (PVE) / `:8007` (PBS) per registered remote.

What is **not** verified and you have to trust:

- The Proxmox ISO contents themselves (you verify it came from Proxmox; you don't audit what Proxmox put in it).
- The Debian package signing keys shipped inside the ISO's squashfs (transitively trusted from the ISO's GPG verification).
- The image maintainer — to mitigate, pin to a specific image digest and review diffs across versions.

See `SECURITY.md` for reporting vulnerabilities and the disclosure timeline.

## Upgrading

When Proxmox publishes a new ISO:

1. Update `PDM_ISO_URL` and `PDM_ISO_SHA256` (the `ARG` lines in the `Dockerfile`'s `extractor` stage).
2. `make build && docker compose up -d`

Named volumes are preserved across rebuilds, so configuration and remotes carry over. The PDM postinst handles intra-version migrations automatically (e.g. the 1.0.0 -> 1.0.1 `ldap_passwords.json` rewrite). Review the upstream changelog (<https://pdm.proxmox.com/docs/>) before upgrading.

### Self-maintaining workflows

The repository's GitHub Actions are designed to run for years without human attention. After the initial `git push`, no one needs to read email, review PRs, or click anything in GitHub.

- **`.github/workflows/iso-bump-detector.yml`** — daily 04:17 UTC poll of `download.proxmox.com/iso/`. When a newer `proxmox-datacenter-manager_*.iso` appears, the workflow runs a full verification build (sha256 + GPG against the pinned Trixie release key + runtime smoke test on `/api2/json/ping`) and, only on success, pushes the pin bump directly to `main`, creates a `v<version>` tag, and dispatches `build-and-sign.yml` at that tag (GITHUB_TOKEN pushes deliberately never trigger workflows, so an explicit `workflow_dispatch` is required), which publishes the signed and attested release image to GHCR. No PR, no human merge step.
- **`.github/workflows/build-and-sign.yml`** — fires on push/tag/PR and on a weekly cron (Sunday 03:17 UTC). The weekly run uses `--no-cache --pull` so the `:edge` tag picks up current Debian Trixie security updates without any commit. PR builds include a runtime smoke test (boot the image, poll `/api2/json/ping`) before the image is signed and pushed. All builds: SBOM, SLSA build provenance, Cosign keyless signing, Trivy scan to GitHub Security tab.
- **`.github/dependabot.yml`** — weekly auto-PRs for GitHub Actions and `FROM` lines in the Dockerfile.
- **`.github/workflows/dependabot-auto-merge.yml`** — listens for `build-and-sign` to finish on a Dependabot PR; if it passed and the PR is not a major version bump, merges via the REST API. Works without the "Allow auto-merge" repo setting. Major version bumps are left open as the one non-trivial human-review hook in the system.
- **`.github/workflows/ghcr-retention.yml`** — monthly cleanup of GHCR images: keeps every `v*` release plus `main`, `latest`, `edge`, the most recent 8 `weekly-*` builds, and the most recent 30 `sha-*` builds; deletes the rest and every untagged manifest.

#### One-time repo settings (none required, but improve quality of life)

The workflows function correctly with GitHub's default repo settings. If you want to harden further:

- **Settings → Actions → General → Workflow permissions** — no change needed: every workflow declares an explicit `permissions:` block, which overrides the repo-level default in either direction.
- **Settings → General → Pull Requests → Automatically delete head branches** — optional cosmetic.
- **Settings → General → Pull Requests → Allow auto-merge** — *not* required; `dependabot-auto-merge.yml` uses the REST API directly to bypass the need for this toggle.
- **Branch protection on `main`** — leave off, or include `iso-bump-bot` in the bypass list. Strict required-reviewers will block the bot's pushes.

#### When things actually break (years-out failure modes)

- **Proxmox rotates the Trixie release GPG key**: the iso-bump verification build fails because the live key's sha256 no longer matches `PROXMOX_KEY_SHA256`. The bot stops bumping (correctly — refuses to trust a key it didn't expect). The running image keeps working; `:edge` continues to update via dist-upgrade for as long as Proxmox's apt repo signing key (separate from the ISO release key) is still trusted. Human fix: bump `PROXMOX_KEY_SHA256` and `PROXMOX_KEY_FPR` once.
- **Debian Trixie reaches EOL** (~2028): `dist-upgrade` starts returning nothing useful; eventually `debian.sources` URLs 404. Human fix: bump to next Debian release, retest.
- **GitHub deprecates a workflow API** (rare, well-telegraphed): Dependabot opens the PR; auto-merge runs it; if smoke test passes, it lands. Otherwise the bot's PR sits open as the only deferred-action signal.

### Debian base updates between ISO releases

The Dockerfile runs `apt-get dist-upgrade` against `deb.debian.org` once during the build (after PDM is installed, before the apt sources are wiped). That lifts glibc, openssl, ca-certificates, and the rest of the Debian Trixie base to current security/point-release state without waiting for Proxmox to publish a new ISO.

- `make build` — incremental; Docker caches the dist-upgrade layer, so a second build the next day reuses yesterday's snapshot.
- `make refresh` — `--pull --no-cache`; forces a fresh pull of `debian:trixie-slim` in the extractor and a fresh `apt-get update && dist-upgrade` in the final image. Use this when you want current Debian patches without bumping the ISO pin.

Tradeoff: hermeticity loosens. Two builds on different days with the same pinned ISO can diverge by however much Debian has shipped between them. The PDM packages themselves are unaffected — they are pinned to an exact version and `apt-mark hold`-ed, so `dist-upgrade` cannot move them.

## Troubleshooting

- **Login fails immediately.** Confirm `PDM_ROOT_PASSWORD` (or `PDM_ROOT_PASSWORD_HASHED`) is set in `compose.yaml`. To re-seed on an existing volume, set `PDM_ROOT_PASSWORD_FORCE: "1"` and `docker compose up -d` (or run `make set-password`).
- **Browser shows a certificate warning.** Expected: TLS material is self-signed and (re)generated by the privileged daemon's `setup` subcommand on first start. To install your own cert, drop a PEM bundle without passphrase at `auth/api.pem` and the matching key at `auth/api.key` inside the `pdm-config` volume, then `make restart`.
- **PDM cannot reach a managed PVE/PBS node.** Confirm outbound TCP `8006` (PVE) / `8007` (PBS) from the container is not blocked, and verify the API token still exists and has the required ACL on the remote.
- **Build fails on the ISO download.** Verify outbound HTTP to `download.proxmox.com`. To use a private mirror, override the URL: `docker compose build --build-arg PDM_ISO_URL=https://your.mirror/pdm.iso`. To pin a different ISO release, also override `PDM_ISO_SHA256`.
- **Build fails with "checksum mismatch".** The pinned `PDM_ISO_SHA256` in the `Dockerfile` does not match what Proxmox is currently serving. Either (a) Proxmox refreshed the ISO under the same URL — fetch the new sha256 from `http://download.proxmox.com/iso/proxmox-datacenter-manager_*.iso.sha256` and update the Dockerfile, or (b) the download was corrupted; rebuild with `--no-cache`.
- **Logs show priv-api `setup` running on every restart.** Expected and intentional; the subcommand is idempotent and ensures auth material exists before the API daemon starts.
- **Browser shows wrong hostname after changing `PDM_FQDN`.** The cert from the previous FQDN is preserved across restarts. Set `PDM_FORCE_REGEN_CERT: "1"` and restart, or manually delete `auth/api.pem` and `auth/api.key` from the `pdm-config` volume. CA-signed certs (subject != issuer) are intentionally never auto-rotated.
- **Reboot/Shutdown buttons in the UI do nothing visible.** Expected — `/sbin/reboot` and `/sbin/shutdown` are stubbed in this image because actually rebooting kills the container. Use `docker compose restart pdm` from the host.
- **Network panel shows only `lo`.** Expected — the panel only reads `/etc/network/interfaces`, which we ship as a loopback-only stub. The container's real `eth0` is managed by Docker. Don't edit it from the UI; edits don't apply.

## Limitations

- **x86_64 only.** No upstream arm64 builds; do not attempt to run on Apple Silicon or Raspberry Pi hosts.
- **Not for production.** PDM is officially deployed via the Proxmox ISO/apt repository onto a real Debian host. This image exists for homelab and lab-test scenarios.
- **No high availability.** PDM's HA features assume a real Proxmox cluster substrate and are not meaningful inside a single container.
- **No notifications yet.** PDM (as of 1.1) does not implement the Notifications subsystem (no SMTP/Gotify/webhook endpoint API exists upstream — see <https://pdm.proxmox.com/docs/roadmap.html>). When upstream lands the feature, the SMTP target dials the relay directly and requires no local MTA — this image will work as-is.
- **Subscription status shows "Unknown subscriptions".** PDM aggregates remote subscriptions; with zero remotes the dashboard's Remote Subscription Status panel reports "Unknown subscriptions" (PDM 1.1 no longer shows a login popup for this). Expected upstream behavior, not caused by the container repackaging. Adding any Proxmox VE/PBS remote with an active Basic+ subscription clears it.
- **DNS / Time / Network panels show transient state.** Edits made through these panels go to `/etc/resolv.conf`, `/etc/localtime`, `/etc/network/interfaces` — files that Docker bind-mounts or that we don't honor. Configure DNS/timezone via Docker (host `/etc/resolv.conf`, `TZ` env var) and don't edit the panels.
- **Self-managed log rotation.** PDM rotates its own `access.log`/`auth.log`/task archive every minute via an internal logrotate task. No host-side `logrotate` is needed.

## License & Credits

- **Packaging code in this repository** (Dockerfile, `rootfs/`, scripts, Makefile, compose.yaml): MIT License — see [`LICENSE`](LICENSE).
- **The container image** produced by `docker build` bundles software with its own licenses — **Proxmox Datacenter Manager** is AGPL-3.0-or-later, **s6-overlay** is ISC, and the Debian Trixie base spans GPL/LGPL/BSD/MIT/Apache. See [`NOTICES.md`](NOTICES.md) for the full inventory with upstream source URLs.
- Every package's `/usr/share/doc/<pkg>/copyright` file is preserved verbatim in the image so the DEP-5 license disclosure travels with the artifact.
- **AGPL §13 (network use)**: if you serve PDM over a network from this image, users have a right to receive the Corresponding Source. Proxmox publishes it at <https://git.proxmox.com/?p=proxmox-datacenter-manager.git;a=summary> — that's the source pointer to share downstream.
- **Trademark**: "Proxmox" is a trademark of Proxmox Server Solutions GmbH. Used here only to identify the software being packaged (nominative use); no endorsement is asserted or implied.
- Credits / prior art:
  - <https://github.com/pbs-plus/proxmox-backup-docker> (s6-overlay supervision pattern)
  - <https://github.com/willmortimer/proxmox-datacenter-manager-docker> (apt-based prior art)

## Disclaimer

This is an **unofficial**, community-maintained packaging effort. It is not affiliated with, sponsored by, or supported by Proxmox Server Solutions GmbH. For production deployments, follow the official guidance and install Proxmox Datacenter Manager directly on a real Debian host using the Proxmox bare-metal ISO installer.
