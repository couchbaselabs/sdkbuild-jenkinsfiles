#!/usr/bin/env bash
#
# bootstrap.sh — the ONLY file a consumer pipeline curls by name.
#
# Responsibilities:
#   1. Pin the CI-core ref (tag/sha) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.py, tasks.sh, tasks.ps1,
#      auditwheel_patch.py, ci-config.yaml) at that ref.
#   3. Verify what was fetched before anything runs.
#
# Consumer usage:
#   curl -fsSL <pinned-ref>/python/bootstrap.sh -o bootstrap.sh
#   ./bootstrap.sh
#   ./tasks.sh <stage> ...
#
# NOTE (Phase 1 scaffold): auth + checksum verification are deferred (PLAN.md §9).
# For now this fetches over plain HTTPS from a pinned ref. Do not ship to the
# private-repo flow until verification below is implemented.

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

# The fixed manifest (N=4 executors + config). bootstrap.sh itself is excluded —
# it is already present. Growth happens *inside* these files, not as new files.
CBCI_MANIFEST=(
    "engine.py"
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
        "engine.py")           echo "7d828d5a37c4568149936b94203394607469d1cad1c0198abe30d37cbf23b4ac" ;;
        "tasks.sh")            echo "87b9b74590b1e4780dc4943bb26543bbdd3071ecd952184483bee920245fa063" ;;
        "tasks.ps1")           echo "3176932a4ae612693bb900e28a737bf3165ac43d6f702b419aabf4b5adfa32d4" ;;
        "auditwheel_patch.py") echo "546592e40cf94e0e861f7373c5b764ffb88f4d719b03d26561c24735407dcf02" ;;
        "ci-config.yaml")      echo "14a48e577b45837e7cb7bee9603435cba863977e7a452d280fdd06f4e45e8b85" ;;
        *)                     echo "" ;;
    esac
}

fetch_one() {
    local name="$1"
    local url="${CBCI_BASE_URL}/${name}"
    local out="${CBCI_DEST}/${name}"
    log "fetching ${name} <- ${url}"
    curl -fsSL "${url}" -o "${out}"
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
