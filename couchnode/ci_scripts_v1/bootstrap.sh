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
        "engine.mjs")         echo "4396ecc05dede2550dc1a84e44c88c26f467a96d43ee76da54e584637c91879c" ;;
        "jenkins.mjs")        echo "40f3b8558cf9ba5d6fd2068b37b8cc6752c4f67baff4c452156f0754c2305c62" ;;
        "tasks.sh")           echo "6fd651980c80d708ce8dd2aad939ba8a3eeca7d452452bfa94c9a13a04a70afb" ;;
        "tasks.ps1")          echo "51d7b7247a8ea0f0c046c277c6403cd4e2bb97ce50d529eb95d0a6038b9d9d4e" ;;
        "ci-config.yaml")     echo "966518a006a14679bf8f7f475f8d3930f1b19ae3ce62578bb9448f8b36333ab9" ;;
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
