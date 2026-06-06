#!/usr/bin/env bash
#
# tasks.sh — POSIX (Linux/macOS) task executors for the Couchbase Python SDK.
#
# The vendor pipeline invokes:  ./tasks.sh <stage> [args...]
# Stages are the portable unit; orchestration/parallelism/archiving belong to the
# vendor. engine.py owns config -> plan; tasks.sh owns "do the work for one unit".
#
# Phase 1 scaffold: dispatch is real; each task is stubbed with TODOs pointing at
# the proven prototype snippets (gha/gha.sh, scripts/build-wheels.sh).

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
    # shellcheck disable=SC2086  # intentional word-split of KEY=VALUE pairs
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
# Ported from gha/gha.sh set_client_version. Requires load_project_env first and
# PROJECT_ROOT as cwd (the version script reads git tags).
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
        # TODO(Phase 4): ensure tomli/tomli-w are present for this path.
        run_python "${CBCI_VERSION_SCRIPT}" --mode make --update-pyproject
    else
        run_python "${CBCI_VERSION_SCRIPT}" --mode make
    fi
}

# Optionally re-point the bundled C++ core (couchbase-cxx-client) at a PR/branch/sha/
# tag, or cherry-pick a commit, BEFORE the CPM cache is baked into the sdist. One typed
# env var so it maps to a SINGLE vendor input (the vendor decides WHEN to expose it —
# e.g. GHA only on manual dispatch; the core just acts when it's set):
#   CBCI_CXX_CHANGE=PR_<n>                            fetch + checkout a core PR
#                  =BR_<name> | SHA_<sha> | TAG_<t> | REF_<r>   fetch + checkout (one path:
#                                                    branch/tag/sha are all a committish)
#                  =CP_<sha>                          cherry-pick a commit ONTO the pinned ref
# Core dir defaults to deps/couchbase-cxx-client (override: CBCI_CXX_DIR).
# NOTE: assumes the build uses the LOCAL core checkout (the submodule). If PYCBC's CMake
# instead CPM-fetches the core by a pinned tag, this needs revisiting — verify against a
# real PYCBC build. (Ported from gha/gha.sh handle_cxx_change, fixing its quoted-glob bug
# that meant it never fired, adding SHA/TAG/REF, and implementing the CP stub.)
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
    # TODO(Phase 1): port the env dump from gha/gha.sh display_info, but keyed on
    # the resolved engine.py config rather than the old CBCI_DEFAULT_* env soup.
    log "project=${CBCI_PROJECT_TYPE:-} sha=${CBCI_SHA:-} version=${CBCI_VERSION:-}"
    log "use_uv=${CBCI_USE_UV:-} config_override=${CBCI_CONFIG_OVERRIDE:-}"
    "${PYTHON}" "${ENGINE}" validate-config
}

task_lint() {
    # Ported from gha/gha.sh setup_and_execute_linting.
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_USE_UV}" == "true" ]]; then
        uv sync --locked --no-group sphinx
    else
        "${PYTHON}" -m pip install --upgrade pip setuptools wheel
        # analytics (pure-python) carries its dev deps separately; Phase 4.
        if [[ "${CBCI_IS_PURE_PYTHON}" == "true" && -f requirements-dev.txt ]]; then
            "${PYTHON}" -m pip install -r requirements-dev.txt
        fi
        [[ -f requirements.txt ]] && "${PYTHON}" -m pip install -r requirements.txt
        "${PYTHON}" -m pip install pre-commit
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
    # Ported from gha/gha.sh build_sdist.
    load_project_env
    cd "${PROJECT_ROOT}"

    log "installing build toolchain"
    install_build_toolchain

    # Export {PREFIX}_* build knobs that setup.py reads (e.g. PYCBC_SET_CPM_CACHE).
    local build_env
    build_env="$("${PYTHON}" "${ENGINE}" build-env sdist)" || die "failed to resolve sdist build-env"
    log "sdist build-env: ${build_env}"
    # shellcheck disable=SC2086  # intentional word-split of KEY=VALUE pairs
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
# PLAN.md §9: build the thin image per-run instead of hosting a registry. The image
# DEFINITION lives HERE (emit_dockerfile heredocs), not in a fetched file, so the
# bootstrap manifest stays fixed (CONVENTIONS §5 / PLAN §56: growth lives inside
# existing manifest files, not new ones). Division of labor (CONVENTIONS §4): the
# vendor ADAPTER owns WHICH image/tag (CBCI_IMAGE); the core owns HOW to build it.

# Emit the Dockerfile for a libc family on stdout. Arch is parameterized via
# `ARG BASE_IMAGE` (Docker allows ARG before FROM) so one template serves both
# x86_64 and aarch64. Quoted heredocs keep the body fully literal — notably the
# Dockerfile-level `${PATH}` reference must reach Docker verbatim, NOT be expanded
# by this shell. (Mirrors the proven Phase 0/0b images/ Dockerfiles, now retired.)
emit_dockerfile() {
    local family="$1"
    case "${family}" in
        manylinux_2_28)
            cat <<'DOCKERFILE'
# Thin manylinux_2_28 image: stock pypa base + Couchbase toolchain layer.
# Generated by `tasks.sh image` (single source of truth).
# BASE_IMAGE is always supplied via --build-arg (arch-specific); the default just
# documents the shape and silences BuildKit's empty-FROM lint.
ARG BASE_IMAGE=quay.io/pypa/manylinux_2_28_x86_64:latest
FROM ${BASE_IMAGE}

# Toolchain layer — AlmaLinux 8 base (manylinux_2_28) uses dnf + SCL gcc-toolset.
#   * gcc-toolset-10: the GCC-12/13 -Werror=stringop-overflow BoringSSL fix.
#   * perl-IPC-Cmd: OpenSSL's Configure dep (CIBW_BEFORE_ALL builds OpenSSL from
#     source); absent from the stock manylinux_2_28 base.
RUN dnf install -y gcc-toolset-10 perl-IPC-Cmd \
    && dnf clean all

# Make the toolset the default compiler for the build + CIBW_BEFORE_ALL.
ENV PATH=/opt/rh/gcc-toolset-10/root/usr/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/rh/gcc-toolset-10/root/usr/lib64:/opt/rh/gcc-toolset-10/root/usr/lib

# Pin CMake < 4.0: manylinux_2_28 ships CMake 4.x (via pipx); 4.0 dropped
# cmake_minimum_required(<3.5) compat that the C++ core's CPM deps still need.
# setup.py only pip-installs cmake<4 when NONE is on PATH, so re-pin the pipx cmake.
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
    # CBCI_BUILD_* vars task_wheel reads). macOS/Windows build on the host → no image.
    local platform="${CBCI_BUILD_PLATFORM:-linux}"
    case "${platform}" in
        macos|windows)
            log "image: ${platform} builds on the host — no container image needed"
            return 0 ;;
    esac

    # libc family. CBCI_BUILD_LIBC wins; else derive from platform (alpine→musllinux).
    local libc="${CBCI_BUILD_LIBC:-}"
    if [[ -z "${libc}" ]]; then
        [[ "${platform}" == "alpine" ]] && libc="musllinux" || libc="manylinux"
    fi
    local family
    case "${libc}" in
        manylinux) family="manylinux_2_28" ;;
        musllinux) family="musllinux_1_2" ;;
        *) die "image: unsupported libc: ${libc} (manylinux|musllinux)" ;;
    esac

    # arch → normalized name + docker --platform.
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

    # Tag: adapter-provided CBCI_IMAGE wins — the SAME ref it later feeds to
    # CBCI_{MANYLINUX,MUSLLINUX}_*_IMAGE for the wheel step (one ref, build→consume).
    # Else a deterministic local default.
    local image="${CBCI_IMAGE:-couchbase/pycbc-ci-${family}_${arch}:local}"
    local base_image="quay.io/pypa/${family}_${arch}:${CBCI_BASE_IMAGE_TAG:-latest}"

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

    # Surface the ref + the matching var name task_wheel reads, so a LOCAL caller can
    # wire build→wheel by hand (in CI the adapter sets CBCI_IMAGE for both steps).
    local libc_uc arch_uc
    libc_uc="$(printf '%s' "${libc}" | tr '[:lower:]' '[:upper:]')"
    arch_uc="$(printf '%s' "${arch}" | tr '[:lower:]' '[:upper:]')"
    log "for the wheel step: export CBCI_${libc_uc}_${arch_uc}_IMAGE=${image}"
}

# --- wheel: cibuildwheel hooks (run inside the build env / manylinux container) ---
#
# PHASE 0 VERIFICATION (PLAN.md §7) — spike outcomes. All CONFIRMED on
# manylinux_2_28 / aarch64 / cp311 / {boringssl,openssl}; x86_64 still TODO in CI.
#   1. RESOLVED: the sdist-first build mounts the extracted sdist as {project}, which
#      (by design) carries NO CI tooling — so the hooks must NOT rely on
#      {project}/tasks.sh. The CI-core dir is bind-mounted read-only to /cbci and the
#      hooks are invoked by that absolute path (see task_wheel).
#   2. CONFIRMED: CIBW_ENVIRONMENT reaches BEFORE_ALL (cibuildwheel linux.py applies
#      `environment` to the before_all env), so OpenSSL prebuild + whitelist see
#      PYCBC_USE_OPENSSL/_VERSION. (Host-side gate fixed: USE_OPENSSL is detected from
#      the build-env STRING, not an unexported shell var — see task_wheel.)
#   3. RESOLVED: a project-relative debug dir does NOT surface ({project} is a COPY on
#      linux + only release wheels are copied back). The debug dir is bind-mounted
#      WRITABLE to /cbci-debug instead (CBCI_DEBUG_WHEELHOUSE points there).
#   4. CONFIRMED: a usable python is on PATH during the repair hook (the manylinux
#      image's cp3x python); _hook_python() resolves it.

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

# Build OpenSSL from source into $2. Ported from gha/gha.sh build_openssl.
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
locate_core_so() {
    local root="$1"
    case "${CBCI_PROJECT_PREFIX:-PYCBC}" in
        PYCBC)
            if [[ -d "${root}/couchbase/logic/pycbc_core" ]]; then
                echo "${root}/couchbase/logic/pycbc_core _core.so"
            else
                echo "${root}/couchbase pycbc_core.so"
            fi
            ;;
        PYCBCC)
            # TODO(Phase 4): confirm PYCBCC core path / any v-relocation.
            echo "${root}/couchbase_columnar/protocol pycbcc_core.so"
            ;;
        *) die "locate_core_so: unsupported project ${CBCI_PROJECT_PREFIX:-}" ;;
    esac
}

# CIBW_BEFORE_ALL hook: prebuild OpenSSL when the unit uses it (else no-op).
task__wheel_before_all() {
    local pfx="${CBCI_PROJECT_PREFIX:-PYCBC}"
    local use_var="${pfx}_USE_OPENSSL" ver_var="${pfx}_OPENSSL_VERSION"
    if [[ "${!use_var:-OFF}" == "ON" && -n "${!ver_var:-}" ]]; then
        build_openssl "${!ver_var}" "${OPENSSL_DIR}"
    else
        log "_wheel_before_all: boringssl build — nothing to prebuild"
    fi
}

# CIBW_REPAIR_WHEEL_COMMAND hook: patched auditwheel repair (linux) + strip +
# separate-debug-wheel split. Ported from scripts/build-wheels.sh reduce_wheel_size
# and gha/gha.sh reduce_macos_wheel_size. Receives {wheel} {dest_dir}.
task__wheel_repair() {
    local wheel="$1" dest_dir="$2"
    local py; py="$(_hook_python)"
    local debug_wh="${CBCI_DEBUG_WHEELHOUSE:-wheelhouse/dist_debug}"
    mkdir -p "${debug_wh}" "${dest_dir}"
    "${py}" -m pip install -q wheel >/dev/null 2>&1 || true

    local tmp repaired
    tmp="$(mktemp -d)"
    if [[ "$(uname -s)" == "Linux" ]]; then
        # patched auditwheel: bundles needed libs but WHITELISTS OpenSSL (not bundled).
        "${py}" -m pip install -q auditwheel >/dev/null 2>&1 || true
        local plat="${AUDITWHEEL_PLAT:-}"
        "${py}" "${SCRIPT_DIR}/auditwheel_patch.py" repair "${wheel}" ${plat:+--plat "${plat}"} -w "${tmp}"
        repaired="$(ls "${tmp}"/*.whl | head -1)"
    else
        # macOS: SDK links dynamically -> skip delocate (matches prototype), strip only.
        cp "${wheel}" "${tmp}/"
        repaired="$(ls "${tmp}"/*.whl | head -1)"
    fi

    # Unpack the repaired wheel ONCE; BOTH wheels are packed from this same tree
    # (symmetric pack) so the debug + release wheels share an IDENTICAL packaging
    # code path. Whatever validates the release wheel's packaging then transitively
    # covers the debug wheel (PLAN.md §6) — "the debug wheel just works" confidence
    # without a redundant 100MB+ install in validate.
    local unpackdir root so_dir so_file so_path pre_size post_size
    unpackdir="$(mktemp -d)"
    "${py}" -m wheel unpack "${repaired}" -d "${unpackdir}"
    root="$(find "${unpackdir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    read -r so_dir so_file <<<"$(locate_core_so "${root}")"
    so_path="${so_dir}/${so_file}"

    # Pre-strip sanity: the debug .so MUST carry debug symbols, else the debug wheel
    # is pointless (build missing -g / not RelWithDebInfo?). The debug wheel is packed
    # from this pre-strip tree, so this transitively asserts it retains symbols.
    pre_size="$(_so_size "${so_path}")"
    if [[ "$(uname -s)" == "Linux" ]]; then
        readelf -S "${so_path}" 2>/dev/null | grep -q '\.debug_info' \
            || die "_wheel_repair: debug .so has no .debug_info — nothing to split (build missing -g/RelWithDebInfo?)"
    fi

    # DEBUG wheel = the tree packed BEFORE stripping (full symbols).
    "${py}" -m wheel pack "${root}" -d "${debug_wh}"

    # Strip the .so in place, then RELEASE wheel = the SAME tree repacked.
    if [[ "$(uname -s)" == "Linux" ]]; then
        (
            cd "${so_dir}"
            objcopy --only-keep-debug "${so_file}" "${so_file}.debug"
            objcopy --strip-debug --strip-unneeded "${so_file}"
            objcopy --add-gnu-debuglink="${so_file}.debug" "${so_file}"
            rm -f "${so_file}.debug"
        )
    else
        ( cd "${so_dir}" && xcrun strip -Sx "${so_file}" )
    fi
    "${py}" -m wheel pack "${root}" -d "${dest_dir}"

    # Post-strip integrity: the RELEASE .so must be smaller, carry NO .debug_info, and
    # (Linux) keep a .gnu_debuglink back to the debug file. Fail the BUILD here — at
    # the source — rather than discovering a broken split downstream.
    post_size="$(_so_size "${so_path}")"
    (( post_size < pre_size )) \
        || die "_wheel_repair: strip did not shrink the .so (pre=${pre_size} post=${post_size})"
    if [[ "$(uname -s)" == "Linux" ]]; then
        ! readelf -S "${so_path}" 2>/dev/null | grep -q '\.debug_info' \
            || die "_wheel_repair: release .so still carries .debug_info — strip failed"
        readelf -x .gnu_debuglink "${so_path}" >/dev/null 2>&1 \
            || die "_wheel_repair: release .so missing .gnu_debuglink — debuglink not added"
        log "strip integrity OK: release .so stripped + debuglink present (${pre_size} -> ${post_size} bytes)"
    else
        log "strip integrity OK: release .so stripped (${pre_size} -> ${post_size} bytes)"
    fi
    rm -rf "${tmp}" "${unpackdir}"
}

task_wheel() {
    # cibuildwheel wrapper (PLAN.md decision 5 / §6). Builds ONE build unit; the
    # vendor adapter fans out across units and sets the per-unit CBCI_BUILD_* env.
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_IS_PURE_PYTHON}" == "true" ]]; then
        # analytics has no C++ core -> plain build, no cibuildwheel. Phase 4.
        die "wheel: pure-python build path not yet implemented (Phase 4)"
    fi

    log "installing cibuildwheel"
    "${PYTHON}" -m pip install --upgrade pip
    "${PYTHON}" -m pip install "cibuildwheel${CBCI_CIBUILDWHEEL_VERSION:+==${CBCI_CIBUILDWHEEL_VERSION}}"

    # Build knobs the build reads (PYCBC_*); space-free, so reuse verbatim as
    # CIBW_ENVIRONMENT to carry them INTO the build (PLAN.md §6 hiccup #1).
    local cibw_environment
    cibw_environment="$("${PYTHON}" "${ENGINE}" build-env wheel)" || die "build-env wheel failed"

    # CIBW_* selectors (values may contain spaces -> read line by line).
    local k v
    while IFS='=' read -r k v; do
        [[ -n "${k}" ]] && export "${k}=${v}"
    done < <("${PYTHON}" "${ENGINE}" wheel-env)

    # Optional verbose build (0..3, mirrors cibuildwheel): passes -v to the build
    # frontend so compiler/CMake output surfaces — invaluable for debugging builds.
    [[ -n "${CBCI_BUILD_VERBOSITY:-}" ]] && export CIBW_BUILD_VERBOSITY="${CBCI_BUILD_VERBOSITY}"

    # Expose the CI-core scripts AND a debug-wheel output dir to the hooks WITHOUT
    # baking anything into the sdist (PLAN.md §7 assumptions #1 + #3):
    #   #1: the sdist-first build mounts the extracted sdist as {project}, which (by
    #       design) carries no CI tooling -> bind the CI-core dir READ-ONLY at /cbci
    #       and call hooks by that absolute path (not {project}).
    #   #3: on linux the build runs in a container where {project} is a COPY (writes
    #       don't surface) and only release wheels are copied back -> the debug wheel
    #       must land in a host-backed dir, so bind it WRITABLE at /cbci-debug.
    # macos/windows run on the host (no container): hooks use absolute host paths.
    local core_dir host_debug hook_dir
    core_dir="${CBCI_CORE_DIR:-${SCRIPT_DIR}}"
    host_debug="${PROJECT_ROOT}/wheelhouse/dist_debug"
    mkdir -p "${PROJECT_ROOT}/wheelhouse/dist" "${host_debug}"
    case "${CBCI_BUILD_PLATFORM:-}" in
        linux|alpine)
            hook_dir="/cbci"
            export CBCI_DEBUG_WHEELHOUSE="/cbci-debug"   # container-side; surfaces to host_debug
            # cibuildwheel parses "<engine>; create_args: <args>" (oci_container.py) by
            # splitting on ':' — a colon-delimited `--volume=src:dst:mode` spec gets shredded
            # into separate argv tokens (cibuildwheel 3.4.1), yielding "invalid reference
            # format" from docker. Use --mount (comma/equals, NO colons) so it survives intact.
            export CIBW_CONTAINER_ENGINE="docker; create_args: --mount type=bind,source=${core_dir},target=/cbci,readonly --mount type=bind,source=${host_debug},target=/cbci-debug"
            ;;
        *)
            hook_dir="${core_dir}"
            export CBCI_DEBUG_WHEELHOUSE="${host_debug}"
            ;;
    esac

    # OpenSSL: prebuild in BEFORE_ALL + re-export its location into the build.
    # The engine's USE_OPENSSL decision lives in the build-env STRING we just
    # computed; it is NOT exported into this shell, so detect it there (an indirect
    # ${!PYCBC_USE_OPENSSL} read would always be empty -> branch silently skipped).
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
    # (Jenkins macOS — see adapter_jenkins_tags). Builds ONE wheel with the on-PATH
    # (cbdep) python, then reuses task__wheel_repair to emit the lean release wheel +
    # full-symbol debug wheel — IDENTICAL strip/packaging to the cibuildwheel path.
    # The host toolchain env (MACOSX_DEPLOYMENT_TARGET/ARCHFLAGS/_PYTHON_HOST_PLATFORM,
    # cmake/go on PATH) is supplied by the vendor (Jenkins getEnvStr).
    load_project_env
    cd "${PROJECT_ROOT}"

    if [[ "${CBCI_IS_PURE_PYTHON}" == "true" ]]; then
        die "wheel-native: pure-python build path not yet implemented (Phase 4)"
    fi

    log "wheel-native: installing build deps"
    "${PYTHON}" -m pip install --upgrade pip
    "${PYTHON}" -m pip install -q wheel

    # Export the SAME PYCBC_* knobs the cibuildwheel path passes via CIBW_ENVIRONMENT, so
    # the native build is configured identically (PYCBC_USE_OPENSSL, PYCBC_BUILD_TYPE, ...).
    local build_env
    build_env="$("${PYTHON}" "${ENGINE}" build-env wheel)" || die "wheel-native: build-env wheel failed"
    log "wheel-native: build-env: ${build_env}"
    # shellcheck disable=SC2086  # intentional word-split of space-free KEY=VALUE pairs
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

    local whl found=0
    for whl in "${bdist}"/*.whl; do
        [[ -e "${whl}" ]] || break
        found=1
        log "wheel-native: repair+strip $(basename "${whl}")"
        task__wheel_repair "${whl}" "${PROJECT_ROOT}/wheelhouse/dist"
    done
    (( found )) || die "wheel-native: pip produced no wheel in ${bdist}"

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

# Install the BUILT artifact (or, with CBCI_PACKAGING_INDEX, an index package) into
# venv python $1 for install type $2 (wheel|sdist). Shared by validate + test-unit.
# Installs the artifact by FILE PATH so its deps still resolve from the index
# (matches the prototype). Reads CBCI_VALIDATE_PACKAGE / CBCI_PACKAGING_INDEX / CBCI_VERSION.
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
            # abi3 (PYCBC default) produces ONE wheel; non-abi3 per-Python fan-out is
            # validated on the matching runner. TODO(Phase 4): when multiple wheels are
            # present, pick the one matching this runner's Python.
            wheel) artifact="$(ls "${PROJECT_ROOT}"/wheelhouse/dist/*.whl 2>/dev/null | head -1 || true)" ;;
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

mod = os.environ["CBCI_VALIDATE_IMPORT"]
m = importlib.import_module(mod)
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

    # SSL backend: the build-correctness signal. Tolerant (warn) until the
    # get_metadata schema is confirmed against a real CI build; then promote to a
    # hard failure. TODO(Phase 1 CI): tighten to sys.exit on mismatch.
    want_ssl = (os.environ.get("CBCI_VALIDATE_SSL") or "").strip().lower()
    if want_ssl and want_ssl not in blob:
        print(f"[validate] WARNING: expected ssl backend '{want_ssl}' not evident in metadata", file=sys.stderr)

    print("[validate] smoke OK (extension imported + initialized)")
else:
    print("[validate] smoke OK (import only)")
PY
}

task_validate() {
    # Artifact-isolation (PLAN.md decision #9): install the BUILT artifact into a
    # clean env and smoke THAT — what a PyPI user gets — not the repo source tree.
    # Granularity is per (platform, arch, python, install_type); the vendor adapter
    # fans out, this validates ONE unit. Linux/macOS here; Windows -> tasks.ps1.
    load_project_env
    cd "${PROJECT_ROOT}"

    # Validate facts from the engine (install types, package/import name, ssl).
    local out
    out="$("${PYTHON}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086  # intentional word-split of KEY=VALUE pairs
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
        _validate_smoke "${vpy}"
        rm -rf "${venvroot}"
        log "validate: ${itype} OK"
    done
    log "validate: all install types passed (${CBCI_VALIDATE_INSTALL_TYPES})"
}

task_test() {
    # Artifact-isolation (PLAN.md decision #9): run the tests against the
    # INSTALLED artifact, not the repo source. engine.py test-setup builds a test tree
    # with the API dirs RENAMED (couchbase->cb, ...) so `import couchbase` resolves to
    # the installed wheel/sdist; we then run pytest from that tree per install_type.
    load_project_env
    cd "${PROJECT_ROOT}"

    local out
    out="$("${PYTHON}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086
    export ${out}
    [[ -n "${CBCI_INSTALL_TYPE:-}" ]] && CBCI_VALIDATE_INSTALL_TYPES="${CBCI_INSTALL_TYPE}"

    if [[ -n "${CBCI_JUNIT_DIR:-}" ]]; then
        mkdir -p "${CBCI_JUNIT_DIR}"
    fi

    # Build the artifact-isolation test tree ONCE (from the repo source). engine.py
    # prints the resolved tree path as its last line. This replaces gha.sh's
    # mkdir/cp/sed with a programmatic, unit-tested generator.
    local test_dir test_root
    test_dir="${CBCI_TEST_DIR:-${PROJECT_ROOT}/.cbci_test}"
    rm -rf "${test_dir}"; mkdir -p "${test_dir}"
    test_root="$(run_python "${ENGINE}" test-setup "${test_dir}" | tail -1)"
    [[ -d "${test_root}" ]] || die "test: test-setup did not produce a tree"
    log "test tree: ${test_root}"

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
    [[ -f "${so_path}" ]] || die "docs: could not locate compiled extension ${so_file} in ${so_dir}"

    # Copy extension to the source tree at the correct subdirectory path
    local rel_so_dir="${so_dir#${root}/}"
    local target_so_dir="${PROJECT_ROOT}/${rel_so_dir}"
    local target_so_path="${target_so_dir}/${so_file}"

    log "docs: copying extension ${so_path} -> ${target_so_path}"
    mkdir -p "${target_so_dir}"
    cp "${so_path}" "${target_so_path}"

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

# --- dispatch ----------------------------------------------------------------

main() {
    local stage="${1:-}"
    [[ -n "${stage}" ]] || die "usage: tasks.sh <stage> [args...]"

    # Optional artifact log (CBCI_LOG_FILE): tee this stage's whole run to a file the
    # vendor CI uploads as an artifact — survives console truncation/expiry, attaches
    # to bug reports, diffs across runs. Verbose-to-console (CBCI_BUILD_VERBOSITY)
    # stays primary; this is the durable copy. Re-exec through tee once (robust flush
    # vs. exec-into-procsub), guarded against recursion. Skip the internal in-container
    # hooks (_wheel_*): they run where CBCI_LOG_FILE isn't set and must not tee.
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
        test)                      task_test "$@" ;;
        docs)                      task_docs "$@" ;;
        # internal cibuildwheel hooks (invoked by cibuildwheel, not the pipeline)
        _wheel_before_all)         task__wheel_before_all "$@" ;;
        _wheel_repair)             task__wheel_repair "$@" ;;
        *) die "unknown stage: ${stage}" ;;
    esac
}

main "$@"
