#!/usr/bin/env bash
#
# bootstrap.sh - the ONLY file a consumer pipeline curls by name.
#
# Responsibilities:
#   1. Pin the CI-core ref (tag/sha) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.py, jenkins.py, tasks.sh, tasks.ps1,
#      auditwheel_patch.py, ci-config.yaml) at that ref.
#   3. Verify what was fetched before anything runs.
#
# Consumer usage:
#   curl -fsSL <pinned-ref>/python/bootstrap.sh -o bootstrap.sh
#   ./bootstrap.sh
#   ./tasks.sh <stage> ...
#
# NOTE: auth is not implemented yet, so this fetches over plain HTTPS from a pinned ref.
# Do not ship to the private-repo flow until it is.

set -euo pipefail

# --- configuration -----------------------------------------------------------

# Pinned ref of couchbase-sdk-ci that this bootstrap fetches. A CI fix ships by
# moving this tag; SDK repos never change.
CBCI_REF="${CBCI_REF:-master}"

# Base raw URL for the python/ tree at the pinned ref.
# TODO: point at the real private repo raw endpoint once the repo move lands.
CBCI_BASE_URL="${CBCI_BASE_URL:-https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/${CBCI_REF}/python/ci_scripts_v2}"

# Where the manifest is written. Consumers run ./tasks.sh from here.
CBCI_DEST="${CBCI_DEST:-.}"

# The fixed manifest. bootstrap.sh itself is excluded, since it is already present.
# Growth happens *inside* these files, not as new files.
CBCI_MANIFEST=(
    "engine.py"
    "jenkins.py"
    "tasks.sh"
    "tasks.ps1"
    "auditwheel_patch.py"
    "ci-config.yaml"
)

# --- helpers -----------------------------------------------------------------

log() { echo "[bootstrap] $*"; }
die() {
    log "ERROR: $*" >&2
    exit 1
}

get_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file}" | awk '{print $NF}'
    else
        die "No sha256 verification tool found (sha256sum, shasum, or openssl)"
    fi
}

get_expected_hash() {
    local name="$1"
    case "${name}" in
        "engine.py")           echo "35c00330788ee1997909848c33baf492e917517005f408aec68f6afcc5a9f64c" ;;
        "jenkins.py")          echo "3a4f4be98f8c5e31e93551e8766267a24947fd8795551b9abf7faff6b72ec250" ;;
        "tasks.sh")            echo "9ebcfcf85c4eb98170a7c63a4bbe6712dedcd7fe75ce152a0d9f17205c343258" ;;
        "tasks.ps1")           echo "6dfd9c6f0a8273870cfa8c6cb8fdc5a19d9685e725c4423238ece3ebbffa4a3c" ;;
        "auditwheel_patch.py") echo "1e38cfe3a7335fe3c5d5e08a0f53718f38d95b8f7185c1315fec5cddc5ad4bfa" ;;
        "ci-config.yaml")      echo "6b3c035f8cc80ffb75dd6006134531e6a31bc6bdb3bb3d29e605ca777512cec9" ;;
        *)                     echo "" ;;
    esac
}

# Fetch ${url} -> ${out}, preferring curl but falling back to wget. Some linux build agents
# intermittently ship a curl whose libcurl can't resolve a shared dep (e.g.
# `libnghttp2.so.14: cannot open shared object file`), which makes curl exit 127 BEFORE any
# network I/O. wget links differently and usually still works, so a broken curl doesn't doom
# the node. Both use fail-on-HTTP-error (curl -f, wget's default) so a 404 isn't written as a
# "success", and verify_manifest checksums every file afterward as a final backstop.
http_get() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1 && curl -fsSL "${url}" -o "${out}"; then
        return 0
    fi
    log "curl unavailable or failed for ${url}; falling back to wget"
    if command -v wget >/dev/null 2>&1 && wget -qO "${out}" "${url}"; then
        return 0
    fi
    die "failed to fetch ${url} (curl and wget both unavailable or failing)"
}

fetch_one() {
    local name="$1"
    local url="${CBCI_BASE_URL}/${name}"
    local out="${CBCI_DEST}/${name}"
    log "fetching ${name} <- ${url}"
    http_get "${url}" "${out}"
}

verify_manifest() {
    local missing=0
    for name in "${CBCI_MANIFEST[@]}"; do
        local file="${CBCI_DEST}/${name}"
        if [[ ! -s "${file}" ]]; then
            log "ERROR: manifest file missing or empty: ${name}"
            missing=1
            continue
        fi

        local expected; expected="$(get_expected_hash "${name}")"
        if [[ -n "${expected}" ]]; then
            local actual; actual="$(get_sha256 "${file}")"
            if [[ "${actual}" != "${expected}" ]]; then
                log "ERROR: checksum verification failed for ${name}"
                log "  expected: ${expected}"
                log "  actual:   ${actual}"
                missing=1
            fi
        fi
    done
    [[ "${missing}" -eq 0 ]] || exit 1
}

# --- main --------------------------------------------------------------------

main() {
    log "ref=${CBCI_REF} dest=${CBCI_DEST}"
    mkdir -p "${CBCI_DEST}"
    for name in "${CBCI_MANIFEST[@]}"; do
        fetch_one "${name}"
    done
    chmod +x "${CBCI_DEST}/tasks.sh" || true
    verify_manifest
    log "manifest ready: ${CBCI_MANIFEST[*]}"
}

main "$@"
