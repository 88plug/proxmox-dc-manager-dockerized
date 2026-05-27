# proxmox-dc-manager-dockerized

A community-maintained Docker repackaging of the official **Proxmox Datacenter Manager (PDM)** ISO. **This project is not affiliated with or endorsed by Proxmox Server Solutions GmbH.**

## Why this approach

The build extracts the squashfs root and apt repository from the official PDM ISO and uses them as the sole sources for image construction. That makes the image hermetic and version-pinned to a specific ISO release: no calls to `download.proxmox.com` at build time, no risk of pulling a mismatched `proxmox-datacenter-manager` against a stale Debian Trixie snapshot, and a single source of truth for what's installed. When Proxmox publishes a new ISO, you bump one URL and one checksum.

## At a glance

- Base: `pdm-base.squashfs` extracted from the PDM ISO (Debian Trixie 13.2)
- Supervisor: s6-overlay v3 (no systemd, no `--privileged` required)
- Web UI: HTTPS on port `8443`
- Volumes: `pdm-config` (`/etc/proxmox-datacenter-manager`), `pdm-data` (`/var/lib/proxmox-datacenter-manager`)
- Tmpfs: `/run/proxmox-datacenter-manager`
- Architecture: `linux/amd64` only (PDM has no upstream arm64 build)
- ISO: `proxmox-datacenter-manager_1.0-2.iso` (PDM 1.0.2, ISO Refresh 2025-12-10), 1.37 GB
  - sha256 `b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1`

## Quickstart

```sh
git clone <repo>
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
make up            # start container in background
make down          # stop & remove container (volumes kept)
make restart       # restart the pdm service
make logs          # tail container logs
make shell         # bash inside the running container
make init-shell    # bash inside a freshly-built image (debug)
make pdm-version   # print PDM version from inside the container
make set-password  # reset root password using compose.yaml's PDM_ROOT_PASSWORD
make lint          # validate compose syntax
make clean         # remove image (keep volumes)
make reset         # DANGER: delete all volumes (factory reset)
```

## Upgrading

When Proxmox publishes a new ISO:

1. Update `PDM_ISO_URL` and `PDM_ISO_SHA256` (the `ARG` lines in the `Dockerfile`'s `extractor` stage).
2. `make build && docker compose up -d`

Named volumes are preserved across rebuilds, so configuration and remotes carry over. The PDM postinst handles intra-version migrations automatically (e.g. the 1.0.0 -> 1.0.1 `ldap_passwords.json` rewrite). Review the upstream changelog (<https://pdm.proxmox.com/docs/>) before upgrading.

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
- **No notifications yet.** PDM 1.0 does not implement the Notifications subsystem (no SMTP/Gotify/webhook endpoint API exists upstream — see <https://pdm.proxmox.com/docs/roadmap.html>). When upstream lands the feature, the SMTP target dials the relay directly and requires no local MTA — this image will work as-is.
- **Subscription warning popup on login.** PDM aggregates remote subscriptions; with zero remotes (or all-community remotes), the UI shows a one-time "no valid subscription" warning. Expected upstream behavior, not caused by the container repackaging. Adding any Proxmox VE/PBS remote with an active Basic+ subscription clears it.
- **DNS / Time / Network panels show transient state.** Edits made through these panels go to `/etc/resolv.conf`, `/etc/localtime`, `/etc/network/interfaces` — files that Docker bind-mounts or that we don't honor. Configure DNS/timezone via Docker (host `/etc/resolv.conf`, `TZ` env var) and don't edit the panels.
- **Self-managed log rotation.** PDM rotates its own `access.log`/`auth.log`/task archive every minute via an internal logrotate task. No host-side `logrotate` is needed.

## License & Credits

- Bundled software: **Proxmox Datacenter Manager** is distributed under AGPL-3.0; **s6-overlay** is ISC-licensed. Both retain their upstream licenses.
- Dockerfile, scripts, and packaging in this repository are released under the **MIT License**.
- Credits / prior art:
  - <https://github.com/pbs-plus/proxmox-backup-docker> (s6-overlay supervision pattern)
  - <https://github.com/willmortimer/proxmox-datacenter-manager-docker> (apt-based prior art)

## Disclaimer

This is an **unofficial**, community-maintained packaging effort. It is not affiliated with, sponsored by, or supported by Proxmox Server Solutions GmbH. For production deployments, follow the official guidance and install Proxmox Datacenter Manager directly on a real Debian host using the Proxmox bare-metal ISO installer.
