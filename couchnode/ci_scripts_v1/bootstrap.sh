#!/usr/bin/env bash
#
# bootstrap.sh — the ONLY file a consumer pipeline curls by name.
#
# Responsibilities:
#   1. Pin the CI-core ref (tag/sha) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.js, jenkins.js, tasks.sh, tasks.ps1,
#      ci-config.yaml, package.json, package-lock.json) at that ref.
#   3. Verify what was fetched before anything runs.
#   4. Materialize node_modules (engine.js has one pinned runtime dependency,
#      the `yaml` npm package — unlike Python's engine.py, this core is not
#      stdlib-only, so `npm ci` here is required before `node engine.js` works).
#
# Consumer usage:
#   curl -fsSL <pinned-ref>/couchnode/bootstrap.sh -o bootstrap.sh
#   ./bootstrap.sh
#   ./tasks.sh <stage> ...
#
# NOTE (Phase 1 scaffold): mirrors couchbase-sdk-ci/python/bootstrap.sh's own stated
# caveat — this fetches over plain HTTPS from a pinned ref; auth is deferred. The
# checksum table below MUST be regenerated (`shasum -a 256 <file>`) whenever any
# manifest file changes — see the sibling table in bootstrap.ps1, which must stay
# in sync with this one.

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

# The fixed manifest. bootstrap.sh itself is excluded — it is already present.
# Growth happens *inside* these files, not as new files (../CONVENTIONS.md).
CBCI_MANIFEST=(
    "engine.js"
    "jenkins.js"
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
        "engine.js")          echo "0a9ef2b11c25fe28e4ee197bd1ae169f83c95d56792c9266fa31be9dc74886b1" ;;
        "jenkins.js")         echo "7dacde16755fda69f2fd1f3bb068fe27c817eb13e07d064bf833e47cbc62f866" ;;
        "tasks.sh")           echo "218cff5dc09b256b5c6bd85ff11a3e30e4023c73d9fc59f78314bd0dfcfaac4e" ;;
        "tasks.ps1")          echo "8dc0f50e25efbb71656436432d42ea33fd4c2f7a197060e68ba5df562590730c" ;;
        "ci-config.yaml")     echo "41a5d7fe9a47049296b626e358edc118ea880d4fa4ad2877c130a6f554e60557" ;;
        "package.json")       echo "490e8f0a45c7c24b8f80f303202673c182154e3fa89884b32b24408825e727c4" ;;
        "package-lock.json")  echo "8930ae2b212bdabb240935d44acfd1b5c869d09b8311e76ab45e035f10a64372" ;;
        *)                    echo "" ;;
    esac
}

# Fetch ${url} -> ${out}, preferring curl but falling back to wget. Mirrors
# couchbase-sdk-ci/python/bootstrap.sh's http_get (same libnghttp2-on-some-agents
# rationale) — kept identical rather than re-derived.
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

# npm ci (not npm install) — reproducible from package-lock.json, matching exactly
# what the checksum above verified. Skippable via CBCI_SKIP_NPM_INSTALL for a
# consumer that already vendors node_modules another way.
install_dependencies() {
    if [[ "${CBCI_SKIP_NPM_INSTALL:-false}" == "true" ]]; then
        log "CBCI_SKIP_NPM_INSTALL=true — skipping npm ci"
        return 0
    fi
    command -v npm >/dev/null 2>&1 || die "npm not found on PATH (required to install engine.js's 'yaml' dependency)"
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
