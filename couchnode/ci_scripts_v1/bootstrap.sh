#!/usr/bin/env bash
#
# bootstrap.sh - the ONLY file a consumer pipeline curls by name.
#
# Responsibilities:
#   1. Pin the CI-core ref (tag/sha) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.mjs, jenkins.mjs, tasks.sh, tasks.ps1,
#      ci-config.yaml, package.json, package-lock.json) at that ref.
#   3. Verify what was fetched before anything runs.
#   4. Materialize node_modules. engine.mjs has one pinned runtime dependency, the
#      `yaml` npm package, so `npm ci` must run here before `node engine.mjs` works.
#
# Consumer usage:
#   curl -fsSL <pinned-ref>/couchnode/bootstrap.sh -o bootstrap.sh
#   ./bootstrap.sh
#   ./tasks.sh <stage> ...
#
# NOTE: auth is not implemented yet, so this fetches over plain HTTPS from a pinned ref.
# The checksum table below MUST be regenerated (`shasum -a 256 <file>`) whenever any
# manifest file changes; see the sibling table in bootstrap.ps1, which must stay in sync
# with this one.

set -euo pipefail

# --- configuration -----------------------------------------------------------

# Pinned ref of couchbase-sdk-ci that this bootstrap fetches. A CI fix ships by
# moving this tag; SDK repos never change.
CBCI_REF="${CBCI_REF:-master}"

# Base raw URL for the couchnode/ tree at the pinned ref.
# TODO: point at the real private repo raw endpoint once the repo move lands
CBCI_BASE_URL="${CBCI_BASE_URL:-https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/${CBCI_REF}/couchnode/ci_scripts_v1}"

# Where the manifest is written. Consumers run ./tasks.sh from here.
CBCI_DEST="${CBCI_DEST:-.}"

# The fixed manifest. bootstrap.sh itself is excluded, since it is already present.
# Growth happens *inside* these files, not as new files (../CONVENTIONS.md).
CBCI_MANIFEST=(
    "engine.mjs"
    "jenkins.mjs"
    "tasks.sh"
    "tasks.ps1"
    "ci-config.yaml"
    "package.json"
    "package-lock.json"
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
        "engine.mjs")         echo "57467cec3bb3a14a81f5cf8af53e437e2553a30e239f964cbc012545384c58de" ;;
        "jenkins.mjs")        echo "d414f0c1e4e0946d865257f153ddf4c3c3d1712bec50049b3321b4e60db3ddfe" ;;
        "tasks.sh")           echo "e72d2bef14d555ee7f2b505f6ad87445a839fb2419f56a5c22d642078b9142b7" ;;
        "tasks.ps1")          echo "754e135fe767134a36655c88eb4d3273d129d009e4e6dd6f0aa162c8b8bf1d70" ;;
        "ci-config.yaml")     echo "9c64bcac9286e6db3d3ad082d149b50d5c586457ba836e9cbdd7836895a1b920" ;;
        "package.json")       echo "723bd7b31c52ee5afc5dcca12b0a4f8c9209ff2d8801ead2355d846eb936206d" ;;
        "package-lock.json")  echo "8930ae2b212bdabb240935d44acfd1b5c869d09b8311e76ab45e035f10a64372" ;;
        *)                    echo "" ;;
    esac
}

# Fetch ${url} -> ${out}, preferring curl but falling back to wget: some linux build
# agents ship a curl whose libcurl cannot resolve a shared dep (`libnghttp2.so.14`), which
# makes curl exit 127 BEFORE any network I/O. wget links differently and usually still
# works, so one broken fetcher does not doom the node.
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

# npm ci, not npm install: reproducible from package-lock.json, matching exactly
# what the checksum above verified. Skippable via CBCI_SKIP_NPM_INSTALL for a
# consumer that already vendors node_modules another way.
install_dependencies() {
    if [[ "${CBCI_SKIP_NPM_INSTALL:-false}" == "true" ]]; then
        log "CBCI_SKIP_NPM_INSTALL=true, skipping npm ci"
        return 0
    fi
    command -v npm >/dev/null 2>&1 || die "npm not found on PATH (required to install engine.mjs's 'yaml' dependency)"
    log "installing dependencies (npm ci)"
    (cd "${CBCI_DEST}" && npm ci --omit=dev)
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
    install_dependencies
    log "manifest ready: ${CBCI_MANIFEST[*]}"
}

main "$@"
