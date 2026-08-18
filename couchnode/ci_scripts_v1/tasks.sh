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
        [[ -s "prebuildsDebug/${filename}.debug" ]] \
            || die "prebuild-repair: debug companion ${filename}.debug did not land in prebuildsDebug/"
    else
        die "prebuild-repair: unsupported uname -s '${uname_s}' (expected Darwin|Linux; Windows uses tasks.ps1)"
    fi

    # Post-strip integrity: the release binary must be smaller than the tar'd-full
    # copy, and (Linux) carry no .debug_info but a .gnu_debuglink back to it. Fail
    # HERE, at the source, rather than discovering a broken split downstream.
    local pre_size post_size
    pre_size="$(gunzip -c "prebuildsDebug/${filename}-debug.tar.gz" | wc -c)"
    # if/else, not `A && B || C`: with the latter a failing BSD stat falls through to the
    # GNU one, which cannot work on the same host, leaving post_size empty and the size
    # assertion below silently satisfied.
    if [[ "${uname_s}" == "Darwin" ]]; then
        post_size="$(stat -f%z "${target}")"
    else
        post_size="$(stat -c%s "${target}")"
    fi
    (( post_size < pre_size )) \
        || log "WARNING: prebuild-repair: stripped size (${post_size}) not smaller than the tarred pre-strip copy (${pre_size}); tar overhead may explain a small gap, but investigate if this persists"
    if [[ "${uname_s}" == "Linux" ]]; then
        ! objdump -h "${target}" 2>/dev/null | grep -q '\.debug_info' \
            || die "prebuild-repair: release .node still carries .debug_info, strip failed"
        objdump -h "${target}" 2>/dev/null | grep -q '\.gnu_debuglink' \
            || die "prebuild-repair: release .node missing .gnu_debuglink, debuglink not added"
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

    task__prebuild_repair "${built}" "${filename}"
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
        *) die "unknown stage: ${stage}" ;;
    esac
}

main "$@"
