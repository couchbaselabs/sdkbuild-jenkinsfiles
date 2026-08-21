#!/usr/bin/env bash
#
# tasks.sh - POSIX (Linux/macOS) task executors for the Couchbase Node.js SDK
# (couchnode).
#
# The vendor pipeline invokes:  ./tasks.sh <stage> [args...]
# Stages are the portable unit; orchestration/parallelism/archiving belong to the
# vendor. engine.mjs owns config -> plan; jenkins.mjs owns labels; tasks.sh owns
# "do the work for one unit". There is no `image` stage: couchnode builds NATIVELY
# on distro-labeled Jenkins agents. See jenkins.mjs's file header.
#
# Every stage below is keyed to the real couchnode scripts (scripts/prebuilds.js,
# scripts/buildPrebuild.js, package.json, test/jcbmock.js, test/harness.js).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ENGINE="${SCRIPT_DIR}/engine.mjs"
NODE_BIN="${CBCI_NODE:-node}"
NPM_BIN="${CBCI_NPM:-npm}"

# Project root = where the SDK checkout (couchnode) lives (consumer cwd by default).
PROJECT_ROOT="${CBCI_PROJECT_ROOT:-$(pwd -P)}"

log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [tasks] $*"; }
die() { echo "[tasks] ERROR: $*" >&2; exit 1; }

# --- shared helpers ----------------------------------------------------------

# Resolve CBCI_* project facts from engine.mjs and export them into this shell:
#   CBCI_PROJECT_PREFIX
load_project_env() {
    local out
    out="$("${NODE_BIN}" "${ENGINE}" project-env)" || die "failed to resolve project env"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${out}
}

_node_platform() { "${NODE_BIN}" -p 'process.platform'; }
_node_arch() { "${NODE_BIN}" -p 'process.arch'; }
_node_major() { "${NODE_BIN}" -p 'process.versions.node.split(".")[0]'; }
_pkg_version() { "${NODE_BIN}" -p "require('${PROJECT_ROOT}/package.json').version"; }

# Size of a file in bytes. if/else rather than `stat -f%z || stat -c%s`: a failing BSD stat
# would fall through to the GNU form, which cannot work on the same host either, leaving
# the caller with an empty string that silently satisfies a numeric comparison.
_file_size() {
    local f="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        stat -f%z "${f}"
    else
        stat -c%s "${f}"
    fi
}

# Section headers of an ELF on stdout, or rc 2 with readelf's own error text on stderr when
# the file cannot be read at all. Callers decide what a section's ABSENCE means; this only
# separates "here is the truth" from "the truth is unavailable".
#
# Reading the sections ONCE and testing the captured text is what makes the strip
# assertions in task__prebuild_repair trustworthy. The obvious inline form,
#     ! readelf -S "${f}" 2>/dev/null | grep -q '\.debug_info'
# reports a broken tool as a clean strip, twice over: readelf's own error is thrown away by
# 2>/dev/null, and under `set -o pipefail` a `grep -q` that exits the moment it matches can
# SIGPIPE readelf into rc 141, so a SUCCESSFUL match fails the pipeline and the leading `!`
# converts that failure into a pass. Either way a binary still carrying full debug info
# ships as the release artifact.
#
# readelf, not objdump: the same binutils package supplies it and the objcopy the split
# below already depends on, so this adds no new tool requirement.
_elf_sections() {
    local elf="$1" out
    out="$(readelf -S "${elf}" 2>&1)" || {
        printf '%s\n' "${out}" >&2
        return 2
    }
    printf '%s\n' "${out}"
}

# --- build-info: a permanent record of what actually compiled each artifact ---
#
# Worth more here than on an SDK that builds in containers. Node's abstract platforms are
# just linux, alpine, macos and windows, so EVERY glibc distro collapses into a single build
# unit named "linux". Which agent behind that label ran, and therefore which glibc the
# prebuild floors at and which of the hardcoded per-label toolchains compiled it, is chosen
# by the adapter and recorded nowhere else. When an `npm install couchbase` starts failing
# on an older distro, this file is the difference between reading it off and guessing.

_build_info_dir() { echo "${PROJECT_ROOT}/buildInfo"; }

# Mirrors bootstrap.sh's get_sha256 tool order (sha256sum / shasum / openssl), and yields
# "unknown" instead of failing: a missing hash must not fail a green build.
_sha256_of() {
    local out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" || out=""
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')" || out=""
    elif command -v openssl >/dev/null 2>&1; then
        out="$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')" || out=""
    fi
    echo "${out:-unknown}"
}

# "cmake version 3.31.6" -> "3.31.6"
_cmake_version_of() {
    local v=""
    v="$(cmake --version 2>/dev/null | head -1)" || v=""
    v="${v##* }"
    echo "${v:-unknown}"
}

# The unit name is the PREBUILD FILENAME MINUS ITS VERSION, e.g.
#     napi-v6-linux-x64-boringssl        electron-v28.0.0-darwin-arm64-boringssl
# and the caller passes it in rather than this deriving one.
#
# Not (platform, arch, runtime), which is what buildPlan fans out on. The neutral plan's
# unit is not the same thing as one invocation of this script: the ADAPTER expands a single
# plan unit into several concrete jobs, one per ABI floor, whenever a floor changes the
# binary. jenkins.mjs does it twice over, splitting openssl builds by node ABI floor
# (openssl1 vs openssl3) and electron builds by electron ABI floor. Those jobs share a
# platform, arch and runtime and differ only in what the filename's abi/ssl components
# record, so keying on the plan's three dimensions writes one file twice.
#
# That collision would be silent, which is the reason for the care. Both adapters REASSEMBLE
# these files by unioning directories (Jenkins copies each unstashed cell's, GHA's
# download-artifact does it with merge-multiple), and a name collision there overwrites
# without reporting anything. Deriving the name from the artifact name instead makes
# uniqueness a property of something already proven unique: two jobs that agreed on it would
# also be overwriting each other's prebuilds.
#
# The version is dropped on purpose. Comparing two builds OF THE SAME VERSION is what these
# records are for, so the name has to be stable across them.

# Host toolchain for a native linux/alpine build. This whole block exists because the
# compiler is NOT a property of the build unit: the adapter picks an agent label, and the
# label's entry in the pipeline's compiler table decides whether this was devtoolset-9,
# gcc-toolset-12 or a distro gcc. CC/CXX are recorded as given AND resolved, because the
# name alone ("gcc") says nothing about which one was on PATH.
_emit_linux_toolchain() {
    local distro="" kernel="" cc_bin="" cc_ver="" ld_ver="" libc_ver=""
    distro="$(sed -n 's/^PRETTY_NAME="\?\([^"]*\)"\?/\1/p' /etc/os-release 2>/dev/null | head -1)" || distro=""
    kernel="$(uname -r 2>/dev/null)" || kernel=""

    cc_bin="${CC:-cc}"
    cc_ver="$("${cc_bin}" --version 2>/dev/null | head -1)" || cc_ver=""
    ld_ver="$(ld --version 2>/dev/null | head -1)" || ld_ver=""

    # glibc reports itself through `ldd --version`; musl's ldd has no --version and prints
    # its banner on stderr with a nonzero exit, so both are read from one 2>&1 capture and
    # the failure is expected rather than an error.
    libc_ver="$(ldd --version 2>&1 | head -1)" || true

    echo "distro=${distro:-unknown}"
    echo "kernel=${kernel:-unknown}"
    echo "libc_flavor=${CBCI_BUILD_LIBC:-unknown}"
    echo "libc=${libc_ver:-unknown}"
    echo "compiler=${cc_ver:-unknown}"
    echo "cc=${CC:-unset}"
    echo "cxx=${CXX:-unset}"
    echo "cc_resolved=$(command -v "${cc_bin}" 2>/dev/null || echo unknown)"
    echo "linker=${ld_ver:-unknown}"
    echo "cmake=$(_cmake_version_of)"
    # The MACHINE's arch, not the unit's: an x64 unit on an arm64 host is an emulated build,
    # a different compiler invocation from the same unit on Intel hardware.
    echo "host_arch=$(uname -m)"
}

# Xcode version WITHOUT `xcodebuild -version`, which is the obvious probe and the wrong one:
# it fails outright when the active developer dir is a CommandLineTools instance, and two units
# sharing a mac agent race it, which reports `xcode=unknown` for one of them while its sibling
# on the same agent reports a version. Reading the developer dir's own version.plist is a file
# read: no daemon, no lock, no shared prefs, and nothing to lose a race to.
_macos_xcode_version() {
    local dev bundle ver
    dev="$(xcode-select -p 2>/dev/null | head -1)" || dev=""
    [[ -n "${dev}" ]] || { echo "unknown"; return; }
    # /Applications/Xcode.app/Contents/Developer -> /Applications/Xcode.app/Contents/version.plist.
    bundle="${dev%/Developer}"
    if [[ -r "${bundle}/version.plist" ]]; then
        ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "${bundle}/version.plist" 2>/dev/null)" || ver=""
        [[ -z "${ver}" ]] || { echo "Xcode ${ver}"; return; }
    fi
    # A CommandLineTools dir has no such plist and is not an Xcode at all. Report the dir rather
    # than "unknown": which toolchain is active is the thing worth knowing, and a CLT-only agent
    # producing release prebuilds is itself the finding.
    echo "${dev}"
}

# Host toolchain on macOS, none of which the SDK sha pins. This is the field set that
# catches two agents behind one label carrying different platform SDKs.
_emit_macos_toolchain() {
    local sdk="" sdk_path="" clang="" xcode="" os=""
    sdk="$(xcrun --show-sdk-version 2>/dev/null | head -1)" || sdk=""
    sdk_path="$(xcrun --show-sdk-path 2>/dev/null | head -1)" || sdk_path=""
    clang="$(cc --version 2>/dev/null | head -1)" || clang=""
    xcode="$(_macos_xcode_version)"
    os="$(sw_vers -productVersion 2>/dev/null | head -1)" || os=""
    echo "macos_sdk=${sdk:-unknown}"
    echo "macos_sdk_path=${sdk_path:-unknown}"
    echo "macos_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-unset}"
    echo "compiler=${clang:-unknown}"
    echo "xcode=${xcode:-unknown}"
    echo "runner_os=${os:-unknown}"
    echo "cmake=$(_cmake_version_of)"
    echo "host_arch=$(uname -m)"
}

# The prebuilds this unit produced, with hashes, so a binary pulled out of a published
# platform package can be matched back to the record of what built it. Indexed rather than
# repeated keys, and counted, so a reader can tell "none" from "the field is missing".
_emit_prebuild_identity() {
    local -a bins=()
    while IFS= read -r -d '' f; do bins+=("${f}"); done \
        < <(find "${PROJECT_ROOT}/prebuilds" -maxdepth 1 -name '*.node' -print0 \
            2>/dev/null | sort -z)
    echo "prebuild_count=${#bins[@]}"
    local i=0 b
    for b in "${bins[@]}"; do
        i=$((i + 1))
        echo "prebuild_${i}=$(basename "${b}")"
        echo "prebuild_${i}_sha256=$(_sha256_of "${b}")"
    done
}

# Toolchain-independent facts shared by every record this file writes.
_emit_common_identity() {
    # CI identity arrives through NEUTRAL vars the adapter sets (Jenkins NODE_NAME and
    # JOB_NAME #BUILD_NUMBER; GHA runner.name and workflow #run_number), so this file
    # speaks no CI's vocabulary. The agent falls back to the hostname, which keeps the
    # single most investigation-critical field correct even from a bare local run.
    local agent="${CBCI_BUILD_AGENT:-}"
    [[ -n "${agent}" ]] || agent="$(uname -n 2>/dev/null || true)"

    echo "agent=${agent:-unknown}"
    echo "build=${CBCI_BUILD_REF:-unknown}"
    echo "runner_image=${CBCI_BUILD_IMAGE:-unknown}"
    echo "node=$("${NODE_BIN}" -p 'process.versions.node' 2>/dev/null || echo unknown)"
    echo "npm=$("${NPM_BIN}" --version 2>/dev/null || echo unknown)"
    # Both shas, because a release is the product of two repos and the release version names
    # only one of them. CBCI_SHA comes first because it is the only one available to the
    # prebuild stage: that stage builds from the packed sdist, which carries no git metadata
    # (see _record_sdist_info, which runs where the checkout still exists).
    local sdk_sha="${CBCI_SHA:-}"
    [[ -n "${sdk_sha}" ]] || sdk_sha="$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null | head -1)" || sdk_sha=""
    echo "sdk_sha=${sdk_sha:-unknown}"
}

# `submodule status --recursive` plus a name match, rather than a hardcoded deps/ path, so
# moving the submodule does not silently record "unknown".
_cxx_client_sha() {
    local sha=""
    sha="$(git -C "${PROJECT_ROOT}" submodule status --recursive 2>/dev/null \
        | awk '$2 ~ /cxx-client/ { gsub(/^[-+U]/, "", $1); print $1; exit }')" || sha=""
    echo "${sha:-unknown}"
}

# Emit the toolchain block for whichever host this is. Windows records its own in tasks.ps1.
_emit_host_toolchain() {
    case "${CBCI_BUILD_PLATFORM:-linux}" in
        macos) _emit_macos_toolchain ;;
        *)     _emit_linux_toolchain ;;
    esac
}

# The sdist unit record, written where the SDK GIT TREE still exists. This is the only stage
# that can resolve the C++ core's submodule sha, which is why it records one at all: the
# prebuild stages downstream build from the packed tarball and have no git metadata to read.
# The toolchain here is the one that configured the core and baked the CPM cache, which is
# not the one that compiled any shipped binary.
_record_sdist_info() {
    local info_dir; info_dir="$(_build_info_dir)"
    local info="${info_dir}/sdist.txt"
    mkdir -p "${info_dir}"
    {
        echo "unit=sdist"
        echo "platform=${CBCI_BUILD_PLATFORM:-linux}"
        echo "arch=${CBCI_BUILD_ARCH:-$(_node_arch)}"
        echo "runtime=none"
        echo "package_version=$(_pkg_version 2>/dev/null || echo unknown)"
        _emit_common_identity
        echo "cxx_client_sha=$(_cxx_client_sha)"
        _emit_host_toolchain
    } > "${info}"
    while IFS= read -r info_line; do log "  build-info: ${info_line}"; done < "${info}"
}

# Records ONE prebuild unit, as buildInfo/<unit>.txt, where <unit> is the version-free
# prebuild name described above. Called after the strip/split so the hashes it records are
# the hashes of the binaries that actually ship.
_record_build_info() {
    local unit="${1:-}"
    [[ -n "${unit}" ]] || die "build-info: _record_build_info needs a unit name"
    local info_dir; info_dir="$(_build_info_dir)"
    local info="${info_dir}/${unit}.txt"
    mkdir -p "${info_dir}"

    local runtime="${CBCI_BUILD_RUNTIME:-node}" runtime_version=""
    if [[ "${runtime}" == "electron" ]]; then
        runtime_version="${CBCI_BUILD_ELECTRON_VERSION:-unknown}"
    else
        runtime_version="${CBCI_BUILD_NODE_VERSION:-unknown}"
    fi

    {
        echo "unit=${unit}"
        echo "platform=${CBCI_BUILD_PLATFORM:-linux}"
        echo "arch=${CBCI_BUILD_ARCH:-$(_node_arch)}"
        echo "runtime=${runtime}"
        # The runtime version is the ABI TARGET, not a fan-out dimension: for node it is the
        # representative version whose headers cmake-js built against, and the N-API level
        # below is what actually makes the result work on the others.
        echo "runtime_version=${runtime_version}"
        echo "napi_version=$([[ "${runtime}" == "node" ]] && echo "${CN_NAPI_VERSION:-6}" || echo n/a)"
        echo "ssl=$([[ "${CN_USE_OPENSSL:-OFF}" == "ON" ]] && echo openssl || echo boringssl)"
        echo "build_type=${CN_BUILD_CONFIG:-unknown}"
        echo "package_version=$(_pkg_version 2>/dev/null || echo unknown)"
        _emit_common_identity
        echo "cxx_client_sha=$(_cxx_client_sha)"
        _emit_host_toolchain
        _emit_prebuild_identity
    } > "${info}"

    while IFS= read -r info_line; do log "  build-info: ${info_line}"; done < "${info}"
}

# First value for a key in a unit record. `head -1` so a duplicated key cannot yield a
# two-line field that shifts every column after it in the summary table.
_bi_kv() {
    local v; v="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1)" || v=""
    echo "${v:-unknown}"
}

# Keeps a summary row on ONE line. The untruncated value is always in the unit's own file,
# so the summary can afford to be lossy and the table cannot afford to wrap.
_bi_clip() {
    local v="$1" n="$2"
    if (( ${#v} > n )); then echo "${v:0:n-3}..."; else echo "${v}"; fi
}

# The identifying HOST fact: the distro whose glibc the binary now floors at, or the
# platform SDK it was linked against. This is the column that moves when one agent behind a
# shared label drifts, which on this SDK is the whole reason the record exists.
_bi_host() {
    local platform; platform="$(_bi_kv "$1" platform)"
    case "${platform}" in
        macos)   _bi_clip "macOS SDK $(_bi_kv "$1" macos_sdk)" 34 ;;
        windows) _bi_clip "Windows SDK $(_bi_kv "$1" windows_sdk)" 34 ;;
        *)       _bi_clip "$(_bi_kv "$1" distro)" 34 ;;
    esac
}

# The first record that carries a real value for `key`. The prebuild stages build from the
# packed sdist and record "unknown" for anything git-derived, so a header that read the
# first unit alone would report the C++ core sha as unknown for every release.
_bi_first_known() {
    local key="$1"; shift
    local u v
    for u in "$@"; do
        v="$(_bi_kv "${u}" "${key}")"
        if [[ "${v}" != "unknown" && -n "${v}" ]]; then echo "${v}"; return; fi
    done
    echo "unknown"
}

# Header facts plus one aligned row per unit. The columns are chosen so that drift is
# visible by scanning: two agents building one release on different distros differ in the
# last column and nowhere else.
_build_info_summary() {
    local version="$1"; shift
    local -a units=("$@")

    echo "release=${version}"
    echo "build=$(_bi_first_known build "${units[@]}")"
    echo "sdk_sha=$(_bi_first_known sdk_sha "${units[@]}")"
    echo "cxx_client_sha=$(_bi_first_known cxx_client_sha "${units[@]}")"
    echo "units=${#units[@]}"
    echo ""

    # Widths sized for the longest name the adapter can produce, which is an electron unit
    # (electron-v<semver>-<platform>-<arch>-<ssl>). A row that wraps defeats the point of a
    # table whose only job is making drift visible by scanning one column.
    printf '%-40s %-9s %-30s %s\n' 'unit' 'runtime' 'toolchain' 'host'
    local u
    for u in "${units[@]}"; do
        printf '%-40s %-9s %-30s %s\n' \
            "$(_bi_clip "$(_bi_kv "${u}" unit)" 40)" \
            "$(_bi_clip "$(_bi_kv "${u}" runtime)" 9)" \
            "$(_bi_clip "$(_bi_kv "${u}" compiler)" 30)" \
            "$(_bi_host "${u}")"
    done
}

# Packs the per-unit records the build archived into ONE object for permanent storage:
# SUMMARY.txt (the whole release on one screen) plus the unit files themselves.
#
# Neutral on purpose. The archive and its summary are what is worth keeping identical across
# CI vendors and worth testing on a laptop; only PUTTING the object is adapter work (Jenkins
# s3Upload through the plugin, GHA aws-cli under an OIDC role), because credential
# acquisition and the available tooling differ.
#
#   tasks.sh build-info-pack [dir] [out.tar.gz]
#
# dir defaults to ./build-info, where both adapters' artifact download lands it, and the
# output to ./build-info-${CBCI_VERSION}.tar.gz. tar.gz rather than zip because tar is
# already a hard dependency of the prebuild split on every platform, while zip(1) is not
# guaranteed on a release agent, and because -debug.tar.gz already sets the convention for
# this SDK's side-band artifacts.
#
# Deliberately does NOT call load_project_env: this operates on text files alone, so it must
# not need engine.mjs, its yaml dependency, or an SDK checkout on an agent that has none of
# them.
task_build_info_pack() {
    local dir="${1:-build-info}"
    local version="${CBCI_VERSION:-unknown}"
    local out="${2:-build-info-${version}.tar.gz}"

    [[ -d "${dir}" ]] || die "build-info-pack: no such directory: ${dir}"
    local -a units=()
    while IFS= read -r -d '' f; do units+=("${f}"); done \
        < <(find "${dir}" -maxdepth 1 -name '*.txt' ! -name 'SUMMARY.txt' -print0 \
            2>/dev/null | sort -z)
    # Refuse to pack an empty record rather than publishing an archive that LOOKS like the
    # release was documented. What an absent record means is the caller's call.
    [[ ${#units[@]} -gt 0 ]] || die "build-info-pack: no unit records in ${dir}"

    _build_info_summary "${version}" "${units[@]}" > "${dir}/SUMMARY.txt"
    while IFS= read -r line; do log "  ${line}"; done < "${dir}/SUMMARY.txt"

    # Absolute, because tar runs with -C dir so its members are bare filenames rather than
    # build-info/<name>: one less directory for a reader to descend, and it keeps every
    # member name equal to its unit name.
    local abs_out
    case "${out}" in /*) abs_out="${out}" ;; *) abs_out="${PWD}/${out}" ;; esac
    rm -f "${abs_out}"

    local -a members=(SUMMARY.txt)
    local u
    for u in "${units[@]}"; do members+=("$(basename "${u}")"); done

    tar -czf "${abs_out}" -C "${dir}" "${members[@]}" \
        || die "build-info-pack: failed to write ${abs_out}"

    log "build-info-pack: ${#members[@]} member(s) -> ${abs_out}"
    log "build-info-pack: sha256=$(_sha256_of "${abs_out}")"
}

# --- stages --------------------------------------------------------------

task_display_info() {
    load_project_env
    log "project=COUCHNODE prefix=${CBCI_PROJECT_PREFIX:-} config_override=${CBCI_CONFIG_OVERRIDE:-}"
    "${NODE_BIN}" "${ENGINE}" validate-config
}

task_lint() {
    # Ported from the repo's own `npm run lint` (package.json: eslint ./lib/ ./test/).
    cd "${PROJECT_ROOT}"
    log "installing dependencies (npm ci --ignore-scripts)"
    "${NPM_BIN}" ci --ignore-scripts
    log "running eslint"
    "${NPM_BIN}" run lint
}

# --- sdist: configure-only pass. Bakes the C++ core's CPM cache
# (deps/couchbase-cxx-cache) into the tree BEFORE `npm pack`, so the sdist tarball
# is self-sufficient for a from-source build (no network/CPM fetch needed later).
# In scripts/prebuilds.js's configureBinary(), the CLI flags --configure/--set-cpm-cache
# pick the configure-only code path (there is no env equivalent for that decision), and
# CN_USE_OPENSSL/CN_SET_CPM_CACHE (from `build-env sdist`) supply the VALUES that path
# reads. CN_BUILD_CONFIG/CN_VERBOSE_MAKEFILE do not apply: the configure step never
# reads them.
task_sdist() {
    cd "${PROJECT_ROOT}"

    log "installing dependencies (npm ci --ignore-scripts)"
    "${NPM_BIN}" ci --ignore-scripts

    if [[ ! -e deps/couchbase-cxx-client/.git && ! -e deps/couchbase-cxx-client/CMakeLists.txt ]]; then
        log "initializing couchbase-cxx-client submodule"
        git submodule update --init --recursive deps/couchbase-cxx-client \
            || die "sdist: cannot init couchbase-cxx-client submodule"
    fi

    local build_env
    build_env="$("${NODE_BIN}" "${ENGINE}" build-env sdist)" || die "failed to resolve sdist build-env"
    log "sdist build-env: ${build_env}"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${build_env}

    log "configuring C++ core + baking CPM cache (deps/couchbase-cxx-cache)"
    # --configure is unconditional (that's what selects cmake-js's configure-only path
    # over a full build); --set-cpm-cache must stay conditional on CN_SET_CPM_CACHE
    # (from build.set_cpm_cache) rather than hardcoded, or the config knob would be
    # unenforceable: buildPrebuild.js's CLI parsing always resolves setCpmCache to a
    # defined boolean once any arg is present, so a hardcoded flag would always win
    # over configureBinary()'s CN_SET_CPM_CACHE env-var fallback.
    local set_cpm_cache_args=()
    [[ "${CN_SET_CPM_CACHE:-ON}" == "ON" ]] && set_cpm_cache_args=(--set-cpm-cache)
    "${NPM_BIN}" run prebuild -- --configure "${set_cpm_cache_args[@]}"

    log "packing source distribution (npm pack)"
    "${NPM_BIN}" pack
    log "dist contents:"
    ls -alh ./*.tgz

    _record_sdist_info
}

# --- prebuild: the actual compile, one build unit per (platform, arch, libc?, ssl,
# runtime). scripts/prebuilds.js's buildBinary() reads
# CN_USE_OPENSSL/CN_BUILD_CONFIG/CN_VERBOSE_MAKEFILE (from `build-env prebuild`) and
# CN_PREBUILD_RUNTIME/CN_PREBUILD_RUNTIME_VERSION (from `prebuild-select-env`, itself
# fed by the adapter's per-job CBCI_BUILD_* env). CN_USE_CPM_CACHE defaults to true, so
# this reuses the CPM cache the sdist stage baked in and needs no extra env.

# Strip debug symbols + emit the separate debug artifacts. The FULL pre-strip binary is
# preserved as a tar.gz under prebuildsDebug/ BEFORE stripping; linux additionally keeps a
# <filename>.debug companion there holding only the symbols, which is what the stripped
# binary's .gnu_debuglink points at. Windows never strips (no strip toolchain assumed);
# its debug artifact is the compiler-emitted .pdb.
# Its OWN directory, deliberately not a subdirectory of prebuildsDebug/. That directory is
# the publish payload: the aggregate stage copies every entry of it into dist_debug/ and the
# release job uploads every file there to a public bucket. Diagnostics belong in neither.
_repair_diag_dir() { echo "${PROJECT_ROOT}/repairDiag"; }

# Dump everything needed to diagnose a failed symbol split, then let the caller die. This is
# the only chance to preserve the evidence: the prebuild stage stashes NOTHING when it
# fails, so an agent that goes away takes the binary, the tool output and the environment
# with it, and the next step is a 40-minute rebuild to see the same message again.
#
# Best-effort throughout, and it must stay that way: a failure inside the dumper would
# replace the caller's real error with a less useful one.
_repair_diag() {
    local stem="$1" target="$2" reason="$3"
    local diag_dir; diag_dir="$(_repair_diag_dir)"
    mkdir -p "${diag_dir}" 2>/dev/null || true
    local out="${diag_dir}/${stem}.repair-diag.txt"
    log "writing repair diagnostics to ${out}"

    {
        echo "=== prebuild-repair diagnostics: ${stem}"
        echo "reason=${reason}"
        echo "--- host"
        uname -a || true
        echo "--- tools"
        # WHICH binutils, not just whether one answered: a debuglink written by one version
        # and read by another is a real failure mode, and objcopy is the tool that ran.
        command -v objcopy >/dev/null 2>&1 && objcopy --version 2>&1 | head -1
        command -v readelf >/dev/null 2>&1 && readelf --version 2>&1 | head -1
        command -v strip >/dev/null 2>&1 && strip --version 2>&1 | head -1
        echo "--- build env"
        env | grep -E "^(CBCI_|CN_|CC|CXX|LD)" | sort || true
        echo "--- release binary: ${target}"
        ls -l "${target}" || true
        command -v file >/dev/null 2>&1 && file "${target}"
        # Section headers are the whole question: whether .debug_info survived the strip, and
        # whether .gnu_debuglink was added. Unfiltered, because a truncated view of the one
        # artifact worth looking at is what forces the rebuild this file exists to avoid.
        echo "-- readelf -S"
        readelf -S "${target}" 2>&1 || true
        # Build ID is the FIRST key gdb resolves separate symbols by, ahead of the debuglink,
        # so its absence changes how the symbols have to be delivered.
        echo "-- readelf -n"
        readelf -n "${target}" 2>&1 || true
        echo "--- debug artifacts produced so far"
        ls -l prebuildsDebug/ 2>&1 || true
        echo "--- companion: prebuildsDebug/${stem}.debug"
        if [[ -f "prebuildsDebug/${stem}.debug" ]]; then
            ls -l "prebuildsDebug/${stem}.debug"
            echo "-- readelf -S"
            readelf -S "prebuildsDebug/${stem}.debug" 2>&1 || true
        else
            echo "(absent)"
        fi
    } >"${out}" 2>&1 || true
}

task__prebuild_repair() {
    local built="$1" filename="$2"
    [[ -f "${built}" ]] || die "prebuild-repair: built binary not found: ${built}"

    mkdir -p prebuilds prebuildsDebug
    local target="prebuilds/${filename}.node"
    cp "${built}" "${target}"

    # Baseline for the post-strip size assertion, measured on the binary as built, before
    # any branch below touches it. Deliberately NOT derived from the -debug.tar.gz: gunzip
    # of that measures the tar member PLUS tar's headers and 512-byte-block padding, a few
    # KB of slop that is exactly why the comparison could previously only warn.
    local pre_size post_size
    pre_size="$(_file_size "${target}")"

    local uname_s; uname_s="$(uname -s)"
    if [[ "${uname_s}" == "Darwin" ]]; then
        log "prebuild-repair: tar full binary -> prebuildsDebug (macOS)"
        tar -czf "prebuildsDebug/${filename}-debug.tar.gz" -C prebuilds "$(basename "${target}")"
        log "prebuild-repair: xcrun strip -Sx"
        xcrun strip -Sx "${target}"
    elif [[ "${uname_s}" == "Linux" ]]; then
        log "prebuild-repair: tar full binary -> prebuildsDebug (Linux)"
        tar -czf "prebuildsDebug/${filename}-debug.tar.gz" -C prebuilds "$(basename "${target}")"
        # The separated symbols are KEPT as a companion file, not discarded. objcopy is run
        # from inside prebuilds/ so the debuglink records a bare filename, then the companion
        # moves to prebuildsDebug/ under that exact name: drop it beside the installed .node
        # and symbols resolve with no further steps.
        log "prebuild-repair: objcopy strip + debuglink -> ${filename}.debug"
        (
            cd prebuilds
            objcopy --only-keep-debug "${filename}.node" "${filename}.debug"
            objcopy --strip-debug --strip-unneeded "${filename}.node"
            objcopy --add-gnu-debuglink="${filename}.debug" "${filename}.node"
        )
        mv "prebuilds/${filename}.debug" "prebuildsDebug/${filename}.debug"
        if [[ ! -s "prebuildsDebug/${filename}.debug" ]]; then
            _repair_diag "${filename}" "${target}" "debug companion missing or empty"
            die "prebuild-repair: debug companion ${filename}.debug did not land in prebuildsDebug/"
        fi
    else
        die "prebuild-repair: unsupported uname -s '${uname_s}' (expected Darwin|Linux; Windows uses tasks.ps1)"
    fi

    # Post-strip integrity, checked HERE at the source rather than discovered as a useless
    # symbol set weeks later: the debug artifact must exist and be non-empty, the release
    # binary must be strictly smaller than it was pre-strip, and on Linux it must carry no
    # debug_info but a .gnu_debuglink pointing back at the companion.
    if [[ ! -s "prebuildsDebug/${filename}-debug.tar.gz" ]]; then
        _repair_diag "${filename}" "${target}" "pre-strip tarball missing or empty"
        die "prebuild-repair: prebuildsDebug/${filename}-debug.tar.gz is missing or empty, the pre-strip copy was not preserved"
    fi

    post_size="$(_file_size "${target}")"
    if (( post_size >= pre_size )); then
        _repair_diag "${filename}" "${target}" "strip did not shrink the binary (${pre_size} -> ${post_size})"
        die "prebuild-repair: stripped ${filename}.node is ${post_size} bytes, not smaller than the ${pre_size}-byte binary it was stripped from; the strip removed nothing"
    fi

    if [[ "${uname_s}" == "Linux" ]]; then
        local sections
        if ! sections="$(_elf_sections "${target}")"; then
            _repair_diag "${filename}" "${target}" "readelf could not read the release binary"
            die "prebuild-repair: readelf could not read ${target} (error above), so the strip cannot be verified either way"
        fi
        # .zdebug_info as well: --compress-debug-sections=zlib-gnu renames the section, and
        # a zlib-gnu build carries debug info by any definition that matters here.
        if grep -q '\.z\?debug_info' <<<"${sections}"; then
            _repair_diag "${filename}" "${target}" "release binary still carries debug_info"
            die "prebuild-repair: release .node still carries .debug_info, strip failed"
        fi
        if ! grep -q '\.gnu_debuglink' <<<"${sections}"; then
            _repair_diag "${filename}" "${target}" "release binary has no .gnu_debuglink"
            die "prebuild-repair: release .node missing .gnu_debuglink, debuglink not added"
        fi
    fi
    log "prebuild-repair: ${filename}.node ready (prebuilds/, prebuildsDebug/)"
}

task_prebuild() {
    cd "${PROJECT_ROOT}"

    # Self-sufficient build FROM the packed sdist tarball: this stage depends on nothing
    # the sdist stage's own working tree left behind (npm ci/submodule/configure state).
    # The tarball already carries deps/couchbase-cxx-cache/** (npm pack's `files`
    # allowlist), so unpacking it needs no network CPM fetch.
    local sdist_tgz
    sdist_tgz="$(ls ./*.tgz 2>/dev/null | head -1)" || true
    [[ -n "${sdist_tgz}" ]] || die "prebuild: no *.tgz found under ${PROJECT_ROOT} (unstash the sdist first?)"
    log "prebuild: unpacking ${sdist_tgz}"
    tar -xzf "${sdist_tgz}" --strip-components=1

    # package-lock.json is NOT in package.json's `files` allowlist, so there is no lock
    # file to verify against and `npm ci` cannot run here; it must be `npm install`.
    # --ignore-scripts skips the package's own "install": "node ./scripts/install.js",
    # which would otherwise build against the AMBIENT runtime before build-env and
    # prebuild-select-env below set the real target (CN_PREBUILD_RUNTIME_VERSION).
    log "prebuild: restoring devDependencies (npm install --ignore-scripts)"
    "${NPM_BIN}" install --ignore-scripts

    local build_env
    build_env="$("${NODE_BIN}" "${ENGINE}" build-env prebuild)" || die "failed to resolve prebuild build-env"
    log "prebuild build-env: ${build_env}"
    # shellcheck disable=SC2086,SC2163
    export ${build_env}

    local select_env
    select_env="$("${NODE_BIN}" "${ENGINE}" prebuild-select-env)" || die "failed to resolve prebuild-select-env"
    log "prebuild select-env:"; log "  ${select_env//$'\n'/$'\n''  '}"
    local k v
    while IFS='=' read -r k v; do
        [[ -n "${k}" ]] && export "${k}=${v}"
    done <<<"${select_env}"

    if [[ "${CBCI_BUILD_RUNTIME:-node}" == "electron" ]]; then
        [[ -n "${CBCI_BUILD_ELECTRON_VERSION:-}" ]] \
            || die "prebuild: runtime=electron requires CBCI_BUILD_ELECTRON_VERSION (set by the adapter per job)"
    fi

    log "building (npm run prebuild) runtime=${CN_PREBUILD_RUNTIME:-node} version=${CN_PREBUILD_RUNTIME_VERSION:-<ambient>}"
    "${NPM_BIN}" run prebuild

    local build_config="${CN_BUILD_CONFIG:-RelWithDebInfo}"
    local built=""
    if [[ -f "build/${build_config}/couchbase_impl.node" ]]; then
        built="build/${build_config}/couchbase_impl.node"
    elif [[ -f "build/Release/couchbase_impl.node" ]]; then
        built="build/Release/couchbase_impl.node"
    elif [[ -f "build/couchbase_impl.node" ]]; then
        built="build/couchbase_impl.node"
    else
        built="$(find build -name "couchbase_impl.node" 2>/dev/null | head -1 || true)"
    fi
    [[ -n "${built}" && -f "${built}" ]] || die "prebuild: expected binary not found: build/${build_config}/couchbase_impl.node"

    # Filename convention scripts/prebuilds.js resolves against:
    #   couchbase-v<version>-{napi|electron}-v<abi>-<nodePlatform>-<nodeArch>-<ssl>.node
    # napi's <abi> is the hardcoded CMakeLists.txt NAPI_VERSION floor (6); electron's is
    # the actual Electron version this job built against (CBCI_BUILD_ELECTRON_VERSION).
    local version node_platform node_arch kind abi ssl_suffix
    version="$(_pkg_version)"
    node_platform="$(_node_platform)"
    node_arch="$(_node_arch)"
    [[ "${CBCI_BUILD_PLATFORM:-}" == "alpine" && "${node_platform}" == "linux" ]] && node_platform="linuxmusl"

    if [[ "${CBCI_BUILD_RUNTIME:-node}" == "electron" ]]; then
        kind="electron"; abi="${CBCI_BUILD_ELECTRON_VERSION}"
        ssl_suffix="boringssl"   # electron is always boringssl (ground-truthed: getPrebuildFileName)
    else
        kind="napi"; abi="6"
        if [[ "${CN_USE_OPENSSL:-OFF}" == "ON" ]]; then
            (( $(_node_major) >= 18 )) && ssl_suffix="openssl3" || ssl_suffix="openssl1"
        else
            ssl_suffix="boringssl"
        fi
    fi
    local filename="couchbase-v${version}-${kind}-v${abi}-${node_platform}-${node_arch}-${ssl_suffix}"
    # The same components minus the version: unique per JOB (which the version is not, and
    # which platform/arch/runtime alone is not either), and stable across releases so two
    # builds of one version can be diffed. See _build_info_unit.
    local unit_key="${kind}-v${abi}-${node_platform}-${node_arch}-${ssl_suffix}"

    task__prebuild_repair "${built}" "${filename}"
    # After the split, so the hashes recorded are the ones that ship.
    _record_build_info "${unit_key}"
    log "prebuild: release:"; ls -alh prebuilds
    log "prebuild: debug:";   ls -alh prebuildsDebug
}

# --- validate: install the BUILT artifact into a clean checkout and smoke-require it,
# proving what an `npm install couchbase` consumer actually gets rather than what the repo
# source tree does. install_type=prebuild simulates the platform-package resolve path via
# npm_config_couchbase_local_prebuilds, which scripts/install.js reads in
# getLocalPrebuild()/resolveLocalPrebuild(). install_type=sdist forces the full cmake-js
# source build with no local-prebuilds hint, proving the sdist tarball is self-sufficient
# (CPM cache baked in, no network fetch needed).
# The smoke script, emitted verbatim (quoted heredoc = no shell expansion, so the JS may
# use $ and backticks freely). On failure it names the cause instead of leaving you with
# the SDK's own message, which reports only what the loader WANTED: resolvePrebuild()
# throws "Could not find native build for platform=..., arch=..., runtime=..., sslType=..."
# after swallowing the real error, and never says what was actually present. Since a failed
# validate never reaches archiving, this in-process look is the only one anyone gets.
_validate_smoke_js() {
    cat <<'NODEJS'
const fs = require('fs');
const path = require('path');

function dumpAddons() {
  const facts = [`node ${process.versions.node}`, `Node-API ${process.versions.napi}`,
    `${process.platform}/${process.arch}`, `ssl=${process.env.CBCI_VALIDATE_SSL || '?'}`];
  if (process.platform === 'linux') {
    // Only linux splits the prebuild's platform token by libc, and it is the token most
    // likely to be wrong (a manylinux binary in an alpine container, or the reverse).
    const report = typeof process.report?.getReport === 'function' ? process.report.getReport() : null;
    const glibc = report?.header?.glibcVersionRuntime;
    facts.push(glibc ? `glibc ${glibc}` : 'musl (no glibc runtime reported)');
  }
  console.error(`[validate] load failed on ${facts.join(', ')}`);

  const found = [];
  const walk = (dir) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.node')) found.push(p);
    }
  };
  walk('node_modules');

  if (!found.length) {
    console.error('[validate]   shipped: NO .node addon anywhere under node_modules/ '
      + '(the prebuild never landed, or a source build was expected and did not produce one)');
    return;
  }
  // The loader matches on the FILENAME's tokens, so the name is the diagnosis:
  //   couchbase-v<pkg>-<runtime>-v<abi>-<platform|libc>-<arch>-<ssl>.node
  // A mismatch in any one of them (musl vs glibc, openssl3 vs boringssl, arch) presents
  // as "no native build found", identical to nothing having shipped at all.
  for (const p of found) console.error(`[validate]   shipped: ${p}`);
}

const mod = process.env.CBCI_VALIDATE_IMPORT;
try {
  const pkg = require(mod);
  if (typeof pkg.connect !== 'function') {
    console.error('[validate] couchbase module missing connect()');
    process.exit(1);
  }
  console.log(`[validate] required ${mod} OK, connect() present`);
} catch (err) {
  dumpAddons();
  throw err;
}
NODEJS
}

_validate_one() {
    local itype="$1" sdist_tgz="$2"
    local tmp; tmp="$(mktemp -d)"
    log "validate: install_type=${itype} in ${tmp}"
    (
        cd "${tmp}"
        "${NPM_BIN}" init -y >/dev/null
        # Registry mode (release-verify): install the PUBLISHED package by name, so what is
        # exercised is what a consumer actually gets. The install types keep their meaning:
        # 'prebuild' lets npm resolve the optionalDependencies, '--omit=optional' withholds
        # them and forces the from-source fallback.
        if [[ -n "${CBCI_PACKAGING_INDEX:-}" ]]; then
            local spec="${CBCI_VALIDATE_PACKAGE_NAME}@${CBCI_VERSION:?validate: CBCI_VERSION required when CBCI_PACKAGING_INDEX is set}"
            if [[ "${itype}" == "prebuild" ]]; then
                "${NPM_BIN}" install --save "${spec}"
            elif [[ "${itype}" == "sdist" ]]; then
                "${NPM_BIN}" install --save --omit=optional "${spec}"
            else
                die "validate: unknown install_type: ${itype} (prebuild|sdist)"
            fi
            "${NPM_BIN}" list --depth=1 || true
            # An --omit=optional install that still resolved a platform package would be
            # testing the prebuild path twice and reporting the source path as covered.
            if [[ "${itype}" == "sdist" ]] \
               && "${NPM_BIN}" list --depth=1 2>/dev/null | grep -q "@${CBCI_VALIDATE_PACKAGE_NAME}/"; then
                die "validate: --omit=optional still pulled a platform package; the from-source path was not exercised"
            fi
            "${NODE_BIN}" -e "$(_validate_smoke_js)"
            exit $?
        fi
        if [[ "${itype}" == "prebuild" ]]; then
            local prebuild_dir; prebuild_dir="$(mktemp -d)"
            cp "${PROJECT_ROOT}"/prebuilds/*.node "${prebuild_dir}/" 2>/dev/null \
                || die "validate: no prebuild found under ${PROJECT_ROOT}/prebuilds (build it first?)"
            npm_config_couchbase_local_prebuilds="${prebuild_dir}" "${NPM_BIN}" install "${sdist_tgz}"
            rm -rf "${prebuild_dir}"
        elif [[ "${itype}" == "sdist" ]]; then
            "${NPM_BIN}" install "${sdist_tgz}"
        else
            die "validate: unknown install_type: ${itype} (prebuild|sdist)"
        fi
        "${NODE_BIN}" -e "$(_validate_smoke_js)"
    )
    local rc=$?
    rm -rf "${tmp}"
    return "${rc}"
}

task_validate() {
    cd "${PROJECT_ROOT}"
    local out
    out="$("${NODE_BIN}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086,SC2163
    export ${out}
    [[ -n "${CBCI_INSTALL_TYPE:-}" ]] && CBCI_VALIDATE_INSTALL_TYPES="${CBCI_INSTALL_TYPE}"

    # Registry mode installs by name from the index, so there is no local artifact to find.
    local sdist_tgz=""
    if [[ -z "${CBCI_PACKAGING_INDEX:-}" ]]; then
        sdist_tgz="$(ls "${PROJECT_ROOT}"/*.tgz 2>/dev/null | head -1 || true)"
        [[ -n "${sdist_tgz}" ]] || die "validate: no *.tgz found under ${PROJECT_ROOT} (build sdist first?)"
    else
        log "validate: registry mode, index=${CBCI_PACKAGING_INDEX} version=${CBCI_VERSION:-<unset>}"
    fi

    local itype
    IFS=',' read -ra _types <<<"${CBCI_VALIDATE_INSTALL_TYPES}"
    for itype in "${_types[@]}"; do
        _validate_one "${itype}" "${sdist_tgz}" || die "validate: ${itype} failed"
        log "validate: ${itype} OK"
    done
    log "validate: all install types passed (${CBCI_VALIDATE_INSTALL_TYPES})"
}

# --- test: run the mocha suite against the CouchbaseMock.jar backend (default) or a real
# cluster. With CNCSTR unset here, test/harness.js falls back to the mock. require_java is
# a real dependency: test/jcbmock.js spawns `java` directly to run the mock jar.
#
# NOTHING IS COMPILED HERE. `test` consumes the prebuild the `prebuild` stage already
# produced, the same contract as `validate`:
#   1. write couchbase_local_prebuilds into .npmrc, so npm re-exports it to lifecycle
#      scripts as npm_config_couchbase_local_prebuilds, which is exactly the name
#      scripts/install.js reads in getLocalPrebuild(). It must be visible to
#      `npm run install`, not merely at dependency-install time, hence .npmrc rather than
#      a shell export.
#   2. `npm ci --ignore-scripts`: deps only, so the package's own install.js never runs.
#   3. `npm run install`: install.js sees the local-prebuilds hint and COPIES the .node
#      into build/Release instead of invoking cmake-js.
# Step 3 is verified, not trusted. install.js's installPrebuild() falls back to
# prebuilds.buildBinary() when it cannot resolve a prebuild, so a missing or mismatched
# .node would silently turn into a full source build: slow, and GREEN. The post-condition
# check below turns that into a hard failure.
_target_node_platform() {
    local plat="${CBCI_BUILD_PLATFORM:-${CBCI_TEST_PLATFORM:-${CBCI_PLATFORM:-}}}"
    if [[ "${plat}" == "alpine" ]]; then
        echo "linuxmusl"
        return
    fi
    _node_platform
}

_test_prebuild_dir() {
    local dir="${PROJECT_ROOT}/prebuilds"
    [[ -d "${dir}" ]] || die "test: no prebuilds/ under ${PROJECT_ROOT}; the prebuild stage must run (or its artifact be copied) first"
    # Defense-in-depth: remove .node files for other platforms if multiple platform artifacts were copied
    local target_plat; target_plat="$(_target_node_platform)"
    local f f_base
    for f in "${dir}"/*.node; do
        [[ -f "${f}" ]] || continue
        f_base="$(basename "${f}")"
        case "${target_plat}" in
            win32)            [[ "${f_base}" == *"-darwin-"* || "${f_base}" == *"-linux-"* || "${f_base}" == *"-linuxmusl-"* ]] && rm -f "${f}" ;;
            darwin)           [[ "${f_base}" == *"-win32-"* || "${f_base}" == *"-linux-"* || "${f_base}" == *"-linuxmusl-"* ]] && rm -f "${f}" ;;
            linux)            [[ "${f_base}" == *"-win32-"* || "${f_base}" == *"-darwin-"* || "${f_base}" == *"-linuxmusl-"* ]] && rm -f "${f}" ;;
            alpine|linuxmusl) [[ "${f_base}" == *"-win32-"* || "${f_base}" == *"-darwin-"* || ( "${f_base}" == *"-linux-"* && "${f_base}" != *"-linuxmusl-"* ) ]] && rm -f "${f}" ;;
        esac
    done
    compgen -G "${dir}/*.node" >/dev/null \
        || die "test: prebuilds/ exists but holds no *.node, so scripts/install.js has nothing to resolve"
    printf '%s\n' "${dir}"
}

# Fail loudly if `npm run install` compiled (or produced nothing) instead of copying the
# prebuild. build/Release is install.js's own destination for the resolved binary.
_assert_prebuild_installed() {
    local rel="${PROJECT_ROOT}/build/Release"
    compgen -G "${rel}/*.node" >/dev/null \
        || die "test: no *.node in build/Release after 'npm run install'; the prebuild was not resolved"
    log "test: prebuild installed:"; ls -alh "${rel}"/*.node
}

task_test() {
    cd "${PROJECT_ROOT}"

    if [[ -n "${CBCI_TEST_HOST:-}" && -z "${CNCSTR:-}" ]]; then
        export CNCSTR="couchbase://${CBCI_TEST_HOST}"
        export CNUSER="${CNUSER:-Administrator}"
        export CNPASS="${CNPASS:-password}"
    fi

    if [[ "${CBCI_TEST_CLUSTER:-mock}" != "realserver" && -z "${CNCSTR:-}" ]]; then
        if [[ "$("${NODE_BIN}" "${ENGINE}" requires-java)" == "true" ]]; then
            command -v java >/dev/null 2>&1 \
                || die "test: ci-config requires java (CouchbaseMock.jar backend) but 'java' is not on PATH"
        fi
    fi

    local prebuild_dir
    prebuild_dir="$(_test_prebuild_dir)"
    log "test: using local prebuilds from ${prebuild_dir} (no compilation)"
    # Replace rather than append: the vendor may retry `test` in the SAME workspace
    # (scripted-build-pipeline.groovy wraps it in retryWithBackoff), and a blind >> would
    # stack a duplicate key every attempt. `|| true` because grep -v exits 1 when it
    # filters out every line, which -e would treat as fatal.
    if [[ -f .npmrc ]]; then
        { grep -v '^couchbase_local_prebuilds=' .npmrc || true; } >.npmrc.cbci
        mv .npmrc.cbci .npmrc
    fi
    echo "couchbase_local_prebuilds=${prebuild_dir}" >>.npmrc

    log "installing dependencies (npm ci --ignore-scripts)"
    "${NPM_BIN}" ci --ignore-scripts

    log "installing mocha-multi-reporters for test reporting"
    "${NPM_BIN}" install --no-save mocha-multi-reporters || true

    log "installing the prebuilt binary (npm run install)"
    "${NPM_BIN}" run install
    _assert_prebuild_installed

    if [[ -n "${CBCI_JUNIT_DIR:-}" ]]; then
        mkdir -p "${CBCI_JUNIT_DIR}"
    fi

    local -a cmds=()
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && cmds+=("${line}")
    done < <("${NODE_BIN}" "${ENGINE}" test-cmds)
    [[ ${#cmds[@]} -gt 0 ]] || die "test: no test commands configured"

    local cmd rc=0
    for cmd in "${cmds[@]}"; do
        local run_cmd="${cmd}"
        if [[ "${cmd}" == *"npm run test"* || "${cmd}" == *"mocha"* ]]; then
            if [[ "${cmd}" != *"-R"* && "${cmd}" != *"--reporter"* ]]; then
                run_cmd="${cmd} -- -R mocha-multi-reporters"
            fi
        fi
        log "test: run: ${run_cmd}"
        eval "${run_cmd}" || rc=$?
    done

    if [[ -f xunit.xml && -n "${CBCI_JUNIT_DIR:-}" ]]; then
        mv -f xunit.xml "${CBCI_JUNIT_DIR}/xunit.xml"
        log "test: moved xunit.xml -> ${CBCI_JUNIT_DIR}/xunit.xml"
    fi

    [[ "${rc}" -eq 0 ]] || die "test: mocha failed (rc=${rc})"
    log "test: OK"
}

# --- package: turn the aggregated prebuilds into optional-dependency packages, list them
# in the main package.json, and repack the tarball.
#
# Runs ONCE on an orchestration node, not per build unit. PROJECT_ROOT is the UNPACKED
# sdist tarball the build already validated, with EVERY unit's prebuilds dropped into
# prebuilds/ beside it. Each prebuild becomes the package scripts/prebuilds.js resolves at
# install time:
#
#   prebuilds/couchbase-<platform>-<arch>-<runtime>/
#     couchbase-v<ver>-<runtime>-v<abi>-<platform>-<arch>-<ssl>.node
#     index.js  package.json  README.md
#
# The three name tokens come from the PREBUILD FILENAME, never from CBCI_BUILD_*. This task
# sees many units at once, and the filename already carries node's own vocabulary
# (darwin/win32/linuxmusl) that resolvePrebuild() matches on; CBCI_BUILD_PLATFORM/_LIBC
# speak the neutral plan's vocabulary (macos/windows/alpine/manylinux), which resolves to
# nothing and would leave every consumer compiling from source.
#
# index.js is load-bearing, not filler: resolvePrebuild() finds the package through
# require.resolve(<name>), so one with no resolvable entry point is invisible even when
# correctly installed. The .node sits at the package ROOT because the resolver reads the
# directory require.resolve landed in.
_package_platform_tokens() {
    local base="$1"
    local -a tokens
    IFS='-' read -ra tokens <<<"${base}"
    local n="${#tokens[@]}"
    (( n >= 7 )) || die "package: unexpected prebuild name '${base}' (${n} tokens, expected at least 7)"
    # Indexed from the END: a prerelease version ('4.8.0-dev.1') adds a token at the front
    # and would shift every forward index.
    printf '%s %s %s\n' "${tokens[n-3]}" "${tokens[n-2]}" "${tokens[n-5]}"
}

task_package() {
    cd "${PROJECT_ROOT}"
    local out
    out="$("${NODE_BIN}" "${ENGINE}" publish-env)" || die "failed to resolve publish-env"
    # shellcheck disable=SC2086,SC2163
    export ${out}

    local pkg_name; pkg_name="$("${NODE_BIN}" -p "require('${PROJECT_ROOT}/package.json').name")"
    # getSupportedPlatformPackages() throws for any other name, so a rename upstream must
    # fail here rather than produce packages nothing will ever resolve.
    [[ "${pkg_name}" == "couchbase" ]] \
        || die "package: platform packages are only defined for package name 'couchbase' (got '${pkg_name}')"

    local prebuild_dir="${PROJECT_ROOT}/prebuilds"
    compgen -G "${prebuild_dir}/*.node" >/dev/null \
        || die "package: no *.node under ${prebuild_dir} (run prebuild, or copy its artifacts, first)"

    # Inherited verbatim so a platform package carries the same provenance as the main
    # package and cannot drift from it.
    local plat_orig="${prebuild_dir}/platPkgOrig.json"
    "${NODE_BIN}" -e '
      const fs = require("fs");
      const keep = ["version", "bugs", "homepage", "license", "repository"];
      const pkg = JSON.parse(fs.readFileSync(process.argv[1]));
      const out = Object.fromEntries(Object.entries(pkg).filter(([k]) => keep.includes(k)));
      fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 2));
    ' "${PROJECT_ROOT}/package.json" "${plat_orig}"

    local -a opt_deps=()
    local f base platform arch runtime os_platform subname subdir description
    for f in "${prebuild_dir}"/*.node; do
        base="$(basename "${f}")"
        read -r platform arch runtime <<<"$(_package_platform_tokens "${base}")"

        # Electron prebuilds ship via the snapshots bucket, not npm.
        if [[ "${runtime}" == "electron" && "${CBCI_PUBLISH_ELECTRON_NPM}" != "true" ]]; then
            log "package: skipping electron prebuild ${base} (CBCI_PUBLISH_ELECTRON_NPM=false)"
            continue
        fi

        # npm matches `os` against process.platform, which has no musl spelling; the libc
        # distinction stays in the package NAME, where the resolver looks for it.
        os_platform="${platform}"
        [[ "${platform}" == *musl* ]] && os_platform="linux"

        subname="${pkg_name}-${platform}-${arch}-${runtime}"
        subdir="${prebuild_dir}/${subname}"
        description="Couchbase Node.js SDK platform specific binary for ${runtime} runtime on ${platform} OS with ${arch} architecture."

        rm -rf "${subdir}"; mkdir -p "${subdir}"
        "${NODE_BIN}" -e '
          const fs = require("fs");
          const pkg = JSON.parse(fs.readFileSync(process.argv[1]));
          pkg.name = process.argv[2];
          pkg.os = [process.argv[3]];
          pkg.cpu = [process.argv[4]];
          pkg.description = process.argv[5];
          pkg.engines = { node: ">=16" };
          fs.writeFileSync(process.argv[6], JSON.stringify(pkg, null, 2));
        ' "${plat_orig}" "@${pkg_name}/${subname}" "${os_platform}" "${arch}" "${description}" "${subdir}/package.json"

        mv "${f}" "${subdir}/"
        : > "${subdir}/index.js"
        printf '%s\n' "${description}" > "${subdir}/README.md"
        opt_deps+=("@${pkg_name}/${subname}")
        log "package: ${subname} <- ${base}"
    done

    rm -f "${plat_orig}"
    (( ${#opt_deps[@]} > 0 )) || die "package: no platform packages were built"

    # What makes a plain `npm install couchbase` resolve a prebuilt binary. Injected here
    # rather than committed, so the list always matches the prebuilds THIS release produced.
    "${NODE_BIN}" -e '
      const fs = require("fs");
      const pkgPath = process.argv[1];
      const pkg = JSON.parse(fs.readFileSync(pkgPath));
      const deps = {};
      for (const name of process.argv.slice(2)) { deps[name] = pkg.version; }
      pkg.optionalDependencies = deps;
      fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2));
    ' "${PROJECT_ROOT}/package.json" "${opt_deps[@]}"

    # Repacked AFTER the rewrite: the tarball npm serves is what carries
    # optionalDependencies, so a tarball packed before this point advertises no platform
    # packages at all and every consumer install falls through to a source build.
    #
    # --ignore-scripts is deliberate. PROJECT_ROOT here is the UNPACKED sdist that the
    # build already validated, so dist/ is built and the CPM cache is baked in; re-running
    # prepare would rebuild it from sources the tarball does not even carry, and could
    # produce different bytes than the ones that were tested. prebuilds/ is not in the
    # package's `files`, so the platform packages assembled above stay out of the tarball.
    log "package: repacking sdist with ${#opt_deps[@]} optionalDependencies"
    rm -rf sdist; mkdir -p sdist
    "${NPM_BIN}" pack --ignore-scripts --pack-destination sdist

    local repacked; repacked="$(ls sdist/*.tgz 2>/dev/null | head -1 || true)"
    [[ -n "${repacked}" ]] || die "package: npm pack produced no tarball"

    # Read back out of the tarball rather than trusting the rewrite: the packed
    # package.json is the only copy consumers ever see, and a `files`/pack quirk that
    # dropped the field would otherwise surface as a silent source build months later.
    local packed_count
    packed_count="$(tar -xzOf "${repacked}" package/package.json \
        | "${NODE_BIN}" -p "Object.keys(JSON.parse(require('fs').readFileSync(0)).optionalDependencies || {}).length")"
    (( packed_count == ${#opt_deps[@]} )) \
        || die "package: ${repacked} lists ${packed_count} optionalDependencies, expected ${#opt_deps[@]}"

    log "package: ${repacked} ready (${packed_count} platform packages)"
    ls -alh "${prebuild_dir}"
}

# --- docs: typedoc API docs. typedoc LOADS the module, so the host needs a binary it can
# require; the matching prebuild is copied into build/Release, which is where install.js
# would have put it.
task_docs() {
    cd "${PROJECT_ROOT}"
    local host_plat host_arch prebuild
    host_plat="$(_node_platform)"
    host_arch="$(_node_arch)"
    # Searched in both layouts: package may or may not have run yet, and it MOVES the
    # prebuilds down into their per-platform directories.
    prebuild="$(ls "prebuilds/${host_plat}"*/*-napi-*-"${host_plat}"-"${host_arch}"-*.node \
                   prebuilds/*/*-napi-*-"${host_plat}"-"${host_arch}"-*.node \
                   prebuilds/*-napi-*-"${host_plat}"-"${host_arch}"-*.node 2>/dev/null | head -1 || true)"
    [[ -n "${prebuild}" ]] \
        || die "docs: no napi prebuild matching this host (${host_plat}/${host_arch}) under prebuilds/"

    log "docs: loading ${prebuild}"
    "${NPM_BIN}" ci --ignore-scripts
    mkdir -p build/Release
    cp "${prebuild}" build/Release/
    "${NPM_BIN}" run build-docs
    [[ -d docs ]] || die "docs: 'npm run build-docs' produced no docs/ directory"
    rm -rf build
    log "docs: ready at ${PROJECT_ROOT}/docs"
}

# --- publish: npm publish the platform packages, then the main tarball.
#
# Credentials are npm's OWN (a registry auth token the vendor puts in .npmrc, or
# NPM_TOKEN/NODE_AUTH_TOKEN); this task never reads them, which is what keeps it callable
# unchanged from a non-Jenkins runner.
#
# The MAIN package is published as the repacked TARBALL, not from the working tree, so the
# bytes that go to the registry are exactly the ones `package` verified. Publishing a
# tarball also skips the prepare/prepack lifecycle, which would otherwise re-run tsc and
# could produce a different artifact than the one that was checked.
task_publish() {
    cd "${PROJECT_ROOT}"
    local out
    out="$("${NODE_BIN}" "${ENGINE}" publish-env)" || die "failed to resolve publish-env"
    # shellcheck disable=SC2086,SC2163
    export ${out}

    if [[ "${CBCI_PUBLISH_NPM}" != "true" ]]; then
        log "publish: CBCI_PUBLISH_NPM=false, nothing to publish"
        return 0
    fi

    local -a flags=(--access public)
    [[ -n "${CBCI_NPM_TAG:-}" ]] && flags+=(--tag "${CBCI_NPM_TAG}")
    if [[ "${CBCI_PUBLISH_DRY_RUN}" == "true" ]]; then
        flags+=(--dry-run)
        log "publish: DRY RUN, nothing will reach the registry"
    fi

    # Platform packages go FIRST: once the main package is live, `npm install couchbase`
    # starts resolving optionalDependencies that must already exist.
    local d name
    for d in "${PROJECT_ROOT}"/prebuilds/*/; do
        [[ -f "${d}/package.json" ]] || continue
        name="$("${NODE_BIN}" -p "require('${d}/package.json').name")"
        log "publish: ${name}"
        ( cd "${d}" && "${NPM_BIN}" publish "${flags[@]}" )
    done

    local tarball; tarball="$(ls "${PROJECT_ROOT}"/sdist/*.tgz 2>/dev/null | head -1 || true)"
    [[ -n "${tarball}" ]] || die "publish: no tarball under sdist/ (run package first)"
    log "publish: main package ${tarball}"
    "${NPM_BIN}" publish "${tarball}" "${flags[@]}"
    log "publish: done"
}

# --- dispatch ----------------------------------------------------------------

main() {
    local stage="${1:-}"
    [[ -n "${stage}" ]] || die "usage: tasks.sh <stage> [args...]"

    # Optional artifact log (CBCI_LOG_FILE): tee this stage's whole run to a file the
    # vendor CI uploads as an artifact. Re-exec through tee once, guarded against
    # recursion. Skip internal hooks (_*): they run nested inside another stage.
    if [[ -n "${CBCI_LOG_FILE:-}" && -z "${CBCI_LOG_TEEING:-}" && "${stage}" != _* ]]; then
        mkdir -p "$(dirname "${CBCI_LOG_FILE}")"
        CBCI_LOG_TEEING=1 bash "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "${CBCI_LOG_FILE}"
        exit "${PIPESTATUS[0]}"
    fi

    shift || true
    case "${stage}" in
        display-info|display_info) task_display_info "$@" ;;
        lint)                      task_lint "$@" ;;
        sdist)                     task_sdist "$@" ;;
        prebuild)                  task_prebuild "$@" ;;
        validate)                  task_validate "$@" ;;
        test)                      task_test "$@" ;;
        package)                   task_package "$@" ;;
        docs)                      task_docs "$@" ;;
        publish)                   task_publish "$@" ;;
        _prebuild_repair)          task__prebuild_repair "$@" ;;
        build-info-pack)           task_build_info_pack "$@" ;;
        *) die "unknown stage: ${stage}" ;;
    esac
}

main "$@"
