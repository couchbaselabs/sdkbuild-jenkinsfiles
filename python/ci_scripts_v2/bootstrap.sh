#!/usr/bin/env bash
#
# bootstrap.sh - the ONLY file a consumer pipeline curls by name.
#
# Responsibilities:
#   1. Pin the CI-core ref (tag/sha) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.py, the vendor adapters, tasks.sh, tasks.ps1,
#      auditwheel_patch.py and the ci-config files) at that ref.
#   3. Verify what was fetched before anything runs.
#
# Consumer usage:
#   curl -fsSL <base-url>/bootstrap.sh -o bootstrap.sh
#   ./bootstrap.sh
#   ./tasks.sh <stage> ...
# where <base-url> is CBCI_BASE_URL below, i.e. the ci_scripts_v2 tree at the pinned ref.
#
# The source repo is PUBLIC (couchbaselabs/sdkbuild-jenkinsfiles), so the fetch needs no
# credentials; integrity comes from the pinned ref plus the sha256 verification below, not
# from transport auth. A move to a private repo would need an auth path added here first.

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
# Growth happens *inside* these files, not as new files, with ONE bounded exception: the
# per-project `ci-config-<project>.yaml`. That is data, of which the manifest already
# carries one (`ci-config.yaml`, which stays PYCBC's), and it is capped at one file per SDK
# project rather than being open-ended the way an `images/` dir would be. Keeping them
# separate also means PYCBC's config never changes SHAPE to accommodate another project, so
# an engine/config version skew cannot break it. A project with no file of its own falls
# back to ci-config.yaml (engine._default_config_path).
#
# The vendor ADAPTERS (jenkins.py, gha.py) are the same bounded kind of exception: one file
# per CI system, not one per project, and every consumer fetches all of them. Fetching an
# adapter you do not run costs a few KB and keeps the manifest FIXED, which is the property
# that lets a consumer curl one file by name and never edit a file list again. Splitting the
# manifest per vendor would put that list back in every workflow.
CBCI_MANIFEST=(
    "engine.py"
    "jenkins.py"
    "gha.py"
    "tasks.sh"
    "tasks.ps1"
    "auditwheel_patch.py"
    "ci-config.yaml"
    "ci-config-pycbac.yaml"
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
        "engine.py")           echo "139fb3968af7d81d41df5207965729ef978e21f92560b9efbaace80186f51af1" ;;
        "jenkins.py")          echo "edbd13b9171dcf583679e5fd661f4085f0a3ee0df0a8ff51600ddf52369a55f4" ;;
        "gha.py")              echo "4bcf36dfa40c548c6ed4ada13ce25c2a29c2886051f6ec7990651c1c4119d2e5" ;;
        "tasks.sh")            echo "c33e07633658bf130ea387a481c8e0f16bdcc46b9a1fd88c22dc33769a911f60" ;;
        "tasks.ps1")           echo "0ac0835cc9a87ff3cc39e546e7c87eb68e0555d4a3d97cadc1fc0d6cdde26e15" ;;
        "auditwheel_patch.py") echo "402f0b8270a7f8acd4790d12cc96257190c1f8209eff2d7d3f450d661d58bef5" ;;
        "ci-config.yaml")      echo "2f075cca668628cea899c98e5abe72cfa0cd39d62fc4ebd76a936256416e457c" ;;
        "ci-config-pycbac.yaml") echo "3e1fb4b0e70283d273b52d1897c40c86eba3367b27c3b6d086e7259f2f339da3" ;;
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

        # An entry with no pinned hash is a HOLE, not a pass: the file was fetched over the
        # network and would then run unverified, which is the one thing this script exists to
        # prevent. Previously an empty expected hash silently skipped the check, so adding a
        # manifest entry and forgetting to run `update_manifest.sh --update` produced a
        # bootstrap that verified everything except the new file.
        local expected; expected="$(get_expected_hash "${name}")"
        if [[ -z "${expected}" ]]; then
            log "ERROR: no pinned sha256 for ${name}; run update_manifest.sh --update"
            missing=1
            continue
        fi
        local actual; actual="$(get_sha256 "${file}")"
        if [[ "${actual}" != "${expected}" ]]; then
            log "ERROR: checksum verification failed for ${name}"
            log "  expected: ${expected}"
            log "  actual:   ${actual}"
            missing=1
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
