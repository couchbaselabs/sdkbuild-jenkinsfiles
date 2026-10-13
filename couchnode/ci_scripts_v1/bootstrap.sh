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
        "engine.mjs")         echo "6aea79154098525961b2324edbdcd328c5e7b375a2ce0792d946069b21c58862" ;;
        "jenkins.mjs")        echo "8fc470fb5aa081cca9455d316ca75fd0fd68fa2a8382dda33b8af01d13666bba" ;;
        "tasks.sh")           echo "a49a5dd55c439278207af5e43567efe8ea63b2935c5af944e6a0c238d66b55f5" ;;
        "tasks.ps1")          echo "d51ed2b43bc718cd2de0ab3df18af28581f287f4e204a4ac2d697cd3a973c3db" ;;
        "ci-config.yaml")     echo "381b75218f49823924df65a147c99b212f76fad5e94ecc17107e0b0056321f95" ;;
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
