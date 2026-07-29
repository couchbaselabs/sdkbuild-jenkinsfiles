#!/usr/bin/env bash
#
# tasks.sh — POSIX (Linux/macOS) task executors for the Couchbase Node.js SDK
# (couchnode).
#
# The vendor pipeline invokes:  ./tasks.sh <stage> [args...]
# Stages are the portable unit; orchestration/parallelism/archiving belong to the
# vendor. engine.js owns config -> plan; jenkins.js owns labels; tasks.sh owns
# "do the work for one unit". No `image` stage here (unlike Python's manylinux/
# musllinux containers) — couchnode builds NATIVELY on distro-labeled Jenkins
# agents; see jenkins.js's file header for the ground truth this is based on.
#
# Every stage below is ground-truthed against the real couchnode scripts
# (scripts/prebuilds.js, scripts/buildPrebuild.js, package.json, test/jcbmock.js,
# test/harness.js), not guessed from the legacy groovy alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ENGINE="${SCRIPT_DIR}/engine.js"
NODE_BIN="${CBCI_NODE:-node}"
NPM_BIN="${CBCI_NPM:-npm}"

# Project root = where the SDK checkout (couchnode) lives (consumer cwd by default).
PROJECT_ROOT="${CBCI_PROJECT_ROOT:-$(pwd -P)}"

log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [tasks] $*"; }
die() { echo "[tasks] ERROR: $*" >&2; exit 1; }

# --- shared helpers ----------------------------------------------------------

# Resolve CBCI_* project facts from engine.js and export them into this shell:
#   CBCI_PROJECT_PREFIX
load_project_env() {
    local out
    out="$("${NODE_BIN}" "${ENGINE}" project-env)" || die "failed to resolve project env"
    # shellcheck disable=SC2086  # intentional word-split of KEY=VALUE pairs
    export ${out}
}

_node_platform() { "${NODE_BIN}" -p 'process.platform'; }
_node_arch() { "${NODE_BIN}" -p 'process.arch'; }
_node_major() { "${NODE_BIN}" -p 'process.versions.node.split(".")[0]'; }
_pkg_version() { "${NODE_BIN}" -p "require('${PROJECT_ROOT}/package.json').version"; }

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
# Ground-truthed against scripts/prebuilds.js's configureBinary(): the CLI flags
# --configure/--set-cpm-cache pick the configure-only code path (no env equivalent
# for that decision); CN_USE_OPENSSL/CN_SET_CPM_CACHE (from `build-env sdist`)
# supply the VALUES that path reads. CN_BUILD_CONFIG/CN_VERBOSE_MAKEFILE do NOT
# apply here — the configure step never reads them.
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
    # shellcheck disable=SC2086  # intentional word-split of KEY=VALUE pairs
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
}

# --- prebuild: the actual compile, one build unit per (platform, arch, libc?, ssl,
# runtime). Ground-truthed against scripts/prebuilds.js's buildBinary(): reads
# CN_USE_OPENSSL/CN_BUILD_CONFIG/CN_VERBOSE_MAKEFILE (from `build-env prebuild`) and
# CN_PREBUILD_RUNTIME/CN_PREBUILD_RUNTIME_VERSION (from `prebuild-select-env`, itself
# fed by the adapter's per-job CBCI_BUILD_* env). CN_USE_CPM_CACHE defaults to true,
# so this reuses the CPM cache the sdist stage already baked in — no extra env needed.

# Strip debug symbols + emit the separate debug artifact. Ported verbatim from the
# legacy pipeline's "parse prebuild" stage (line ~396-416 of scripted-build-
# pipeline.groovy): the FULL pre-strip binary is preserved (tar.gz) under
# prebuildsDebug/ BEFORE stripping; linux additionally keeps a .gnu_debuglink back
# to an objcopy --only-keep-debug copy (immediately deleted locally, since the tar.gz
# already preserved the full binary). Windows never strips (no strip toolchain
# assumption); its debug artifact is the compiler-emitted .pdb.
task__prebuild_repair() {
    local built="$1" filename="$2"
    [[ -f "${built}" ]] || die "prebuild-repair: built binary not found: ${built}"

    mkdir -p prebuilds prebuildsDebug
    local target="prebuilds/${filename}.node"
    cp "${built}" "${target}"

    local uname_s; uname_s="$(uname -s)"
    if [[ "${uname_s}" == "Darwin" ]]; then
        log "prebuild-repair: tar full binary -> prebuildsDebug (macOS)"
        tar -czf "prebuildsDebug/${filename}-debug.tar.gz" -C prebuilds "$(basename "${target}")"
        log "prebuild-repair: xcrun strip -Sx"
        xcrun strip -Sx "${target}"
    elif [[ "${uname_s}" == "Linux" ]]; then
        log "prebuild-repair: tar full binary -> prebuildsDebug (Linux)"
        tar -czf "prebuildsDebug/${filename}-debug.tar.gz" -C prebuilds "$(basename "${target}")"
        log "prebuild-repair: objcopy strip + debuglink"
        objcopy --only-keep-debug "${target}" "${target}.debug"
        objcopy --strip-debug --strip-unneeded "${target}"
        objcopy --add-gnu-debuglink="${target}.debug" "${target}"
        rm -f "${target}.debug"
    else
        die "prebuild-repair: unsupported uname -s '${uname_s}' (expected Darwin|Linux; Windows uses tasks.ps1)"
    fi

    # Post-strip integrity: the release binary must be smaller than the tar'd-full
    # copy, and (Linux) carry no .debug_info but a .gnu_debuglink back to it. Fail
    # HERE — at the source — rather than discovering a broken split downstream.
    local pre_size post_size
    pre_size="$(gunzip -c "prebuildsDebug/${filename}-debug.tar.gz" | wc -c)"
    post_size="$([[ "${uname_s}" == "Darwin" ]] && stat -f%z "${target}" || stat -c%s "${target}")"
    (( post_size < pre_size )) \
        || log "WARNING: prebuild-repair: stripped size (${post_size}) not smaller than the tarred pre-strip copy (${pre_size}) — tar overhead may explain a small gap, but investigate if this persists"
    if [[ "${uname_s}" == "Linux" ]]; then
        ! objdump -h "${target}" 2>/dev/null | grep -q '\.debug_info' \
            || die "prebuild-repair: release .node still carries .debug_info — strip failed"
        objdump -h "${target}" 2>/dev/null | grep -q '\.gnu_debuglink' \
            || die "prebuild-repair: release .node missing .gnu_debuglink — debuglink not added"
    fi
    log "prebuild-repair: ${filename}.node ready (prebuilds/, prebuildsDebug/)"
}

task_prebuild() {
    cd "${PROJECT_ROOT}"

    # Self-sufficient build FROM the packed sdist tarball — this stage depends on
    # nothing sdist's OWN working tree left behind (npm ci/submodule/configure state).
    # The tarball already carries deps/couchbase-cxx-cache/** (npm pack's `files`
    # allowlist), so unpacking it needs no network CPM fetch.
    local sdist_tgz
    sdist_tgz="$(ls ./*.tgz 2>/dev/null | head -1)" || true
    [[ -n "${sdist_tgz}" ]] || die "prebuild: no *.tgz found under ${PROJECT_ROOT} (unstash the sdist first?)"
    log "prebuild: unpacking ${sdist_tgz}"
    tar -xzf "${sdist_tgz}" --strip-components=1

    # --ignore-scripts: package-lock.json is NOT in package.json's `files` allowlist
    # (confirmed via `npm pack --dry-run`), so `npm ci` can't run here (no lock file to
    # verify against) — must be `npm install`. --ignore-scripts skips the package's own
    # "install": "node ./scripts/install.js", which would otherwise try to build against
    # the AMBIENT runtime before build-env/prebuild-select-env below ever set the real
    # target (CN_PREBUILD_RUNTIME_VERSION) — same precedent as task_lint's `npm ci
    # --ignore-scripts` workaround.
    log "prebuild: restoring devDependencies (npm install --ignore-scripts)"
    "${NPM_BIN}" install --ignore-scripts

    local build_env
    build_env="$("${NODE_BIN}" "${ENGINE}" build-env prebuild)" || die "failed to resolve prebuild build-env"
    log "prebuild build-env: ${build_env}"
    # shellcheck disable=SC2086
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
    local built="build/${build_config}/couchbase_impl.node"
    [[ -f "${built}" ]] || die "prebuild: expected binary not found: ${built}"

    # Filename convention ported from the legacy pipeline's getPrebuildFileName():
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

    task__prebuild_repair "${built}" "${filename}"
    log "prebuild: release:"; ls -alh prebuilds
    log "prebuild: debug:";   ls -alh prebuildsDebug
}

# --- validate: install the BUILT artifact into a clean checkout and smoke-require
# it — proves what an `npm install couchbase` consumer actually gets, not the repo
# source tree. install_type=prebuild simulates the platform-package resolve path via
# npm_config_couchbase_local_prebuilds (ground-truthed: scripts/install.js's
# getLocalPrebuild()/resolveLocalPrebuild()); install_type=sdist forces the full
# cmake-js source build (no local-prebuilds hint), proving the sdist tarball is
# self-sufficient (CPM cache baked in, no network fetch needed).
_validate_one() {
    local itype="$1" sdist_tgz="$2"
    local tmp; tmp="$(mktemp -d)"
    log "validate: install_type=${itype} in ${tmp}"
    (
        cd "${tmp}"
        "${NPM_BIN}" init -y >/dev/null
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
        "${NODE_BIN}" -e "
const pkg = require(process.env.CBCI_VALIDATE_IMPORT);
if (typeof pkg.connect !== 'function') { console.error('[validate] couchbase module missing connect()'); process.exit(1); }
console.log('[validate] required ' + process.env.CBCI_VALIDATE_IMPORT + ' OK, connect() present');
"
    )
    local rc=$?
    rm -rf "${tmp}"
    return "${rc}"
}

task_validate() {
    cd "${PROJECT_ROOT}"
    local out
    out="$("${NODE_BIN}" "${ENGINE}" validate-env)" || die "failed to resolve validate-env"
    # shellcheck disable=SC2086
    export ${out}
    [[ -n "${CBCI_INSTALL_TYPE:-}" ]] && CBCI_VALIDATE_INSTALL_TYPES="${CBCI_INSTALL_TYPE}"

    local sdist_tgz
    sdist_tgz="$(ls "${PROJECT_ROOT}"/*.tgz 2>/dev/null | head -1 || true)"
    [[ -n "${sdist_tgz}" ]] || die "validate: no *.tgz found under ${PROJECT_ROOT} (build sdist first?)"

    local itype
    IFS=',' read -ra _types <<<"${CBCI_VALIDATE_INSTALL_TYPES}"
    for itype in "${_types[@]}"; do
        _validate_one "${itype}" "${sdist_tgz}" || die "validate: ${itype} failed"
        log "validate: ${itype} OK"
    done
    log "validate: all install types passed (${CBCI_VALIDATE_INSTALL_TYPES})"
}

# --- test: run the mocha suite against the CouchbaseMock.jar backend (default) or a
# real cluster (deferred to the later integration-pipeline phase — CNCSTR unset here
# means test/harness.js falls back to the mock, ground-truthed against
# test/harness.js + test/jcbmock.js). require_java is a real dependency: jcbmock.js
# spawns `java` directly (child_process.spawn('java', ...)) to run the mock jar.
#
# NOTHING IS COMPILED HERE. `test` consumes the prebuild the `prebuild` stage already
# produced — same contract as `validate`. The mechanism is ported verbatim from the
# legacy pipeline's test stage:
#   1. write couchbase_local_prebuilds into .npmrc, so npm re-exports it to lifecycle
#      scripts as npm_config_couchbase_local_prebuilds (scripts/install.js reads exactly
#      that name via getLocalPrebuild()). It must be visible to `npm run install`, not
#      merely set at dependency-install time — hence .npmrc rather than a shell export.
#   2. `npm ci --ignore-scripts` — deps only; the package's own install.js never runs.
#   3. `npm run install` — install.js sees the local-prebuilds hint and COPIES the .node
#      into build/Release instead of invoking cmake-js.
# Step 3 is verified, not trusted: install.js's installPrebuild() falls back to
# prebuilds.buildBinary() when it cannot resolve a prebuild, so a missing/mismatched .node
# would silently turn into a full source build — slow, and GREEN. The post-condition check
# below turns that into a hard failure.
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
    [[ -d "${dir}" ]] || die "test: no prebuilds/ under ${PROJECT_ROOT} — the prebuild stage must run (or its artifact be copied) first"
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
        || die "test: prebuilds/ exists but holds no *.node — nothing for scripts/install.js to resolve"
    printf '%s\n' "${dir}"
}

# Fail loudly if `npm run install` compiled (or produced nothing) instead of copying the
# prebuild. build/Release is install.js's own destination for the resolved binary.
_assert_prebuild_installed() {
    local rel="${PROJECT_ROOT}/build/Release"
    compgen -G "${rel}/*.node" >/dev/null \
        || die "test: no *.node in build/Release after 'npm run install' — the prebuild was not resolved"
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

# --- package: build the per-platform npm packages that get listed in
# optionalDependencies at publish time (publish itself is deferred — see
# ../CONVENTIONS.md Node addendum). Naming convention ground-truthed against
# scripts/prebuilds.js's getPrebuildsInfo(): `<name>-<libc-or-platform>-<arch>-
# <napi|electron>`. This is a first formalization (the source repo has no existing
# packaging script to port from — the legacy pipeline does this in groovy at publish
# time); verify against a real build agent before relying on it for a real publish.
task_package() {
    cd "${PROJECT_ROOT}"
    local pkg_name; pkg_name="$("${NODE_BIN}" -p "require('./package.json').name")"
    local version; version="$(_pkg_version)"

    local platform="${CBCI_BUILD_PLATFORM:?package: CBCI_BUILD_PLATFORM required}"
    local arch="${CBCI_BUILD_ARCH:?package: CBCI_BUILD_ARCH required}"
    local libc="${CBCI_BUILD_LIBC:-}"
    local runtime="${CBCI_BUILD_RUNTIME:-node}"
    local pkg_runtime; [[ "${runtime}" == "node" ]] && pkg_runtime="napi" || pkg_runtime="electron"
    local pkg_platform="${platform}"; [[ "${platform}" == "linux" && -n "${libc}" ]] && pkg_platform="${libc}"

    local subname="${pkg_name}-${pkg_platform}-${arch}-${pkg_runtime}"
    local out_dir="platform-packages/${subname}"
    rm -rf "${out_dir}"; mkdir -p "${out_dir}/prebuilds"

    local prebuild; prebuild="$(ls prebuilds/*.node 2>/dev/null | head -1 || true)"
    [[ -n "${prebuild}" ]] || die "package: no prebuild found under prebuilds/ (build it first?)"
    cp "${prebuild}" "${out_dir}/prebuilds/"

    cat > "${out_dir}/package.json" <<EOF
{
  "name": "@${pkg_name}/${subname}",
  "version": "${version}",
  "description": "Prebuilt ${pkg_name} binary for ${pkg_platform}/${arch} (${pkg_runtime})",
  "os": ["${pkg_platform}"],
  "cpu": ["${arch}"],
  "files": ["prebuilds/"]
}
EOF
    log "package: platform package ready at ${out_dir}"
    ls -alh "${out_dir}/prebuilds"
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
        _prebuild_repair)          task__prebuild_repair "$@" ;;
        *) die "unknown stage: ${stage}" ;;
    esac
}

main "$@"
