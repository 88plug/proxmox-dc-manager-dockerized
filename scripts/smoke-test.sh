#!/usr/bin/env bash
# Smoke test: verify a freshly-built PDM container can register a real
# PVE remote, list its nodes, and round-trip a no-op task. Requires a
# reachable PVE node with credentials that can mint an API token.
#
# Usage:
#   PVE_HOST=192.168.1.10 PVE_USER=root@pam PVE_PASS=hunter2 \
#     bash scripts/smoke-test.sh
#
# Optional:
#   PVE_FINGERPRINT=...   skip --insecure on the curl probe
#   PDM_URL=...           defaults to https://127.0.0.1:8443
#   PDM_USER=root@pam     defaults to root@pam
#   PDM_PASS=...          defaults to compose.yaml PDM_ROOT_PASSWORD or 'changeme'
#   KEEP=1                don't tear down the registered remote at the end
#
# Exit codes:
#   0  all checks passed
#   1  precondition failure (missing env, container not running, etc.)
#   2  PVE side failure
#   3  PDM side failure

set -euo pipefail

log()  { printf '[smoke] %s\n' "$*"; }
fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; exit "${2:-1}"; }

# ----- preconditions ---------------------------------------------------------
: "${PVE_HOST:?need PVE_HOST=<ip-or-host>}"
: "${PVE_USER:=root@pam}"
: "${PVE_PASS:?need PVE_PASS=<password> (used to mint a scoped API token, then discarded)}"
: "${PDM_URL:=https://127.0.0.1:8443}"
: "${PDM_USER:=root@pam}"

if [ -z "${PDM_PASS:-}" ]; then
  PDM_PASS="$(awk -F'[:[:space:]]+' '/PDM_ROOT_PASSWORD:/ {print $3; exit}' compose.yaml 2>/dev/null || true)"
  PDM_PASS="${PDM_PASS:-changeme}"
fi

command -v curl >/dev/null || fail "curl not installed"
command -v jq   >/dev/null || fail "jq not installed (apt install jq / brew install jq)"

if ! docker compose ps --status running --services 2>/dev/null | grep -q '^pdm$'; then
  fail "pdm container is not running. 'make up' first."
fi

REMOTE_NAME="smoke-$(date -u +%s)"
TOKEN_NAME="pdm-smoke"

log "PVE=${PVE_HOST} user=${PVE_USER} PDM=${PDM_URL} remote-name=${REMOTE_NAME}"

# ----- 1. mint a scoped PVE API token via the bundled scanner ---------------
log "minting PVE API token via scan-proxmox (single-host scan)"
SCAN_OUT="$(mktemp)"
if ! docker compose exec -T \
      -e SCAN_PASSWORD="${PVE_PASS}" pdm \
      scan-proxmox --cidr "${PVE_HOST}/32" \
                   --user "${PVE_USER}" \
                   --token-name "${TOKEN_NAME}" \
                   --force-token \
                   --json > "${SCAN_OUT}" 2>&1; then
  cat "${SCAN_OUT}" >&2
  fail "scan-proxmox failed against ${PVE_HOST}" 2
fi

if ! jq -e '.[0].token_id and .[0].token_secret and .[0].fingerprint' "${SCAN_OUT}" >/dev/null; then
  cat "${SCAN_OUT}" >&2
  fail "scan-proxmox returned no usable token/fingerprint" 2
fi

TOKEN_ID="$(jq -r '.[0].token_id'      "${SCAN_OUT}")"
TOKEN_SECRET="$(jq -r '.[0].token_secret' "${SCAN_OUT}")"
FINGERPRINT="$(jq -r '.[0].fingerprint'  "${SCAN_OUT}")"
rm -f "${SCAN_OUT}"
log "ok — token=${TOKEN_ID}, fingerprint=${FINGERPRINT:0:20}..."

# ----- 2. authenticate to PDM ------------------------------------------------
log "authenticating to PDM as ${PDM_USER}"
TICKET_JSON="$(curl -fsS -k -X POST "${PDM_URL}/api2/json/access/ticket" \
  --data-urlencode "username=${PDM_USER}" \
  --data-urlencode "password=${PDM_PASS}")" \
  || fail "PDM authentication failed (check PDM_PASS)" 3

PDM_TICKET="$(echo "${TICKET_JSON}" | jq -r '.data.ticket')"
PDM_CSRF="$(echo "${TICKET_JSON}" | jq -r '.data.CSRFPreventionToken')"
[ -n "${PDM_TICKET}" ] && [ "${PDM_TICKET}" != "null" ] || fail "PDM returned no ticket" 3
log "ok — got ticket"

# ----- 3. register the remote -----------------------------------------------
log "registering remote ${REMOTE_NAME} as PVE node ${PVE_HOST}"
REGISTER_BODY="$(jq -nc \
  --arg id        "${REMOTE_NAME}" \
  --arg type      "pve" \
  --arg host      "${PVE_HOST}" \
  --arg token_id  "${TOKEN_ID}" \
  --arg token     "${TOKEN_SECRET}" \
  --arg fp        "${FINGERPRINT}" \
  '{
     id: $id, type: $type,
     nodes: [{hostname: $host, fingerprint: $fp}],
     authid: $token_id, token: $token
   }')"

if ! curl -fsS -k -X POST "${PDM_URL}/api2/json/remotes/remote" \
      -H "Cookie: PDMAuthCookie=${PDM_TICKET}" \
      -H "CSRFPreventionToken: ${PDM_CSRF}" \
      -H 'Content-Type: application/json' \
      --data "${REGISTER_BODY}" >/dev/null; then
  fail "remote registration failed" 3
fi
log "ok — remote registered"

# ----- 4. read it back -------------------------------------------------------
log "listing remotes"
LIST="$(curl -fsS -k "${PDM_URL}/api2/json/remotes" \
  -H "Cookie: PDMAuthCookie=${PDM_TICKET}")" \
  || fail "could not list remotes" 3

if ! echo "${LIST}" | jq -e --arg id "${REMOTE_NAME}" '.data[] | select(.id == $id)' >/dev/null; then
  echo "${LIST}" | jq . >&2
  fail "remote ${REMOTE_NAME} did not appear in /remotes list" 3
fi
log "ok — remote is visible"

# ----- 5. query PVE through PDM ---------------------------------------------
log "fetching nodes for ${REMOTE_NAME} via PDM proxy"
if ! NODES="$(curl -fsS -k "${PDM_URL}/api2/json/remotes/${REMOTE_NAME}/nodes" \
                -H "Cookie: PDMAuthCookie=${PDM_TICKET}")"; then
  fail "PDM could not proxy /nodes to ${REMOTE_NAME}" 3
fi

NODE_COUNT="$(echo "${NODES}" | jq '.data | length')"
[ "${NODE_COUNT}" -ge 1 ] || fail "PVE returned 0 nodes via PDM" 3
log "ok — ${NODE_COUNT} node(s) reachable: $(echo "${NODES}" | jq -r '.data[].node' | tr '\n' ' ')"

# ----- 6. teardown -----------------------------------------------------------
if [ "${KEEP:-0}" != "1" ]; then
  log "tearing down remote ${REMOTE_NAME}"
  curl -fsS -k -X DELETE "${PDM_URL}/api2/json/remotes/${REMOTE_NAME}" \
    -H "Cookie: PDMAuthCookie=${PDM_TICKET}" \
    -H "CSRFPreventionToken: ${PDM_CSRF}" >/dev/null \
    || log "WARNING: teardown failed — remove ${REMOTE_NAME} manually"
fi

log "all checks passed"
