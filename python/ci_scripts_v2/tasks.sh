#!/usr/bin/env bash
#
# tasks.sh - POSIX (Linux/macOS) task executors for the Couchbase Python SDK.
#
# The vendor pipeline invokes:  ./tasks.sh <stage> [args...]
# Stages are the portable unit; orchestration/parallelism/archiving belong to the
# vendor. engine.py owns config -> plan; tasks.sh owns "do the work for one unit".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ENGINE="${SCRIPT_DIR}/engine.py"
PYTHON="${CBCI_PYTHON:-python3}"

# Project root = where the SDK checkout lives (consumer cwd by default).
PROJECT_ROOT="${CBCI_PROJECT_ROOT:-$(pwd -P)}"

log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [tasks] $*"; }
die() { echo "[tasks] ERROR: $*" >&2; exit 1; }

# --- shared helpers ----------------------------------------------------------

# Resolve CBCI_* project facts from engine.py and export them into this shell:
#   CBCI_PROJECT_PREFIX, CBCI_VERSION_SCRIPT, CBCI_IS_PURE_PYTHON, CBCI_USE_UV
load_project_env() {
    local out
    out="$("${PYTHON}" "${ENGINE}" project-env)" || die "failed to resolve project env"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${out}
}

# Run python, routing through `uv run` when uv is the active toolchain.
run_python() {
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv run python "$@"
    else
        "${PYTHON}" "$@"
    fi
}

# Tag the release version (if CBCI_VERSION is set) and stamp the client version.
# Requires load_project_env first, and PROJECT_ROOT as cwd (the version script reads
# git tags).
set_client_version() {
    [[ -n "${CBCI_VERSION_SCRIPT:-}" ]] || die "CBCI_VERSION_SCRIPT unset (call load_project_env)"
    [[ -f "${CBCI_VERSION_SCRIPT}" ]] || die "missing ${CBCI_VERSION_SCRIPT}; confirm checkout completed"

    local version="${CBCI_VERSION:-}"
    if [[ -n "${version}" ]]; then
        log "tagging client version ${version}"
        git config user.name "Couchbase SDK Team"
        git config user.email "sdk_dev@couchbase.com"
        git tag -a "${version}" -m "Release of client version ${version}"
        git tag --sort=-version:refname | head -n 10
    fi

    if [[ "${CBCI_IS_PURE_PYTHON:-false}" == "true" ]]; then
        # pure-python (analytics) updates pyproject.toml via tomli/tomli-w.
        run_python "${CBCI_VERSION_SCRIPT}" --mode make --update-pyproject
    else
        run_python "${CBCI_VERSION_SCRIPT}" --mode make
    fi
}

# Optionally re-point the bundled C++ core (couchbase-cxx-client) at a PR/branch/sha/
# tag, or cherry-pick a commit, BEFORE the CPM cache is baked into the sdist. One typed
# env var so it maps to a SINGLE vendor input. The vendor decides WHEN to expose it (GHA
# only on manual dispatch, say); the core just acts when it is set:
#   CBCI_CXX_CHANGE=PR_<n>                            fetch + checkout a core PR
#                  =BR_<name> | SHA_<sha> | TAG_<t> | REF_<r>   fetch + checkout (one path:
#                                                    branch/tag/sha are all a committish)
#                  =CP_<sha>                          cherry-pick a commit ONTO the pinned ref
# Core dir defaults to deps/couchbase-cxx-client (override: CBCI_CXX_DIR).
# NOTE: assumes the build uses the LOCAL core checkout (the submodule). If PYCBC's CMake
# instead CPM-fetches the core by a pinned tag, this needs revisiting; verify against a
# real PYCBC build.
handle_cxx_change() {
    local change="${CBCI_CXX_CHANGE:-}"
    [[ -n "${change}" ]] || return 0

    local type="${change%%_*}" value="${change#*_}"
    [[ "${change}" == *_* && -n "${value}" ]] \
        || die "CBCI_CXX_CHANGE='${change}' must be <TYPE>_<value> (PR_/BR_/SHA_/TAG_/REF_/CP_)"

    local dir="${CBCI_CXX_DIR:-deps/couchbase-cxx-client}"
    if [[ ! -e "${dir}/.git" ]]; then
        log "cxx-change: initializing core submodule ${dir}"
        git submodule update --init --recursive "${dir}" \
            || die "cxx-change: cannot init core submodule at ${dir}"
    fi
    [[ -d "${dir}" ]] || die "cxx-change: core dir not found: ${dir}"

    log "cxx-change: ${type} -> ${value} (in ${dir})"
    (
        cd "${dir}"
        case "${type}" in
            PR)
                git fetch origin "pull/${value}/head:cbci_cxx_pr"
                git checkout cbci_cxx_pr ;;
            BR|SHA|TAG|REF)
                # branch/tag/sha are all a committish -> fetch the exact ref into
                # FETCH_HEAD and detach onto it (GitHub allows reachable-SHA fetch).
                git fetch origin "${value}"
                git checkout --detach FETCH_HEAD ;;
            CP)
                # cherry-pick a commit on TOP of the pinned ref (no checkout switch).
                git fetch origin "${value}" 2>/dev/null || git fetch origin
                git cherry-pick "${value}" ;;
            *)
                die "cxx-change: unknown type '${type}' (PR|BR|SHA|TAG|REF|CP)" ;;
        esac
        git --no-pager log --oneline -n 5
    ) || die "cxx-change: failed to apply ${change}"
}

# Install the base build toolchain (pip path) or sync the uv env.
install_build_toolchain() {
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv sync --locked --no-group sphinx
    else
        "${PYTHON}" -m pip install --upgrade pip setuptools wheel
    fi
}

# --- stages ------------------------------------------------------------------

task_display_info() {
    log "project=${CBCI_PROJECT_TYPE:-} sha=${CBCI_SHA:-} version=${CBCI_VERSION:-}"
    log "use_uv=${CBCI_USE_UV:-} config_override=${CBCI_CONFIG_OVERRIDE:-}"
    "${PYTHON}" "${ENGINE}" validate-config
}

task_lint() {
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_USE_UV}" == "true" ]]; then
        uv sync --locked --no-group sphinx
    else
        "${PYTHON}" -m pip install --upgrade pip setuptools wheel
        # analytics (pure-python) carries its dev deps separately.
        if [[ "${CBCI_IS_PURE_PYTHON}" == "true" && -f requirements-dev.txt ]]; then
            "${PYTHON}" -m pip install -r requirements-dev.txt
        fi
        [[ -f requirements.txt ]] && "${PYTHON}" -m pip install -r requirements.txt
        # Unpinned by default: latest is right wherever the toolchain is current. A vendor
        # whose agents lag (pre-commit's git floor moves) sets CBCI_PRE_COMMIT_VERSION.
        "${PYTHON}" -m pip install "pre-commit${CBCI_PRE_COMMIT_VERSION:+==${CBCI_PRE_COMMIT_VERSION}}"
    fi

    # Install deps first, THEN stamp the version: the EA/analytics client mutates
    # pyproject.toml during versioning, so the toolchain must already be present.
    set_client_version

    log "running pre-commit"
    if [[ "${CBCI_USE_UV}" == "true" ]]; then
        uv run pre-commit run --all-files
    else
        pre-commit run --all-files
    fi
}

task_sdist() {
    load_project_env
    cd "${PROJECT_ROOT}"

    log "installing build toolchain"
    install_build_toolchain

    # Export {PREFIX}_* build knobs that setup.py reads (e.g. PYCBC_SET_CPM_CACHE).
    local build_env
    build_env="$("${PYTHON}" "${ENGINE}" build-env sdist)" || die "failed to resolve sdist build-env"
    log "sdist build-env: ${build_env}"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${build_env}

    if [[ "${CBCI_IS_PURE_PYTHON}" != "true" ]]; then
        # Re-point the C++ core (PR/branch/sha/cherry-pick) BEFORE baking the CPM cache.
        handle_cxx_change
        log "configuring C++ core CPM cache (baked into the sdist)"
        run_python setup.py configure_ext
        rm -rf ./build
    fi

    set_client_version

    log "building source distribution"
    run_python setup.py sdist
    log "dist contents:"
    ls -alh dist
}

# --- image: build the thin manylinux/musllinux image on demand ----------------
#
# The thin image is built per-run rather than hosted in a registry. Its DEFINITION lives
# HERE, in the emit_dockerfile heredocs rather than a fetched file, so the bootstrap
# manifest stays fixed: growth lives inside existing manifest files, not new ones. Per
# CONVENTIONS.md, the vendor ADAPTER owns WHICH image/tag (CBCI_IMAGE) and the core owns
# HOW to build it.

# Emit the Dockerfile for a libc family on stdout. Arch is parameterized via
# `ARG BASE_IMAGE` (Docker allows ARG before FROM) so one template serves both x86_64 and
# aarch64. The heredocs are quoted so the body stays literal: the Dockerfile-level
# `${PATH}` reference must reach Docker verbatim, NOT be expanded by this shell.
emit_dockerfile() {
    local family="$1"
    case "${family}" in
        manylinux2014)
            cat <<'DOCKERFILE'
# Thin manylinux2014 image: stock pypa base + Couchbase toolchain layer.
# Generated by `tasks.sh image` (single source of truth).
# manylinux2014 == glibc 2.17 (CentOS 7 base), so the wheel stays installable on
# CentOS 7 / Amazon Linux 2, which manylinux_2_28 (glibc 2.28) drops.
# BASE_IMAGE is always supplied via --build-arg (arch-specific); the default just
# documents the shape and silences BuildKit's empty-FROM lint.
ARG BASE_IMAGE=quay.io/pypa/manylinux2014_x86_64:latest
FROM ${BASE_IMAGE}

# Toolchain layer. The CentOS 7 base (manylinux2014) uses yum + SCL devtoolset. The
# stock manylinux2014 image already ships devtoolset-10 (GCC 10) as the default
# compiler on PATH, so no gcc-toolset downgrade is needed here: the GCC-12/13
# -Werror=stringop-overflow BoringSSL issue that forced gcc-toolset-10 on the
# manylinux_2_28 (AlmaLinux 8) image does not arise on GCC 10.
#   * perl-IPC-Cmd: OpenSSL's Configure dep (CIBW_BEFORE_ALL builds OpenSSL from
#     source), installed via yum for the openssl-backend path.
RUN yum install -y perl-IPC-Cmd \
    && yum clean all

# Pin CMake < 4.0 (same rationale as before): 4.0 dropped cmake_minimum_required
# (<3.5) compat that the C++ core's CPM deps still need. setup.py only pip-installs
# cmake<4 when NONE is on PATH, so re-pin the pipx cmake.
ARG CMAKE_VERSION=3.31.*
RUN pipx install --force "cmake==${CMAKE_VERSION}" \
    && cmake --version
DOCKERFILE
            ;;
        musllinux_1_2)
            cat <<'DOCKERFILE'
# Thin musllinux_1_2 image: stock pypa Alpine base + Couchbase toolchain layer.
# Generated by `tasks.sh image` (single source of truth).
# BASE_IMAGE is always supplied via --build-arg; the default documents the shape
# (musllinux is x86_64-only today) and silences BuildKit's empty-FROM lint.
ARG BASE_IMAGE=quay.io/pypa/musllinux_1_2_x86_64:latest
FROM ${BASE_IMAGE}

# build-base = gcc, g++, make, musl-dev, binutils (the Alpine base lacks g++). No
# gcc-toolset dance (no -Werror=stringop-overflow toolset needed); Alpine's perl
# already ships IPC::Cmd, so no perl fix is required.
RUN apk add --no-cache build-base

# Pin CMake < 4.0 (same rationale as manylinux).
ARG CMAKE_VERSION=3.31.*
RUN pipx install --force "cmake==${CMAKE_VERSION}" \
    && cmake --version
DOCKERFILE
            ;;
        *) die "emit_dockerfile: unsupported family: ${family}" ;;
    esac
}

task_image() {
    # Build-unit dimensions come from the env the adapter sets per unit (the same
    # CBCI_BUILD_* vars task_wheel reads). macOS/Windows build on the host, so no image.
    local platform="${CBCI_BUILD_PLATFORM:-linux}"
    case "${platform}" in
        macos|windows)
            log "image: ${platform} builds on the host, no container image needed"
            return 0 ;;
    esac

    # libc family. CBCI_BUILD_LIBC wins; else derive from platform (alpine is musllinux).
    local libc="${CBCI_BUILD_LIBC:-}"
    if [[ -z "${libc}" ]]; then
        [[ "${platform}" == "alpine" ]] && libc="musllinux" || libc="manylinux"
    fi
    local family
    case "${libc}" in
        manylinux) family="manylinux2014" ;;
        musllinux) family="musllinux_1_2" ;;
        *) die "image: unsupported libc: ${libc} (manylinux|musllinux)" ;;
    esac

    # arch: normalized name + docker --platform.
    local arch="${CBCI_BUILD_ARCH:-}"
    if [[ -z "${arch}" ]]; then
        case "$(uname -m)" in arm64|aarch64) arch="aarch64" ;; *) arch="x86_64" ;; esac
    fi
    local docker_platform
    case "${arch}" in
        x86_64)        docker_platform="linux/amd64" ;;
        arm64|aarch64) arch="aarch64"; docker_platform="linux/arm64" ;;
        *) die "image: unsupported arch: ${arch} (x86_64|aarch64)" ;;
    esac

    # musllinux is x86_64-only in the support matrix today (no musl-arm).
    [[ "${family}" == "musllinux_1_2" && "${arch}" != "x86_64" ]] \
        && die "image: musllinux is x86_64-only in the support matrix (got ${arch})"

    # Tag: adapter-provided CBCI_IMAGE wins. It is the SAME ref the adapter later feeds to
    # CBCI_{MANYLINUX,MUSLLINUX}_*_IMAGE for the wheel step, so one ref covers build and
    # consume. Otherwise a deterministic local default.
    local image="${CBCI_IMAGE:-couchbase/pycbc-ci-${family}_${arch}:local}"

    # A tag is mutable (`latest` moves whenever pypa publishes); a digest is not. Accept
    # either through the SAME var, since the caller that wants to reproduce an old build has
    # a digest and the caller that just wants to build has a tag: a value starting with
    # sha256: is joined with '@' (digest form), anything else with ':' (tag form).
    local base_ref="${CBCI_BASE_IMAGE_TAG:-latest}" base_image
    case "${base_ref}" in
        sha256:*) base_image="quay.io/pypa/${family}_${arch}@${base_ref}" ;;
        *)        base_image="quay.io/pypa/${family}_${arch}:${base_ref}" ;;
    esac

    # Empty build context: the Dockerfile COPYs nothing, so don't ship cwd (the SDK
    # checkout) to the daemon. Feed the Dockerfile via stdin (`-f -`).
    local ctx; ctx="$(mktemp -d)"
    log "building ${image} (${docker_platform}) from ${base_image}"
    emit_dockerfile "${family}" | docker build \
        --platform "${docker_platform}" \
        --build-arg "BASE_IMAGE=${base_image}" \
        ${CBCI_CMAKE_VERSION:+--build-arg "CMAKE_VERSION=${CBCI_CMAKE_VERSION}"} \
        -t "${image}" -f - "${ctx}"
    rmdir "${ctx}"
    log "image ready: ${image}"

    # Record what actually built this unit. Two things here are NOT pinned by the SDK sha:
    # the base image (`latest` moves) and, on musllinux, the compiler itself, since
    # `apk add build-base` resolves live against Alpine's repos. So this file does not make
    # the image reproducible; it makes the image IDENTIFIABLE, which is what a later
    # investigation needs to decide whether reproducing a release build is even plausible.
    # base_digest is the actionable line: feed it back as CBCI_BASE_IMAGE_TAG.
    # Diagnostics must never fail a build, hence the fallbacks.
    local info_dir="${PROJECT_ROOT}/wheelhouse/build-info"
    local info="${info_dir}/${family}_${arch}.txt"
    mkdir -p "${info_dir}"

    # Collected into vars first, NOT inline as `$(docker ... || echo unknown)`: docker prints
    # an empty line to stdout AND exits non-zero when an image is missing, so the `||` form
    # yields a two-line "\nunknown" and corrupts the key=value file. `head -1` plus a
    # :- default normalizes both the empty and the multi-line case.
    local base_digest image_id compiler
    base_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' \
                   "${base_image}" 2>/dev/null | head -1)"
    image_id="$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null | head -1)"
    compiler="$(docker run --rm --platform "${docker_platform}" "${image}" \
                sh -c 'gcc --version 2>/dev/null | head -1' 2>/dev/null | head -1)"
    {
        echo "family=${family}"
        echo "arch=${arch}"
        echo "docker_platform=${docker_platform}"
        echo "base_image=${base_image}"
        echo "base_digest=${base_digest:-unknown}"
        echo "image=${image}"
        echo "image_id=${image_id:-unknown}"
        echo "cmake_version_arg=${CBCI_CMAKE_VERSION:-3.31.*}"
        echo "compiler=${compiler:-unknown}"
    } > "${info}"
    while IFS= read -r info_line; do log "  build-info: ${info_line}"; done < "${info}"

    # Surface the ref + the matching var name task_wheel reads, so a LOCAL caller can
    # wire build to wheel by hand (in CI the adapter sets CBCI_IMAGE for both steps).
    local libc_uc arch_uc
    libc_uc="$(printf '%s' "${libc}" | tr '[:lower:]' '[:upper:]')"
    arch_uc="$(printf '%s' "${arch}" | tr '[:lower:]' '[:upper:]')"
    log "for the wheel step: export CBCI_${libc_uc}_${arch_uc}_IMAGE=${image}"
}

# --- wheel: cibuildwheel hooks (run inside the build env / manylinux container) ---
#
# Four constraints these hooks are built around:
#   1. The sdist-first build mounts the extracted sdist as {project}, which by design
#      carries NO CI tooling, so the hooks must NOT rely on {project}/tasks.sh. The
#      CI-core dir is bind-mounted read-only to /cbci and the hooks run from that
#      absolute path (see task_wheel).
#   2. CIBW_ENVIRONMENT does reach BEFORE_ALL, so the OpenSSL prebuild and whitelist see
#      PYCBC_USE_OPENSSL/_VERSION. The host-side gate must read USE_OPENSSL from the
#      build-env STRING, not an unexported shell var (see task_wheel).
#   3. A project-relative debug dir does NOT surface: {project} is a COPY on linux, and
#      only release wheels are copied back. The debug dir is bind-mounted WRITABLE to
#      /cbci-debug instead, with CBCI_DEBUG_WHEELHOUSE pointing there.
#   4. A usable python IS on PATH during the repair hook (the image's cp3x python);
#      _hook_python() resolves it.

OPENSSL_DIR="${CBCI_OPENSSL_DIR:-/usr/local/openssl}"

# Resolve a python usable in the current (possibly in-container) context.
_hook_python() {
    local py="${CBCI_PYTHON:-python3}"
    command -v "${py}" >/dev/null 2>&1 || py="python"
    echo "${py}"
}

# Byte size of a file (Linux container vs macOS host).
_so_size() {
    if [[ "$(uname -s)" == "Darwin" ]]; then stat -f%z "$1"; else stat -c%s "$1"; fi
}

# Debug-info state of an ELF: 0 = present, 1 = definitively absent, 2 = readelf could not
# read the file (state UNKNOWN, error text echoed on stderr).
#
# The three are distinct on purpose. Collapsing them the obvious way,
#     readelf -S "${so}" 2>/dev/null | grep -q '\.debug_info'
# misreports two of them as the third: readelf's own error is discarded by 2>/dev/null, and
# under `set -o pipefail` a `grep -q` that exits on match can SIGPIPE readelf into rc 141,
# so a SUCCESSFUL match fails the pipeline. Both surface as "no debug info", which points
# the investigation at the compiler flags instead of the tool or the ELF.
#
# Matches .zdebug_info too: --compress-debug-sections=zlib-gnu renames the section, and a
# zlib-gnu build has debug info by any useful definition.
_so_debug_info_state() {
    local so="$1" sections
    sections="$(readelf -S "${so}" 2>&1)" || {
        printf '%s\n' "${sections}" >&2
        return 2
    }
    grep -q '\.z\?debug_info' <<<"${sections}"
}

# Dump everything needed to diagnose a failed debug-symbol split, then keep going: the
# caller dies immediately after, and this is the only chance to preserve evidence.
#
# Lands in the debug wheelhouse because on linux that is the WRITABLE bind mount to the
# host (/cbci-debug); a container-local path dies with the container, and the wheel stage
# stashes nothing when it fails, so anything written elsewhere is unrecoverable without a
# full rebuild.
#
# Records the extension BEFORE repair as well as after. That comparison is the one that
# splits the two live hypotheses apart: sections present pre-repair but missing post-repair
# means auditwheel/patchelf dropped them, missing in both means the build never emitted
# them. Unpacking a second ~100MB+ wheel is why this runs only on the failure path.
_repair_diag() {
    local debug_wh="$1" stem="$2" built_wheel="$3" repaired_so="$4" py="$5"
    # A SUBDIR of the debug wheelhouse, not the wheelhouse itself. The wheel stage stashes
    # `wheelhouse/dist_debug/*`, which is FLAT: diagnostics one level down stay out of the
    # published symbol set, while a kept pre-repair wheel sitting beside the debug wheels
    # would be archived and uploaded as a release artifact by the next attempt that
    # succeeds. Pre-repair means unstripped, and on linux it also still carries the build's
    # raw linux_<arch> tag instead of the manylinux/musllinux one auditwheel assigns.
    local diag_dir="${debug_wh}/repair-diag"
    mkdir -p "${diag_dir}" || true
    local out="${diag_dir}/${stem}.repair-diag.txt"
    log "writing repair diagnostics to ${out}"

    {
        echo "=== _wheel_repair diagnostics: ${stem}"
        echo "--- host"
        uname -a || true
        readelf --version 2>&1 | head -2 || true
        echo "--- build env"
        env | grep -E "^(CBCI_|PYCBC_|AUDITWHEEL_)" | sort || true
        echo "--- post-repair extension: ${repaired_so}"
        ls -l "${repaired_so}" || true
        command -v file >/dev/null 2>&1 && file "${repaired_so}"
        echo "-- readelf -h"
        readelf -h "${repaired_so}" 2>&1 || true
        echo "-- readelf -S"
        readelf -S "${repaired_so}" 2>&1 || true
        # Build ID is the FIRST key gdb resolves separate symbols by, ahead of the
        # debuglink, so its absence changes how symbols have to be delivered.
        echo "-- readelf -n"
        readelf -n "${repaired_so}" 2>&1 || true
    } >"${out}" 2>&1 || true

    # Pre-repair comparison, best-effort: a failure to unpack the built wheel must not
    # replace the caller's real error with this one.
    {
        echo "--- pre-repair extension (from ${built_wheel})"
        local pre_dir pre_root pre_dir_so pre_file
        if pre_dir="$(mktemp -d)" \
            && "${py}" -m wheel unpack "${built_wheel}" -d "${pre_dir}" >/dev/null 2>&1 \
            && pre_root="$(find "${pre_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)" \
            && read -r pre_dir_so pre_file <<<"$(locate_core_so "${pre_root}")" \
            && [[ -n "${pre_file}" && -f "${pre_dir_so}/${pre_file}" ]]; then
            ls -l "${pre_dir_so}/${pre_file}"
            echo "-- readelf -S"
            readelf -S "${pre_dir_so}/${pre_file}" 2>&1
        else
            echo "(could not unpack/locate the pre-repair extension)"
        fi
        [[ -n "${pre_dir:-}" ]] && rm -rf "${pre_dir}"
    } >>"${out}" 2>&1 || true

    # The wheel itself, so the next investigation is a readelf away rather than a 15-minute
    # rebuild away. Opt out where the agent is tight on disk.
    if [[ "${CBCI_REPAIR_DIAG_KEEP_WHEEL:-true}" == "true" ]]; then
        if cp -f "${built_wheel}" "${diag_dir}/" 2>/dev/null; then
            log "kept the pre-repair wheel in ${diag_dir}"
        else
            log "WARNING: could not keep the pre-repair wheel in ${diag_dir}"
        fi
    fi
}

# Build OpenSSL from source into $2.
build_openssl() {
    local version="$1" dir="$2"
    local base="https://www.openssl.org/source/old" libcrypto libssl
    if [[ "${version}" == *"1.1.1"* ]]; then
        base="${base}/1.1.1"; libcrypto="${dir}/lib/libcrypto.so.1.1"; libssl="${dir}/lib/libssl.so.1.1"
    elif [[ "${version}" == *"3.0"* ]]; then
        base="${base}/3.0"; libcrypto="${dir}/lib/libcrypto.so.3"; libssl="${dir}/lib/libssl.so.3"
    elif [[ "${version}" == *"3.1"* ]]; then
        base="${base}/3.1"; libcrypto="${dir}/lib/libcrypto.so.3.1"; libssl="${dir}/lib/libssl.so.3.1"
    else
        die "cannot install OpenSSL=${version}"
    fi
    if [[ -f "${libcrypto}" && -f "${libssl}" ]]; then
        log "found prebuilt OpenSSL=${version}"
        return 0
    fi
    log "building OpenSSL=${version} -> ${dir}"
    mkdir -p /usr/src
    cd /usr/src
    curl -L -o "openssl-${version}.tar.gz" "${base}/openssl-${version}.tar.gz"
    tar -xf "openssl-${version}.tar.gz"
    mv "openssl-${version}" openssl
    cd openssl
    ./config --prefix="${dir}" --openssldir="${dir}" shared zlib
    make -j4
    make install_sw
}

# Echo "<so_dir> <so_file>" for the current project's built core extension.
# PYCBC handles the v4.6.0 (PYCBC-1745) relocation under couchbase/logic/pycbc_core.
#
# The extension's SUFFIX is build-mode dependent, so only the stem is known up front:
#   abi3 (PYCBC-1854)  -> <stem>.abi3.so
#   version-specific   -> <stem>.cpython-3XY-<plat>.so
#   pre-PYCBC-1854     -> <stem>.so
# Glob the stem and let the single match name itself rather than pinning one spelling.
# Callers MUST check the returned path is a real file: a `die` in here lands in a
# command substitution's subshell, which yields empty fields instead of exiting.
locate_core_so() {
    local root="$1" so_dir so_stem
    case "${CBCI_PROJECT_PREFIX:-PYCBC}" in
        PYCBC)
            if [[ -d "${root}/couchbase/logic/pycbc_core" ]]; then
                so_dir="${root}/couchbase/logic/pycbc_core"; so_stem="_core"
            else
                so_dir="${root}/couchbase"; so_stem="pycbc_core"
            fi
            ;;
        PYCBCC)
            so_dir="${root}/couchbase_columnar/protocol"; so_stem="pycbcc_core"
            ;;
        *) die "locate_core_so: unsupported project ${CBCI_PROJECT_PREFIX:-}" ;;
    esac

    local -a found=()
    while IFS= read -r -d '' f; do found+=("$(basename "${f}")"); done \
        < <(find "${so_dir}" -maxdepth 1 \( -name "${so_stem}.so" -o -name "${so_stem}.*.so" \) -print0 2>/dev/null | sort -z)

    if [[ ${#found[@]} -eq 0 ]]; then
        echo "[tasks] ERROR: locate_core_so: no ${so_stem}*.so under ${so_dir}" >&2
        return 1
    fi
    if [[ ${#found[@]} -gt 1 ]]; then
        echo "[tasks] ERROR: locate_core_so: expected one ${so_stem}*.so under ${so_dir}, found: ${found[*]}" >&2
        return 1
    fi
    echo "${so_dir} ${found[0]}"
}

# CIBW_BEFORE_ALL hook: prebuild OpenSSL when the unit uses it (else no-op).
task__wheel_before_all() {
    local pfx="${CBCI_PROJECT_PREFIX:-PYCBC}"
    local use_var="${pfx}_USE_OPENSSL" ver_var="${pfx}_OPENSSL_VERSION"
    if [[ "${!use_var:-OFF}" == "ON" && -n "${!ver_var:-}" ]]; then
        build_openssl "${!ver_var}" "${OPENSSL_DIR}"
    else
        log "_wheel_before_all: boringssl build, nothing to prebuild"
    fi
}

# CIBW_REPAIR_WHEEL_COMMAND hook: patched auditwheel repair (linux) + strip +
# separate-debug-wheel split. Receives {wheel} {dest_dir}. Leaves two things in the debug
# wheelhouse on Linux: the full pre-strip wheel, and a <wheel-stem>.debug companion holding
# only the symbols, which is what the release wheel's debuglink points at.
task__wheel_repair() {
    local wheel="$1" dest_dir="$2"
    local py; py="$(_hook_python)"
    local debug_wh="${CBCI_DEBUG_WHEELHOUSE:-wheelhouse/dist_debug}"
    mkdir -p "${debug_wh}" "${dest_dir}"
    # A retry re-runs this hook in the SAME workspace, so a failed attempt's diagnostics
    # would otherwise be archived next to a green build. Safe to clear: only a FAILING
    # invocation writes here, and that aborts the whole cibuildwheel run.
    rm -rf "${debug_wh}/repair-diag"
    # Absolute: the strip step runs from inside the unpacked tree, where a relative
    # wheelhouse path would resolve somewhere else entirely.
    local debug_wh_abs; debug_wh_abs="$(cd "${debug_wh}" && pwd)"
    "${py}" -m pip install -q wheel >/dev/null 2>&1 || true

    local tmp repaired wheel_stem
    tmp="$(mktemp -d)"
    if [[ "$(uname -s)" == "Linux" ]]; then
        # patched auditwheel: bundles needed libs but WHITELISTS OpenSSL (not bundled).
        "${py}" -m pip install -q auditwheel >/dev/null 2>&1 || true
        local plat="${AUDITWHEEL_PLAT:-}"
        "${py}" "${SCRIPT_DIR}/auditwheel_patch.py" repair "${wheel}" ${plat:+--plat "${plat}"} -w "${tmp}"
        repaired="$(ls "${tmp}"/*.whl | head -1)"
    else
        # macOS: the SDK links dynamically, so skip delocate and strip only.
        cp "${wheel}" "${tmp}/"
        repaired="$(ls "${tmp}"/*.whl | head -1)"
    fi

    wheel_stem="$(basename "${repaired}" .whl)"

    # Unpack the repaired wheel ONCE; BOTH wheels are packed from this same tree, so the
    # debug and release wheels share an IDENTICAL packaging code path. Whatever validates
    # the release wheel's packaging then transitively covers the debug wheel, without a
    # redundant 100MB+ install in validate.
    local unpackdir root so_dir so_file so_path pre_size post_size
    unpackdir="$(mktemp -d)"
    "${py}" -m wheel unpack "${repaired}" -d "${unpackdir}"
    root="$(find "${unpackdir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    read -r so_dir so_file <<<"$(locate_core_so "${root}")"
    so_path="${so_dir}/${so_file}"
    # Check explicitly: without it a miss falls through to the .debug_info check below and
    # reports a missing-symbols build rather than a missing extension.
    [[ -n "${so_file}" && -f "${so_path}" ]] \
        || die "_wheel_repair: could not locate the compiled extension in ${root}"

    # Pre-strip sanity: the debug .so MUST carry debug symbols, else the debug wheel
    # is pointless (build missing -g / not RelWithDebInfo?). The debug wheel is packed
    # from this pre-strip tree, so this transitively asserts it retains symbols.
    pre_size="$(_so_size "${so_path}")"
    if [[ "$(uname -s)" == "Linux" ]]; then
        local dbg_state=0
        _so_debug_info_state "${so_path}" || dbg_state=$?
        if (( dbg_state != 0 )); then
            _repair_diag "${debug_wh_abs}" "${wheel_stem}" "${wheel}" "${so_path}" "${py}"
            if (( dbg_state == 2 )); then
                die "_wheel_repair: readelf could not read ${so_path}, so the debug-info check is INCONCLUSIVE (not a verdict on the build); see repair-diag/${wheel_stem}.repair-diag.txt in the debug wheelhouse"
            fi
            die "_wheel_repair: no .debug_info in the extension AFTER repair, nothing to split; repair-diag/${wheel_stem}.repair-diag.txt in the debug wheelhouse has the pre- vs post-repair sections (both missing = build missing -g/RelWithDebInfo, post-repair only = auditwheel/patchelf dropped them)"
        fi
    fi

    # DEBUG wheel = the tree packed BEFORE stripping (full symbols). The `0debug` build tag
    # is the only thing that tells the two wheels apart: name, version and platform tags are
    # otherwise identical, so an installed debug wheel would be indistinguishable from the
    # shipped one. `wheel pack` records the tag in the tree's WHEEL and LEAVES IT THERE, so
    # it has to come back out before the release wheel is packed from this same tree.
    "${py}" -m wheel pack "${root}" -d "${debug_wh}" \
        --build-number "${CBCI_DEBUG_WHEEL_BUILD_TAG:-0debug}"
    local -a wheel_metas=( "${root}"/*.dist-info/WHEEL )
    local wheel_meta="${wheel_metas[0]}"
    [[ -f "${wheel_meta}" ]] || die "_wheel_repair: no .dist-info/WHEEL under ${root}"
    grep -v '^Build: ' "${wheel_meta}" >"${wheel_meta}.tmp" && mv "${wheel_meta}.tmp" "${wheel_meta}"
    if grep -q '^Build: ' "${wheel_meta}"; then
        die "_wheel_repair: build tag survived in WHEEL, the release wheel would inherit it"
    fi

    # Strip the .so in place, then RELEASE wheel = the SAME tree repacked.
    if [[ "$(uname -s)" == "Linux" ]]; then
        # The separated symbols are KEPT as a companion file, not discarded. The debuglink
        # records the name gdb goes looking for, so it is set to the same name the companion
        # ships under: drop <wheel-stem>.debug beside the installed .so and symbols resolve
        # with no further steps. Named for the wheel because dist_debug is flat and every
        # platform's extension has the identical filename.
        local dbg_name="${wheel_stem}.debug"
        (
            cd "${so_dir}"
            objcopy --only-keep-debug "${so_file}" "${dbg_name}"
            objcopy --strip-debug --strip-unneeded "${so_file}"
            objcopy --add-gnu-debuglink="${dbg_name}" "${so_file}"
            # Out of the tree BEFORE the release wheel is packed from it.
            mv "${dbg_name}" "${debug_wh_abs}/"
        )
        [[ -s "${debug_wh_abs}/${dbg_name}" ]] \
            || die "_wheel_repair: debug companion ${dbg_name} did not land in ${debug_wh_abs}"
    else
        ( cd "${so_dir}" && xcrun strip -Sx "${so_file}" )
    fi
    "${py}" -m wheel pack "${root}" -d "${dest_dir}"
    # The release wheel must land under the repaired wheel's exact name. Packaging drift
    # here (an inherited build tag, a rewritten local version) changes what ships and what
    # PyPI receives, and would otherwise only surface at upload.
    [[ -f "${dest_dir}/${wheel_stem}.whl" ]] \
        || die "_wheel_repair: release wheel is not ${wheel_stem}.whl (dest_dir has: $(ls "${dest_dir}"))"

    # Post-strip integrity: the RELEASE .so must be smaller, carry NO .debug_info, and
    # (Linux) keep a .gnu_debuglink back to the debug file. Fail the BUILD at the source
    # rather than discovering a broken split downstream.
    post_size="$(_so_size "${so_path}")"
    (( post_size < pre_size )) \
        || die "_wheel_repair: strip did not shrink the .so (pre=${pre_size} post=${post_size})"
    if [[ "$(uname -s)" == "Linux" ]]; then
        # Assert on the DEFINITIVELY-ABSENT state (1), not on "not present": a readelf
        # failure (2) means the strip was never verified, and the negated-pipeline spelling
        # would report that as a pass.
        local rel_state=0
        _so_debug_info_state "${so_path}" || rel_state=$?
        if (( rel_state != 1 )); then
            _repair_diag "${debug_wh_abs}" "${wheel_stem}" "${wheel}" "${so_path}" "${py}"
            if (( rel_state == 2 )); then
                die "_wheel_repair: readelf could not read the stripped ${so_path}, strip is UNVERIFIED; see repair-diag/${wheel_stem}.repair-diag.txt in the debug wheelhouse"
            fi
            die "_wheel_repair: release .so still carries .debug_info, strip failed"
        fi
        readelf -x .gnu_debuglink "${so_path}" >/dev/null 2>&1 \
            || die "_wheel_repair: release .so missing .gnu_debuglink, debuglink not added"
        log "strip integrity OK: release .so stripped + debuglink -> ${wheel_stem}.debug (${pre_size} -> ${post_size} bytes)"
    else
        log "strip integrity OK: release .so stripped (${pre_size} -> ${post_size} bytes)"
    fi
    rm -rf "${tmp}" "${unpackdir}"
}

task_wheel() {
    # cibuildwheel wrapper. Builds ONE build unit; the vendor adapter fans out across
    # units and sets the per-unit CBCI_BUILD_* env.
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_IS_PURE_PYTHON}" == "true" ]]; then
        # analytics has no C++ core, so it needs a plain build rather than cibuildwheel.
        die "wheel: pure-python build path not yet implemented"
    fi

    log "installing cibuildwheel"
    "${PYTHON}" -m pip install --upgrade pip
    "${PYTHON}" -m pip install "cibuildwheel${CBCI_CIBUILDWHEEL_VERSION:+==${CBCI_CIBUILDWHEEL_VERSION}}"

    # Build knobs the build reads (PYCBC_*). Space-free, so reuse verbatim as
    # CIBW_ENVIRONMENT to carry them INTO the build.
    local cibw_environment
    cibw_environment="$("${PYTHON}" "${ENGINE}" build-env wheel)" || die "build-env wheel failed"

    # CIBW_* selectors (values may contain spaces -> read line by line).
    local k v
    while IFS='=' read -r k v; do
        [[ -n "${k}" ]] && export "${k}=${v}"
    done < <("${PYTHON}" "${ENGINE}" wheel-env)

    # Optional verbose build (0..3, mirrors cibuildwheel): passes -v to the build
    # frontend so compiler/CMake output surfaces, which is what makes a build debuggable.
    [[ -n "${CBCI_BUILD_VERBOSITY:-}" ]] && export CIBW_BUILD_VERBOSITY="${CBCI_BUILD_VERBOSITY}"

    # Expose the CI-core scripts AND a debug-wheel output dir to the hooks WITHOUT baking
    # anything into the sdist:
    #   * the sdist-first build mounts the extracted sdist as {project}, which carries no
    #     CI tooling, so bind the CI-core dir READ-ONLY at /cbci and call hooks by that
    #     absolute path rather than through {project}.
    #   * on linux the build runs in a container where {project} is a COPY (writes do not
    #     surface) and only release wheels are copied back, so the debug wheel must land
    #     in a host-backed dir: bind it WRITABLE at /cbci-debug.
    # macos/windows run on the host with no container, so hooks use absolute host paths.
    local core_dir host_debug hook_dir
    core_dir="${CBCI_CORE_DIR:-${SCRIPT_DIR}}"
    host_debug="${PROJECT_ROOT}/wheelhouse/dist_debug"
    mkdir -p "${PROJECT_ROOT}/wheelhouse/dist" "${host_debug}"
    case "${CBCI_BUILD_PLATFORM:-}" in
        linux|alpine)
            hook_dir="/cbci"
            export CBCI_DEBUG_WHEELHOUSE="/cbci-debug"   # container-side; surfaces to host_debug
            # cibuildwheel parses "<engine>; create_args: <args>" (oci_container.py) by
            # splitting on ':', so a colon-delimited `--volume=src:dst:mode` spec gets shredded
            # into separate argv tokens (cibuildwheel 3.4.1), yielding "invalid reference
            # format" from docker. Use --mount (comma/equals, NO colons) so it survives intact.
            export CIBW_CONTAINER_ENGINE="docker; create_args: --mount type=bind,source=${core_dir},target=/cbci,readonly --mount type=bind,source=${host_debug},target=/cbci-debug"
            ;;
        *)
            hook_dir="${core_dir}"
            export CBCI_DEBUG_WHEELHOUSE="${host_debug}"
            ;;
    esac

    # OpenSSL: build it in BEFORE_ALL and re-export its location into the build. The
    # engine's USE_OPENSSL decision lives in the build-env STRING computed above and is NOT
    # exported into this shell, so detect it there. An indirect ${!PYCBC_USE_OPENSSL} read
    # would always be empty and the branch would silently never fire.
    local pfx="${CBCI_PROJECT_PREFIX}"
    if [[ " ${cibw_environment} " == *" ${pfx}_USE_OPENSSL=ON "* ]]; then
        export CIBW_BEFORE_ALL="bash ${hook_dir}/tasks.sh _wheel_before_all"
        cibw_environment="${cibw_environment} ${pfx}_OPENSSL_DIR=${OPENSSL_DIR}"
    fi
    export CIBW_ENVIRONMENT="${cibw_environment}"

    # Patched-repair + strip + debug split, invoked from the mounted CI-core dir
    # (auditwheel_patch.py resolves via tasks.sh's own SCRIPT_DIR = ${hook_dir}); the
    # debug wheel lands in CBCI_DEBUG_WHEELHOUSE (host-backed via /cbci-debug above).
    export CIBW_REPAIR_WHEEL_COMMAND="bash ${hook_dir}/tasks.sh _wheel_repair {wheel} {dest_dir}"

    # Pass CI-core facts through to the manylinux CONTAINER (repair hook reads these).
    export CIBW_ENVIRONMENT_PASS_LINUX="CBCI_PROJECT_PREFIX CBCI_DEBUG_WHEELHOUSE CBCI_PYTHON AUDITWHEEL_PLAT"

    # Custom images are resolved + provided by the vendor ADAPTER (not the core).
    [[ -n "${CBCI_MANYLINUX_X86_64_IMAGE:-}" ]]  && export CIBW_MANYLINUX_X86_64_IMAGE="${CBCI_MANYLINUX_X86_64_IMAGE}"
    [[ -n "${CBCI_MANYLINUX_AARCH64_IMAGE:-}" ]] && export CIBW_MANYLINUX_AARCH64_IMAGE="${CBCI_MANYLINUX_AARCH64_IMAGE}"
    [[ -n "${CBCI_MUSLLINUX_X86_64_IMAGE:-}" ]]  && export CIBW_MUSLLINUX_X86_64_IMAGE="${CBCI_MUSLLINUX_X86_64_IMAGE}"

    # Artifact isolation: build from the sdist (CPM cache baked in) when present.
    local target="." sdist
    sdist="$(ls dist/*.tar.gz 2>/dev/null | head -1 || true)"
    [[ -n "${sdist}" ]] && target="${sdist}"

    log "running cibuildwheel (target=${target})"
    log "  CIBW_BUILD=${CIBW_BUILD:-} CIBW_SKIP=${CIBW_SKIP:-} CIBW_ARCHS=${CIBW_ARCHS:-auto}"
    log "  CIBW_ENVIRONMENT=${CIBW_ENVIRONMENT}"
    "${PYTHON}" -m cibuildwheel --output-dir wheelhouse/dist "${target}"

    log "release wheels:"; ls -alh wheelhouse/dist
    log "debug wheels:";   ls -alh "${host_debug}" 2>/dev/null || log "  (none surfaced)"
}

task_wheel_native() {
    # NATIVE wheel build (no cibuildwheel). The vendor adapter selects this verb instead
    # of `wheel` for platforms where cibuildwheel's interpreter provisioning is unwanted
    # (Jenkins macOS/Windows). Builds ONE wheel with the on-PATH (cbdep) python, then
    # reuses task__wheel_repair for the lean release wheel and full-symbol debug wheel, so
    # strip/packaging is IDENTICAL to the cibuildwheel path. The host toolchain env
    # (MACOSX_DEPLOYMENT_TARGET/ARCHFLAGS/_PYTHON_HOST_PLATFORM, cmake/go on PATH) comes
    # from the vendor.
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_IS_PURE_PYTHON}" == "true" ]]; then
        die "wheel-native: pure-python build path not yet implemented"
    fi

    log "wheel-native: installing build deps"
    "${PYTHON}" -m pip install --upgrade pip
    "${PYTHON}" -m pip install -q wheel

    # Export the SAME PYCBC_* knobs the cibuildwheel path passes via CIBW_ENVIRONMENT, so
    # the native build is configured identically (PYCBC_USE_OPENSSL, PYCBC_BUILD_TYPE, ...).
    local build_env
    build_env="$("${PYTHON}" "${ENGINE}" build-env wheel)" || die "wheel-native: build-env wheel failed"
    log "wheel-native: build-env: ${build_env}"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of space-free KEY=VALUE pairs
    export ${build_env}

    # Build from the sdist (CPM cache baked in) when present, else the cwd checkout.
    local target="." sdist
    sdist="$(ls dist/*.tar.gz 2>/dev/null | head -1 || true)"
    [[ -n "${sdist}" ]] && target="${sdist}"

    local bdist; bdist="$(mktemp -d)"
    local -a pipargs=( "${target}" --no-deps -w "${bdist}" )
    [[ -n "${CBCI_BUILD_VERBOSITY:-}" ]] && pipargs+=( -v )
    log "wheel-native: building wheel (target=${target})"
    "${PYTHON}" -m pip wheel "${pipargs[@]}"

    # Strip + debug-split each built wheel via the shared repair hook: release -> dist,
    # full-symbol -> dist_debug. One packaging/strip code path for native + containerized.
    mkdir -p "${PROJECT_ROOT}/wheelhouse/dist"
    export CBCI_DEBUG_WHEELHOUSE="${PROJECT_ROOT}/wheelhouse/dist_debug"
    mkdir -p "${CBCI_DEBUG_WHEELHOUSE}"

    local whl found_whl=0
    for whl in "${bdist}"/*.whl; do
        [[ -e "${whl}" ]] || break
        found_whl=1
        log "wheel-native: repair+strip $(basename "${whl}")"
        task__wheel_repair "${whl}" "${PROJECT_ROOT}/wheelhouse/dist"
    done
    (( found_whl )) || die "wheel-native: pip produced no wheel in ${bdist}"

    log "wheel-native: release wheels:"; ls -alh "${PROJECT_ROOT}/wheelhouse/dist"
    log "wheel-native: debug wheels:";   ls -alh "${CBCI_DEBUG_WHEELHOUSE}" 2>/dev/null || log "  (none)"
    rm -rf "${bdist}"
}

# Create a fresh, isolated venv at $1 (uv or stdlib) with an up-to-date pip.
_make_clean_venv() {
    local venv="$1"
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv venv "${venv}" >/dev/null
    else
        "${PYTHON}" -m venv "${venv}"
    fi
    "${venv}/bin/python" -m pip install --upgrade pip >/dev/null
}

# Pick the wheel under wheelhouse/dist compatible with interpreter $1. Normally there's
# exactly one (a per-cell unstash only ever brings its own unit's wheel), but the
# copy-artifacts test-only rerun (RUN_STAGES=test + COPY_ARTIFACTS_FROM, no fresh 'build')
# fetches EVERY platform's wheel into every cell's wheelhouse/dist indiscriminately (Jenkins
# copyArtifacts has no per-cell filter), so a naive `ls | head -1` picks whatever sorts
# first alphabetically -- observed picking a macosx wheel on Linux, and even the Intel
# macosx wheel over the arm64 one on M1 ("macosx_10_15_x86_64" < "macosx_11_0_arm64").
# Rather than reimplement PEP 425/600 tag matching (manylinux vs musllinux, arm64 vs
# aarch64 spelling, abi3 floors, ...), let pip's own compatibility check be the oracle:
# try each candidate through `pip install --dry-run --no-deps` and take the first it
# accepts. --no-deps keeps this local/fast (no dependency resolution over the network).
_select_wheel() {
    local vpy="$1" whl_dir="${PROJECT_ROOT}/wheelhouse/dist"
    local -a candidates=()
    while IFS= read -r -d '' f; do candidates+=("${f}"); done \
        < <(find "${whl_dir}" -maxdepth 1 -name '*.whl' -print0 2>/dev/null | sort -z)
    [[ ${#candidates[@]} -gt 0 ]] || return 0
    if [[ ${#candidates[@]} -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi
    local w
    for w in "${candidates[@]}"; do
        if "${vpy}" -m pip install --dry-run --no-deps "${w}" >/dev/null 2>&1; then
            printf '%s\n' "${w}"
            return 0
        fi
    done
    die "install: none of ${#candidates[@]} wheels under ${whl_dir} are compatible with $("${vpy}" --version 2>&1) on this platform: ${candidates[*]}"
}

# Install the BUILT artifact (or, with CBCI_PACKAGING_INDEX, an index package) into
# venv python $1 for install type $2 (wheel|sdist). Shared by validate + test-unit.
# Installs the artifact by FILE PATH so its deps still resolve from the index. Reads
# CBCI_VALIDATE_PACKAGE / CBCI_PACKAGING_INDEX / CBCI_VERSION.
_install_built_artifact() {
    local vpy="$1" itype="$2"
    local pkg="${CBCI_VALIDATE_PACKAGE}"
    local index="${CBCI_PACKAGING_INDEX:-}"
    local -a src
    if [[ -n "${index}" ]]; then
        local index_uc; index_uc="$(printf '%s' "${index}" | tr '[:lower:]' '[:upper:]')"
        case "${index_uc}" in
            PYPI)      src=("${pkg}${CBCI_VERSION:+==${CBCI_VERSION}}") ;;
            TEST_PYPI) src=(-i https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple "${pkg}${CBCI_VERSION:+==${CBCI_VERSION}}") ;;
            *) die "install: unknown CBCI_PACKAGING_INDEX: ${index} (PYPI|TEST_PYPI)" ;;
        esac
    else
        local artifact
        case "${itype}" in
            wheel) artifact="$(_select_wheel "${vpy}")" ;;
            sdist) artifact="$(ls "${PROJECT_ROOT}"/dist/*.tar.gz 2>/dev/null | head -1 || true)" ;;
            *) die "install: unknown install_type: ${itype} (wheel|sdist)" ;;
        esac
        [[ -n "${artifact}" ]] || die "install: no ${itype} artifact found (build it first?)"
        log "  artifact: ${artifact}"
        src=("${artifact}")
    fi
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv pip install --python "${vpy}" "${src[@]}"
    else
        "${vpy}" -m pip install "${src[@]}"
    fi
}

# Smoke-check the INSTALLED package in a clean venv: import it, and (PYCBC/columnar)
# call get_metadata(detailed=True). The import proves the C extension loads + its
# dynamic deps (BoringSSL/OpenSSL) resolve; get_metadata proves it INITIALIZES and
# surfaces the SSL backend + version we assert against. Dependency-free (runs in the
# clean venv where only the SDK is installed); facts arrive via env.
_validate_smoke() {
    local vpy="$1"
    "${vpy}" - <<'PY'
import importlib, os, pprint, sys


def dump_extension_modules(mod):
    """Name the cause of a failed import: what shipped vs what this interpreter accepts.

    An extension whose FILENAME is not an importable suffix fails identically to one that
    was never built. Windows is the trap: it has no '.abi3.pyd' suffix (only '.pyd'), so a
    stable-ABI module named the POSIX way is invisible to the importer. Validate failing
    also means the run never reaches archiving, so this is the only look inside the
    artifact anyone gets.
    """
    import importlib.machinery as machinery
    import importlib.util as util
    print(f"[validate] import failed; suffixes this interpreter accepts: "
          f"{machinery.EXTENSION_SUFFIXES}", file=sys.stderr)
    try:
        roots = list(util.find_spec(mod).submodule_search_locations or [])
    except Exception as exc:
        print(f"[validate]   could not locate '{mod}' on disk: {exc!r}", file=sys.stderr)
        return
    found = 0
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for name in sorted(names):
                if os.path.splitext(name)[1].lower() in (".so", ".pyd", ".dylib"):
                    found += 1
                    rel = os.path.join(os.path.relpath(dirpath, root), name)
                    print(f"[validate]   shipped: {rel}", file=sys.stderr)
    if not found:
        print(f"[validate]   shipped: NO extension modules under {roots} "
              f"(the build produced none, or they were left out of the artifact)", file=sys.stderr)


mod = os.environ["CBCI_VALIDATE_IMPORT"]
try:
    m = importlib.import_module(mod)
except ImportError:
    dump_extension_modules(mod)
    raise
print(f"[validate] imported {mod} from {getattr(m, '__file__', '?')}")

if os.environ.get("CBCI_VALIDATE_HAS_METADATA") == "true":
    md = m.get_metadata(detailed=True)
    print("[validate] get_metadata(detailed=True):")
    pprint.pprint(md)
    blob = repr(md).lower()

    # Version: metadata formatting varies across SDK versions -> tolerant (warn).
    want_ver = (os.environ.get("CBCI_VERSION") or "").strip().lower()
    if want_ver and want_ver not in blob:
        print(f"[validate] WARNING: version '{want_ver}' not found in metadata", file=sys.stderr)

    # SSL backend: the build-correctness signal. Tolerant (warn) until the get_metadata
    # schema is confirmed against a real CI build, then promote to a hard failure.
    want_ssl = (os.environ.get("CBCI_VALIDATE_SSL") or "").strip().lower()
    if want_ssl and want_ssl not in blob:
        print(f"[validate] WARNING: expected ssl backend '{want_ssl}' not evident in metadata", file=sys.stderr)

    print("[validate] smoke OK (extension imported + initialized)")
else:
    print("[validate] smoke OK (import only)")
PY
}

task_validate() {
    # Artifact isolation: install the BUILT artifact into a clean env and smoke THAT, which
    # is what a PyPI user gets, rather than the repo source tree. Granularity is per
    # (platform, arch, python, install_type); the vendor adapter fans out and this validates
    # ONE unit. Linux/macOS here; Windows is tasks.ps1.
    load_project_env
    cd "${PROJECT_ROOT}"

    # Validate facts from the engine (install types, package/import name, ssl).
    local out
    out="$("${PYTHON}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${out}
    # Per-job fan-out: the adapter sets CBCI_INSTALL_TYPE to run ONE type per Jenkins
    # job; unset (local runs) -> all types from config.
    [[ -n "${CBCI_INSTALL_TYPE:-}" ]] && CBCI_VALIDATE_INSTALL_TYPES="${CBCI_INSTALL_TYPE}"

    local itype venvroot venv vpy
    IFS=',' read -ra _types <<<"${CBCI_VALIDATE_INSTALL_TYPES}"
    for itype in "${_types[@]}"; do
        log "validate: install_type=${itype} package=${CBCI_VALIDATE_PACKAGE} ssl=${CBCI_VALIDATE_SSL} index=${CBCI_PACKAGING_INDEX:-<local>}"
        venvroot="$(mktemp -d)"; venv="${venvroot}/venv"
        _make_clean_venv "${venv}"; vpy="${venv}/bin/python"
        _install_built_artifact "${vpy}" "${itype}"
        # Run the smoke check from a SOURCE-FREE dir: `python -` puts CWD first on
        # sys.path, and PROJECT_ROOT holds the SDK checkout, so `import couchbase` from
        # here would resolve to the (uncompiled) repo source instead of the installed
        # wheel -> ModuleNotFoundError on pycbc_core._core. venvroot has only venv/.
        ( cd "${venvroot}" && _validate_smoke "${vpy}" )
        rm -rf "${venvroot}"
        log "validate: ${itype} OK"
    done
    log "validate: all install types passed (${CBCI_VALIDATE_INSTALL_TYPES})"
}

# Build the artifact-isolation test tree from the repo source (engine.py test-setup:
# renamed API dirs + tests + conftest/pytest.ini/test_config.ini/requirements-test.txt).
# Prints ONLY the resolved tree root on stdout (callers log) so it is capture-safe. Needs
# the SDK checkout present under PROJECT_ROOT.
_build_test_tree() {
    local test_dir="$1" test_root
    rm -rf "${test_dir}"; mkdir -p "${test_dir}"
    test_root="$(run_python "${ENGINE}" test-setup "${test_dir}" | tail -1)"
    [[ -d "${test_root}" ]] || die "test-setup did not produce a tree"
    printf '%s\n' "${test_root}"
}

# Standalone: build the test tree and leave it under CBCI_TEST_DIR (default .cbci_test).
# CI does not call this. Every fan-out test node gets the SDK checkout and builds its OWN
# tree inline via task_test. This exists for local use, so a dev can build once and reuse
# the tree across repeated `tasks.sh test` invocations.
task_test_setup() {
    load_project_env
    cd "${PROJECT_ROOT}"
    local test_dir test_root
    test_dir="${CBCI_TEST_DIR:-${PROJECT_ROOT}/.cbci_test}"
    test_root="$(_build_test_tree "${test_dir}")"
    log "test-setup: test tree ready at ${test_root}"
}

task_test() {
    # Artifact isolation: run the tests against the INSTALLED artifact, not the repo
    # source. engine.py test-setup builds a test tree with the API dirs RENAMED
    # (couchbase->cb, ...) so `import couchbase` resolves to the installed wheel/sdist,
    # then pytest runs from that tree once per install_type.
    load_project_env
    cd "${PROJECT_ROOT}"

    local out
    out="$("${PYTHON}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086,SC2163
    export ${out}
    [[ -n "${CBCI_INSTALL_TYPE:-}" ]] && CBCI_VALIDATE_INSTALL_TYPES="${CBCI_INSTALL_TYPE}"

    if [[ -n "${CBCI_JUNIT_DIR:-}" ]]; then
        mkdir -p "${CBCI_JUNIT_DIR}"
    fi

    # Artifact-isolation test tree. Prefer a PRE-BUILT tree staged here (a dev ran
    # task_test_setup by hand, or CBCI_TEST_DIR already points at one); otherwise build it
    # inline from the SDK checkout CI staged under PROJECT_ROOT. The tree does not depend on
    # platform/arch/python/install_type, so building it per node is cheap and cannot drift.
    # Detected by pytest.ini at a tree root under test_dir.
    local test_dir test_root="" _cand
    test_dir="${CBCI_TEST_DIR:-${PROJECT_ROOT}/.cbci_test}"
    for _cand in "${test_dir}"/*/; do
        [[ -f "${_cand}pytest.ini" ]] && { test_root="${_cand%/}"; break; }
    done
    if [[ -n "${test_root}" ]]; then
        log "test tree: reusing pre-built ${test_root}"
    else
        test_root="$(_build_test_tree "${test_dir}")"
        log "test tree: built ${test_root}"
    fi

    # Pytest invocations from ci-config (one per API). Each line is a full
    # `pytest -m '<markers>' <opts>` command (markers contain spaces -> read by line).
    local -a cmds=()
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && cmds+=("${line}")
    done < <("${PYTHON}" "${ENGINE}" test-cmds)
    [[ ${#cmds[@]} -gt 0 ]] || die "test: no pytest commands configured"

    local itype venvroot venv vpy cmd rc
    IFS=',' read -ra _types <<<"${CBCI_VALIDATE_INSTALL_TYPES}"
    for itype in "${_types[@]}"; do
        log "test: install_type=${itype} package=${CBCI_VALIDATE_PACKAGE}"
        venvroot="$(mktemp -d)"; venv="${venvroot}/venv"
        _make_clean_venv "${venv}"; vpy="${venv}/bin/python"
        _install_built_artifact "${vpy}" "${itype}"
        # Test deps that engine.py filtered out of the repo's dev-requirements.
        "${vpy}" -m pip install -r "${test_root}/requirements-test.txt"

        # Run each unit/integration command FROM the test tree, with the venv's bin first on PATH so
        # the literal `pytest` is THIS venv's (and `import couchbase` -> the installed
        # artifact, since the tree has cb/ not couchbase/). `eval` honors the embedded
        # `-m '<markers>'` quoting; commands are CI-core config (trusted).
        rc=0
        (
            cd "${test_root}"
            export PATH="${venv}/bin:${PATH}"
            local cmd_rc=0
            local idx=1
            for cmd in "${cmds[@]}"; do
                local full_cmd="${cmd}"
                if [[ -n "${CBCI_JUNIT_DIR:-}" ]]; then
                    if [[ "${cmd}" == *"pytest"* || "${cmd}" == *"py.test"* ]]; then
                        local apiname=""
                        if [[ "${cmd}" == *"acouchbase"* ]]; then
                            apiname="acouchbase"
                        elif [[ "${cmd}" == *"txcouchbase"* ]]; then
                            apiname="txcouchbase"
                        elif [[ "${cmd}" == *"couchbase"* ]]; then
                            apiname="couchbase"
                        else
                            apiname="override-${idx}"
                        fi
                        full_cmd="${cmd} --junitxml=${CBCI_JUNIT_DIR}/junit-${apiname}.xml"
                        idx=$((idx + 1))
                    fi
                fi
                log "  run: ${full_cmd}"
                eval "${full_cmd}" || cmd_rc=$?
                if [[ ${cmd_rc} -ne 0 ]]; then
                    rc=${cmd_rc}
                fi
            done
            exit ${rc}
        ) || rc=$?
        rm -rf "${venvroot}"
        [[ "${rc}" -eq 0 ]] || die "test: ${itype} pytest failed (rc=${rc})"
        log "test: ${itype} OK"
    done
    log "test: all install types passed (${CBCI_VALIDATE_INSTALL_TYPES})"
}

# --- dispatch ----------------------------------------------------------------

task_docs() {
    load_project_env
    cd "${PROJECT_ROOT}"

    local py; py="$(_hook_python)"
    local wheel
    wheel="$(ls "${PROJECT_ROOT}"/wheelhouse/dist/*.whl 2>/dev/null | head -1 || true)"
    [[ -n "${wheel}" ]] || die "docs: no wheel found under wheelhouse/dist/ (build/unstash it first)"

    log "docs: unpacking wheel ${wheel}"
    local unpackdir
    unpackdir="$(mktemp -d)"
    "${py}" -m pip install -q wheel || true
    "${py}" -m wheel unpack "${wheel}" -d "${unpackdir}"

    local root so_dir so_file so_path
    root="$(find "${unpackdir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    read -r so_dir so_file <<<"$(locate_core_so "${root}")"
    so_path="${so_dir}/${so_file}"
    [[ -n "${so_file}" && -f "${so_path}" ]] \
        || die "docs: could not locate the compiled extension in ${root}"

    # Copy extension to the source tree at the correct subdirectory path
    local rel_so_dir="${so_dir#"${root}"/}"
    local target_so_dir="${PROJECT_ROOT}/${rel_so_dir}"
    local target_so_path="${target_so_dir}/${so_file}"

    log "docs: copying extension ${so_path} -> ${target_so_path}"
    mkdir -p "${target_so_dir}"
    cp "${so_path}" "${target_so_path}"

    # docs/conf.py calls <project>_version.py's get_version(), which reads
    # <top_package>/_version.py as TEXT (deliberately, so it never imports the package and
    # thus never loads the extension). That file is generated during the sdist build, so the
    # checkout unstashed here does not have it and sphinx dies in its config phase.
    # Take it from the wheel rather than regenerating it: the documented version is then the
    # version of the artifact being documented, by construction rather than by two
    # derivations agreeing, and the docs build needs neither a git tree nor CBCI_VERSION.
    # The top package is the first segment of the extension's path, which covers every
    # project (couchbase/logic/pycbc_core, couchbase, couchbase_columnar/protocol).
    local pkg_dir version_src
    pkg_dir="${rel_so_dir%%/*}"
    version_src="${root}/${pkg_dir}/_version.py"
    [[ -f "${version_src}" ]] \
        || die "docs: ${pkg_dir}/_version.py is not in ${wheel}; the wheel was built without a stamped version"
    log "docs: version file from the wheel: $(grep -m1 __version__ "${version_src}")"
    mkdir -p "${PROJECT_ROOT}/${pkg_dir}"
    cp "${version_src}" "${PROJECT_ROOT}/${pkg_dir}/_version.py"

    log "docs: installing sphinx dependencies"
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv pip install -r sphinx_requirements.txt
    else
        "${py}" -m pip install -r sphinx_requirements.txt
    fi

    log "docs: building documentation with sphinx"
    mkdir -p sphinx
    if [[ "${CBCI_USE_UV:-false}" == "true" ]]; then
        uv run sphinx-build -M html ./docs ./sphinx
    else
        sphinx-build -M html ./docs ./sphinx
    fi

    rm -rf "${unpackdir}"
    log "docs: build complete"
}

# Publish the built dist (dist/*.whl, dist/*.tar.gz) to PyPI or Test PyPI via twine.
# Reads CBCI_PACKAGING_INDEX (PYPI|TEST_PYPI, required -- same knob _install_built_artifact
# uses for index-install) and CBCI_VERSION (informational only here; twine reads it from the
# artifact filenames, not env). Credentials are twine's OWN env vars (TWINE_USERNAME/
# TWINE_PASSWORD), sourced by the adapter (Jenkins withCredentials, GHA secrets). This task
# never touches them directly, so it is identically callable from either vendor.
task_publish() {
    load_project_env
    cd "${PROJECT_ROOT}"

    local out
    out="$("${PYTHON}" "${ENGINE}" publish-env)" || die "failed to resolve publish-env"
    # shellcheck disable=SC2086,SC2163  # intentional word-split of KEY=VALUE pairs
    export ${out}

    local index="${CBCI_PACKAGING_INDEX:-}"
    [[ -n "${index}" ]] || die "publish: CBCI_PACKAGING_INDEX must be set (PYPI|TEST_PYPI)"

    local -a artifacts=()
    while IFS= read -r -d '' f; do artifacts+=("${f}"); done \
        < <(find "${PROJECT_ROOT}/dist" -maxdepth 1 \( -name '*.whl' -o -name '*.tar.gz' \) -print0 2>/dev/null | sort -z)
    [[ ${#artifacts[@]} -gt 0 ]] || die "publish: no dist/*.whl or dist/*.tar.gz found under ${PROJECT_ROOT}/dist (copy/build them first)"

    "${PYTHON}" -m pip show twine >/dev/null 2>&1 || "${PYTHON}" -m pip install --upgrade twine
    log "publish: checking ${#artifacts[@]} artifact(s): ${artifacts[*]}"
    "${PYTHON}" -m twine check "${artifacts[@]}"

    if [[ "${CBCI_PUBLISH_DRY_RUN:-false}" == "true" ]]; then
        log "publish: CBCI_PUBLISH_DRY_RUN=true -- check only, skipping upload"
        return 0
    fi

    local repo_url
    case "$(printf '%s' "${index}" | tr '[:lower:]' '[:upper:]')" in
        PYPI)      repo_url="https://upload.pypi.org/legacy/" ;;
        TEST_PYPI) repo_url="https://test.pypi.org/legacy/" ;;
        *) die "publish: unknown CBCI_PACKAGING_INDEX: ${index} (PYPI|TEST_PYPI)" ;;
    esac
    log "publish: uploading ${#artifacts[@]} artifact(s) to ${index} package=${CBCI_PUBLISH_PACKAGE}"
    "${PYTHON}" -m twine upload --repository-url "${repo_url}" "${artifacts[@]}"
    log "publish: done (${index})"
}

# --- dispatch ----------------------------------------------------------------

main() {
    local stage="${1:-}"
    [[ -n "${stage}" ]] || die "usage: tasks.sh <stage> [args...]"

    # Optional artifact log (CBCI_LOG_FILE): tee this stage's whole run to a file the vendor
    # CI uploads as an artifact, so it survives console truncation and can be attached to a
    # bug report or diffed across runs. Verbose-to-console (CBCI_BUILD_VERBOSITY) stays
    # primary; this is the durable copy. Re-exec through tee once, guarded against
    # recursion. Skip the in-container hooks (_wheel_*): they run where CBCI_LOG_FILE is not
    # set and must not tee.
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
        image)                     task_image "$@" ;;
        wheel)                     task_wheel "$@" ;;
        wheel-native)              task_wheel_native "$@" ;;
        validate)                  task_validate "$@" ;;
        test-setup)                task_test_setup "$@" ;;
        test)                      task_test "$@" ;;
        docs)                      task_docs "$@" ;;
        publish)                   task_publish "$@" ;;
        # internal cibuildwheel hooks (invoked by cibuildwheel, not the pipeline)
        _wheel_before_all)         task__wheel_before_all "$@" ;;
        _wheel_repair)             task__wheel_repair "$@" ;;
        *) die "unknown stage: ${stage}" ;;
    esac
}

main "$@"
