#!/usr/bin/env bash
# init-pdm: bootstrap Proxmox Datacenter Manager on container start.
# Runs as a s6-overlay v3 oneshot before the PDM longrun services.
set -euo pipefail

log()  { echo "[init-pdm] $*"; }
warn() { echo "[init-pdm] WARNING: $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  warn "container is running as uid=$(id -u); PDM requires root for the privileged API and chown of volume mounts."
  warn "Remove any 'user:' line from compose.yaml and recreate the container."
  exit 1
fi

CONF_DIR=/etc/proxmox-datacenter-manager
DATA_DIR=/var/lib/proxmox-datacenter-manager
INIT_FLAG="${DATA_DIR}/.pdm-container-initialized"

log "starting PDM bootstrap"

# --- 1. hostname + /etc/hosts -------------------------------------------------
FQDN="${PDM_FQDN:-pdm.local}"
case "${FQDN}" in
  ''|.|*[!A-Za-z0-9.-]*)
    warn "PDM_FQDN='${FQDN}' is invalid; falling back to 'pdm.local'"
    FQDN=pdm.local ;;
esac
SHORT="${FQDN%%.*}"
[ -z "${SHORT}" ] && SHORT="pdm"
echo "${SHORT}" > /etc/hostname
hostname "${SHORT}" 2>/dev/null || true  # utsname is read-only in unprivileged ctrs
cat > /etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
127.0.1.1 ${FQDN} ${SHORT}
::1 ip6-localhost ip6-loopback
EOF

# --- 2. timezone --------------------------------------------------------------
TZ_VAL="${TZ:-Etc/UTC}"
if [ -f "/usr/share/zoneinfo/${TZ_VAL}" ]; then
  if [ -L /etc/localtime ] && [ "$(readlink /etc/localtime)" != "/usr/share/zoneinfo/${TZ_VAL}" ]; then
    log "overriding /etc/localtime: $(readlink /etc/localtime) -> /usr/share/zoneinfo/${TZ_VAL}"
  fi
  ln -sf "/usr/share/zoneinfo/${TZ_VAL}" /etc/localtime
  echo "${TZ_VAL}" > /etc/timezone
else
  warn "TZ='${TZ_VAL}' not found under /usr/share/zoneinfo; leaving /etc/localtime alone"
fi

# --- 3. machine-id ------------------------------------------------------------
# Dockerfile blanks /etc/machine-id at build time so each container is unique.
if [ ! -s /etc/machine-id ]; then
  if command -v systemd-machine-id-setup >/dev/null 2>&1; then
    systemd-machine-id-setup >/dev/null
  else
    tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id
  fi
  chmod 0444 /etc/machine-id
fi

# --- 4. volume permission fixup ------------------------------------------------
# Docker mounts named volumes onto the image dir with default root:root 0755,
# clobbering whatever ownership the .deb postinst set. priv-api's `setup`
# subcommand checks ownership of /etc/proxmox-datacenter-manager strictly and
# refuses to start if it isn't www-data:www-data 01770 — so we replicate the
# bare-metal installer's chown/chmod (Install.pm:1601-1603) before the longrun
# services start. setup will populate auth/, access/, and the TLS material.
RUN_DIR=/run/proxmox-datacenter-manager
LOG_DIR=/var/log/proxmox-datacenter-manager
mkdir -p "${CONF_DIR}" "${DATA_DIR}" "${RUN_DIR}" "${LOG_DIR}/api" "${LOG_DIR}/tasks"
# Docker mounts named volumes / tmpfs as root:root by default, clobbering
# whatever ownership the .deb postinst set. priv-api `setup` enforces strict
# perms on all four paths and refuses to start otherwise.
# Mode/owner pattern verified by reading priv-api error messages:
#   /etc/proxmox-datacenter-manager     → www-data:www-data  01770
#   /var/lib/proxmox-datacenter-manager → www-data:www-data  0755
#   /var/log/proxmox-datacenter-manager → root:www-data      0755 (priv-api
#     creates files here as root; api daemon reads them as www-data; pre-
#     chown happens here because pdm-log-forwarder may pre-create api/*.log)
#   /run/proxmox-datacenter-manager     → root:www-data      01770
for op in 'chown www-data:www-data '"${CONF_DIR}"' '"${DATA_DIR}" \
          'chown www-data:www-data '"${LOG_DIR}/api"' '"${LOG_DIR}/tasks" \
          'chown root:www-data '"${RUN_DIR}"' '"${LOG_DIR}" \
          'chmod 01770 '"${CONF_DIR}"' '"${RUN_DIR}" \
          'chmod 0755 '"${DATA_DIR}"' '"${LOG_DIR}"' '"${LOG_DIR}/api"' '"${LOG_DIR}/tasks"; do
  if ! eval "${op}" 2>/dev/null; then
    warn "failed: ${op}"
    warn "Likely a host bind-mount with foreign ownership. Use a Docker named volume, or pre-chown the host path so UID 33 (www-data) and root can write it."
    exit 1
  fi
done

# --- 4.5 TLS cert / FQDN consistency check -----------------------------------
# If the existing self-signed cert's CN/SAN don't match PDM_FQDN, browsers will
# warn about a hostname mismatch. Auto-rotate ONLY for self-signed certs (subject
# == issuer) and ONLY when PDM_FORCE_REGEN_CERT=1 — never clobber an operator-
# supplied CA-signed cert silently.
CERT=/etc/proxmox-datacenter-manager/auth/api.pem
KEY=/etc/proxmox-datacenter-manager/auth/api.key
if [ -f "${CERT}" ] && [ -f "${KEY}" ]; then
  cert_subj="$(openssl x509 -in "${CERT}" -noout -subject -nameopt RFC2253 2>/dev/null || true)"
  cert_iss="$(openssl x509 -in "${CERT}" -noout -issuer  -nameopt RFC2253 2>/dev/null || true)"
  cert_cn="$(printf '%s' "${cert_subj#subject=}" | grep -oE 'CN=[^,]+' | head -n1 | cut -d= -f2- || true)"
  cert_san="$(openssl x509 -in "${CERT}" -noout -ext subjectAltName 2>/dev/null \
              | tr ',' '\n' | grep -oE 'DNS:[^[:space:]]+' | cut -d: -f2- || true)"
  is_self_signed=0
  [ -n "${cert_subj}" ] && [ "${cert_subj#subject=}" = "${cert_iss#issuer=}" ] && is_self_signed=1
  match=0
  for n in ${cert_san} "${cert_cn}"; do
    [ "${n}" = "${FQDN}" ] && match=1 && break
    [ "${n}" = "${SHORT}" ] && match=1 && break
  done
  if [ "${match}" = "0" ]; then
    if [ "${is_self_signed}" = "1" ]; then
      if [ "${PDM_FORCE_REGEN_CERT:-0}" = "1" ]; then
        warn "self-signed cert CN/SAN does not include '${FQDN}'; PDM_FORCE_REGEN_CERT=1 set, regenerating"
        rm -f "${CERT}" "${KEY}"
      else
        warn "self-signed TLS cert (CN='${cert_cn}') does not match PDM_FQDN='${FQDN}'"
        warn "Set PDM_FORCE_REGEN_CERT=1 in compose.yaml + restart, OR remove auth/api.{pem,key} manually."
      fi
    else
      log "TLS cert is CA-signed (subject != issuer); leaving alone despite FQDN mismatch (CN='${cert_cn}')"
    fi
  fi
fi

# --- 5. root password ---------------------------------------------------------
seed_pw_plain()  { echo "root:${PDM_ROOT_PASSWORD}"        | chpasswd; }
# --encrypted mirrors PVE/PDM Install.pm: accept an already-hashed value so
# operators don't have to expose plaintext in env/compose.
seed_pw_hashed() { echo "root:${PDM_ROOT_PASSWORD_HASHED}" | chpasswd --encrypted; }

if [ ! -f "${INIT_FLAG}" ] || [ "${PDM_ROOT_PASSWORD_FORCE:-0}" = "1" ]; then
  if [ -n "${PDM_ROOT_PASSWORD_HASHED:-}" ]; then
    seed_pw_hashed
    log "root password set from PDM_ROOT_PASSWORD_HASHED"
  elif [ -n "${PDM_ROOT_PASSWORD:-}" ]; then
    seed_pw_plain
    log "root password set from PDM_ROOT_PASSWORD"
  else
    shadow_hash="$(getent shadow root | cut -d: -f2 || true)"
    case "${shadow_hash}" in
      ''|'*'|'!'|'!*'|'!!')
        if [ "${PDM_ALLOW_NO_PASSWORD:-0}" != "1" ]; then
          warn "no PDM_ROOT_PASSWORD{,_HASHED} set and shadow has no usable hash; refusing to start. Set PDM_ALLOW_NO_PASSWORD=1 to override."
          exit 1
        fi
        warn "starting without a root password — web login will fail until one is set"
        ;;
      *)
        log "root password already set (persisted); leaving as-is"
        ;;
    esac
  fi
else
  log "already initialized; skip password seed (set PDM_ROOT_PASSWORD_FORCE=1 to override)"
fi

# --- 6. optional SSH authorized_keys -----------------------------------------
if [ -n "${PDM_ROOT_SSH_KEYS:-}" ]; then
  install -d -m 0700 -o root -g root /root/.ssh
  printf '%s\n' "${PDM_ROOT_SSH_KEYS}" > /root/.ssh/authorized_keys
  chmod 0600 /root/.ssh/authorized_keys
  chown root:root /root/.ssh/authorized_keys
  log "wrote /root/.ssh/authorized_keys from PDM_ROOT_SSH_KEYS"
fi

# --- 7. www-data sanity check -------------------------------------------------
if ! getent passwd www-data >/dev/null; then
  warn "www-data user is missing; priv-api setup will fail. Aborting."
  exit 1
fi

# --- 8. seed access/user.cfg (conditional) -----------------------------------
# Only seed if priv-api `setup` has already run on a previous boot (access/
# exists) AND user.cfg is missing. On first boot setup hasn't run yet, so we
# defer; the daemon tolerates a missing user.cfg (root@pam is implicit super-
# user) and we'll write it next boot. This avoids creating files priv-api
# would otherwise create with the right ownership itself.
if [ -d "${CONF_DIR}/access" ] && [ ! -f "${CONF_DIR}/access/user.cfg" ]; then
  mailto="${PDM_MAILTO:-root@${FQDN}}"
  printf 'user: root@pam\n\temail %s\n' "${mailto}" > "${CONF_DIR}/access/user.cfg"
  chown root:www-data "${CONF_DIR}/access/user.cfg"
  chmod 0640 "${CONF_DIR}/access/user.cfg"
  log "seeded access/user.cfg with mailto=${mailto}"
fi

touch "${INIT_FLAG}"

cat <<EOF
[init-pdm] ============================================================
[init-pdm]  Proxmox Datacenter Manager container is ready.
[init-pdm]  Web UI:  https://<host>:8443
[init-pdm]  Login:   root  /  realm: Linux PAM
[init-pdm]  TLS:     self-signed (generated by priv-api setup)
[init-pdm] ============================================================
EOF

exit 0
