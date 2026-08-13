#!/usr/bin/env node
// engine.js — CI-core brain for the Couchbase Node.js SDK (couchnode).
//
// Responsibilities (single file by design; growth = new subcommands, not new files):
//   * load + merge + validate config (ci-config.yaml < CBCI_CONFIG_OVERRIDE < promoted vars)
//   * emit a vendor-NEUTRAL build plan (ABSTRACT platforms only — no runner labels/images)
//
// This module is vendor-NEUTRAL: it knows only abstract platforms (linux/alpine/macos/
// windows) and abstract runtimes (node/electron). Runner labels, container images, and
// the distro/agent vocabulary live in the per-CI adapter modules that `import` this file
// (jenkins.js now; gha.js later) — this core must NEVER import an adapter. See
// ../CONVENTIONS.md and ../python/ADAPTER_REFACTOR_PLAN.md (the pattern this mirrors).
//
// Shares NO CODE with couchbase-sdk-ci/python/engine.py — only the shape (CLI verbs,
// config-merge precedence, neutral-plan schema, adapter boundary).

import { parseArgs } from 'node:util';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { parse as parseYaml } from 'yaml';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG_FILENAME = 'ci-config.yaml';

// Promoted override vars (empty = use file). Map 1:1 to Jenkins params / GHA inputs.
export const PROMOTED_VARS = [
  'PLATFORMS', 'ARCHES', 'NODE_VERSIONS', 'ELECTRON_VERSIONS', 'RUNTIMES',
  'USE_OPENSSL', 'OPENSSL_VERSION', 'INSTALL_TYPES',
];

const VALID_RUNTIMES = ['node', 'electron'];
const VALID_PLATFORMS = ['linux', 'alpine', 'macos', 'windows'];
const VALID_INSTALL_TYPES = ['prebuild', 'sdist'];

// ---------------------------------------------------------------------------
// Config loading + merge
// ---------------------------------------------------------------------------

/** Resolved, merged configuration. The single in-memory source of truth. */
export class Config {
  constructor(raw) {
    this.raw = raw || {};
  }

  get project() {
    return this.raw.project || 'COUCHNODE';
  }
}

function loadYamlFile(path) {
  const text = readFileSync(path, 'utf8');
  return parseYaml(text) || {};
}

/** Recursively merge `over` onto `base`. Dicts merge key-wise; everything else
 * (scalars AND arrays) overwrites — an array override replaces, never concatenates. */
function deepMerge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    if (isPlainObject(v) && isPlainObject(out[k])) {
      out[k] = deepMerge(out[k], v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

/** Split a promoted-var list: comma- or space-separated. */
function parseList(value) {
  return (value || '')
    .replace(/,/g, ' ')
    .split(/\s+/)
    .map((tok) => tok.trim())
    .filter(Boolean);
}

function asBool(value) {
  return ['1', 'true', 'y', 'yes', 'on'].includes(String(value).trim().toLowerCase());
}

/** Deep-merge CBCI_CONFIG_OVERRIDE (one JSON object string) over the file config.
 *
 * Tolerates a stray wrapping quote (a JSON string can pick one up when passed
 * through a container/CLI layer). Invalid JSON warns and is ignored rather than
 * hard-failing the run.
 */
function applyConfigOverride(cfg) {
  let raw = process.env.CBCI_CONFIG_OVERRIDE;
  if (!raw || !raw.trim()) return cfg;
  raw = raw.trim();
  if (raw.length >= 2 && raw[0] === raw[raw.length - 1] && (raw[0] === "'" || raw[0] === '"')) {
    raw = raw.slice(1, -1).trim();
  }
  let override;
  try {
    override = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`WARNING: CBCI_CONFIG_OVERRIDE is not valid JSON (${e.message}); ignoring\n`);
    return cfg;
  }
  if (!isPlainObject(override)) {
    process.stderr.write('WARNING: CBCI_CONFIG_OVERRIDE must be a JSON object; ignoring\n');
    return cfg;
  }
  return deepMerge(cfg, override);
}

/** Filter `support.platforms` per arch to exactly `platforms` (a Set of ABSTRACT
 * platform names). Mutates in place. An empty set narrows to no platforms — callers
 * that mean "no narrowing" must simply not call this. */
function narrowPlatformsInPlace(support, platforms) {
  const plats = support.platforms || (support.platforms = {});
  for (const arch of support.architectures || []) {
    plats[arch] = (plats[arch] || []).filter((p) => platforms.has(p));
  }
}

/** Narrow the support matrix to a set of ABSTRACT platforms. The public hook for
 * per-CI adapters: after translating their vendor/distro tokens to abstract platforms,
 * an adapter calls this to scope `buildPlan` before emitting jobs. Empty/falsey =
 * no-op (the adapter keeps the full matrix). */
export function narrowToPlatforms(cfg, platforms) {
  const platSet = new Set([...(platforms || [])].map((p) => String(p).toLowerCase()));
  if (platSet.size) {
    narrowPlatformsInPlace(cfg.raw.support || (cfg.raw.support = {}), platSet);
  }
}

/** Apply promoted override vars (HIGHEST precedence). Each is empty = leave as-is.
 * Values are comma/space lists, validated against the support matrix where one
 * exists; unsupported entries warn and are dropped (never hard-fail on a stray
 * value). NODE_VERSIONS/ELECTRON_VERSIONS are a straight list REPLACEMENT — unlike
 * Python's PYTHON_VERSIONS, there is no fixed "supported Node version" boundary to
 * validate against (any semver the SDK's engines field allows is fair game).
 */
function applyPromotedVars(cfg) {
  const support = cfg.support || (cfg.support = {});
  const build = cfg.build || (cfg.build = {});

  // INSTALL_TYPES — narrows validate/test's install_type axis. ci-config declares the
  // full CAPABILITY (["prebuild", "sdist"]); this picks what a given RUN exercises, and
  // the consumers default it to 'prebuild' so neither stage compiles anything. Mirrors
  // Python's identically-named promoted var (engine.py's INSTALL_TYPES block).
  const installTypes = (process.env.INSTALL_TYPES || '').trim();
  if (installTypes) {
    const chosen = [];
    for (const t of parseList(installTypes).map((v) => v.toLowerCase())) {
      if (!VALID_INSTALL_TYPES.includes(t)) {
        process.stderr.write(`WARNING: unsupported install type '${t}' (expected prebuild|sdist); ignoring\n`);
      } else if (!chosen.includes(t)) {
        chosen.push(t);
      }
    }
    if (chosen.length) {
      const test = cfg.test || (cfg.test = {});
      test.install_types = chosen;
    }
  }

  const nodeVersions = (process.env.NODE_VERSIONS || '').trim();
  if (nodeVersions) {
    support.node_versions = parseList(nodeVersions);
  }

  const electronVersions = (process.env.ELECTRON_VERSIONS || '').trim();
  if (electronVersions) {
    support.electron_versions = parseList(electronVersions);
  }

  const runtimes = (process.env.RUNTIMES || '').trim();
  if (runtimes) {
    const chosen = [];
    for (const r of parseList(runtimes).map((v) => v.toLowerCase())) {
      if (VALID_RUNTIMES.includes(r)) {
        if (!chosen.includes(r)) chosen.push(r);
      } else {
        process.stderr.write(`WARNING: unsupported runtime '${r}' (expected node|electron); ignoring\n`);
      }
    }
    if (chosen.length) support.runtimes = chosen;
  }

  // ARCHES — normalize aarch64->arm64, x86_64->x64 (Node's own arch vocabulary).
  const arches = (process.env.ARCHES || '').trim();
  if (arches) {
    const supported = support.architectures || [];
    const chosen = [];
    for (let a of parseList(arches).map((v) => v.toLowerCase())) {
      a = a === 'aarch64' ? 'arm64' : a;
      a = a === 'x86_64' ? 'x64' : a;
      if (!supported.includes(a)) {
        process.stderr.write(`WARNING: unsupported arch '${a}' (not in support matrix); ignoring\n`);
      } else if (!chosen.includes(a)) {
        chosen.push(a);
      }
    }
    if (chosen.length) support.architectures = chosen;
  }

  // PLATFORMS — narrow each (selected) arch's platform list to the request. The engine
  // speaks ONLY abstract platforms (linux/alpine/macos/windows); mapping vendor/distro
  // tokens (qe-grav2-amzn2, m1, ubuntu-22.04) to abstract is the ADAPTER's job
  // (jenkins.js pops PLATFORMS and calls narrowToPlatforms() itself). Here, a
  // non-abstract token warns and is dropped.
  const platforms = (process.env.PLATFORMS || '').trim();
  if (platforms) {
    const requested = parseList(platforms).map((v) => v.toLowerCase());
    const plats = support.platforms || {};
    const arches2 = support.architectures || [];
    const validAnywhere = new Set(arches2.flatMap((a) => plats[a] || []));
    for (const p of requested) {
      if (!validAnywhere.has(p)) {
        process.stderr.write(
          `WARNING: platform '${p}' is not a supported abstract platform ` +
          `[${[...validAnywhere].sort().join(', ')}]; ignoring (distro/label tokens belong to ` +
          `the CI adapter, not engine.js)\n`
        );
      }
    }
    narrowPlatformsInPlace(support, new Set(requested.filter((p) => validAnywhere.has(p))));
  }

  // USE_OPENSSL / OPENSSL_VERSION — flip the SSL backend + pin.
  const useSsl = (process.env.USE_OPENSSL || '').trim();
  if (useSsl) {
    build.ssl = asBool(useSsl) ? 'openssl' : 'boringssl';
  }
  const osslVer = (process.env.OPENSSL_VERSION || '').trim();
  if (osslVer) {
    build.openssl_version = osslVer;
  }

  return cfg;
}

function isCommitAncestor(commitSha, projectRoot) {
  const cwd = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
  try {
    const catRes = spawnSync('git', ['cat-file', '-e', `${commitSha}^{commit}`], { cwd, stdio: 'ignore' });
    if (catRes.status !== 0) {
      return null;
    }
    const res = spawnSync('git', ['merge-base', '--is-ancestor', commitSha, 'HEAD'], { cwd, stdio: 'ignore' });
    return res.status === 0;
  } catch (_err) {
    return null;
  }
}

function evalVersionEntry(entry, keyName, projectRoot) {
  if (typeof entry === 'string') return entry.trim();
  if (!entry || typeof entry !== 'object') return null;
  const version = String(entry.version || '').trim();
  if (!version) return null;

  if (entry.min_commit) {
    const minCommit = String(entry.min_commit).trim();
    const isAnc = isCommitAncestor(minCommit, projectRoot);
    if (isAnc === false) {
      process.stderr.write(`[engine] ${keyName}: omitting '${version}' (min_commit '${minCommit.slice(0, 7)}' is not in HEAD history)\n`);
      return null;
    }
  }

  if (entry.drop_commit) {
    const dropCommit = String(entry.drop_commit).trim();
    const isAnc = isCommitAncestor(dropCommit, projectRoot);
    if (isAnc === true) {
      process.stderr.write(`[engine] ${keyName}: omitting '${version}' (drop_commit '${dropCommit.slice(0, 7)}' is in HEAD history)\n`);
      return null;
    }
  }

  return version;
}

export function resolveCommitGatedVersions(cfg, projectRoot) {
  const support = cfg.support;
  if (support && typeof support === 'object') {
    for (const key of ['python_versions', 'node_versions', 'electron_versions']) {
      if (Array.isArray(support[key])) {
        const resolved = [];
        for (const item of support[key]) {
          const v = evalVersionEntry(item, key, projectRoot);
          if (v && !resolved.includes(v)) {
            resolved.push(v);
          }
        }
        support[key] = resolved;
      }
    }
  }

  const build = cfg.build;
  if (build && typeof build === 'object' && 'abi3' in build) {
    const abi3Val = build.abi3;
    if (abi3Val && typeof abi3Val === 'object') {
      let enabled = Boolean(abi3Val.enabled ?? true);
      if (abi3Val.min_commit) {
        const minCommit = String(abi3Val.min_commit).trim();
        if (isCommitAncestor(minCommit, projectRoot) === false) {
          process.stderr.write(`[engine] build.abi3: disabling abi3 (min_commit '${minCommit.slice(0, 7)}' is not in HEAD history)\n`);
          enabled = false;
        }
      }
      if (abi3Val.drop_commit) {
        const dropCommit = String(abi3Val.drop_commit).trim();
        if (isCommitAncestor(dropCommit, projectRoot) === true) {
          process.stderr.write(`[engine] build.abi3: disabling abi3 (drop_commit '${dropCommit.slice(0, 7)}' is in HEAD history)\n`);
          enabled = false;
        }
      }
      build.abi3 = enabled;
    }
  }
  return cfg;
}

/** Load + merge config with precedence: file < CBCI_CONFIG_OVERRIDE < promoted vars.
 *
 * Config path precedence: explicit arg > CBCI_CONFIG_FILE env > ci-config.yaml
 * alongside engine.js.
 */
export function loadConfig(configPath) {
  const path = configPath
    || process.env.CBCI_CONFIG_FILE
    || join(__dirname, CONFIG_FILENAME);
  let cfg = loadYamlFile(resolvePath(path));
  cfg = resolveCommitGatedVersions(cfg);
  cfg = applyConfigOverride(cfg);
  cfg = applyPromotedVars(cfg);
  return new Config(cfg);
}

// ---------------------------------------------------------------------------
// Per-project facts + build-env exports (consumed by tasks.sh / tasks.ps1)
// ---------------------------------------------------------------------------

// Phase 1 scope is COUCHNODE only. The SDK's OWN env-var prefix (CN_*) is what
// scripts/prebuilds.js already reads (CN_USE_OPENSSL, CN_CXXCBC_CACHE_DIR, ...) — engine.js
// emits into that namespace rather than inventing a new one. Future Node SDKs
// (columnar/analytics) would extend this table, not replace it.
const PROJECT_PREFIX = 'CN';

/** CBCI-level facts tasks.sh needs to drive a stage. Values are space-free. */
export function projectEnv(cfg) {
  return {
    CBCI_PROJECT_PREFIX: PROJECT_PREFIX,
  };
}

function resolveVerboseMakefile(cfg) {
  const env = process.env.CBCI_VERBOSE_MAKEFILE;
  if (env !== undefined) return asBool(env);
  return Boolean(cfg.raw.build?.verbose_makefile);
}

/** Emit `CN_*` env that scripts/prebuilds.js / CMake read for the given stage.
 *
 * Ground-truthed against the real scripts/prebuilds.js (not guessed):
 *   - `sdist` runs the CONFIGURE-ONLY path (`configureBinary()`, invoked via
 *     `npm run prebuild -- --configure --set-cpm-cache`), which reads only
 *     CN_USE_OPENSSL + CN_SET_CPM_CACHE. It does NOT read CN_BUILD_CONFIG or
 *     CN_VERBOSE_MAKEFILE — those only apply to the actual compile step.
 *   - `prebuild` runs the BUILD path (`buildBinary()`), which reads CN_USE_OPENSSL,
 *     CN_BUILD_CONFIG (note: NOT "CN_BUILD_TYPE" — the real script's own name),
 *     and CN_VERBOSE_MAKEFILE. CN_OPENSSL_VERSION is NOT read by prebuilds.js at
 *     all; it is reserved for tasks.sh's own build-openssl-from-source helper
 *     (ported from Python's build_openssl), consumed there directly, not passed
 *     through to cmake-js.
 * Values are space-free so callers can `export $(engine.js build-env <stage>)`.
 */
const STAGE_BUILD_KEYS = {
  sdist: ['use_openssl', 'set_cpm_cache'],
  prebuild: ['use_openssl', 'openssl_version', 'build_config', 'verbose_makefile'],
};

export function buildEnv(cfg, stage) {
  const keys = STAGE_BUILD_KEYS[stage];
  if (!keys) {
    process.stderr.write(`ERROR: build-env: unknown stage: ${stage}\n`);
    process.exit(1);
  }
  const build = cfg.raw.build || {};
  const ssl = String(build.ssl || 'boringssl').toLowerCase();
  const out = {};
  for (const key of keys) {
    if (key === 'set_cpm_cache') {
      out[`${PROJECT_PREFIX}_SET_CPM_CACHE`] = build.set_cpm_cache === false ? 'OFF' : 'ON';
    } else if (key === 'build_config') {
      out[`${PROJECT_PREFIX}_BUILD_CONFIG`] = String(build.build_type || 'RelWithDebInfo');
    } else if (key === 'use_openssl') {
      out[`${PROJECT_PREFIX}_USE_OPENSSL`] = ssl === 'openssl' ? 'ON' : 'OFF';
    } else if (key === 'openssl_version') {
      if (ssl === 'openssl' && build.openssl_version) {
        out[`${PROJECT_PREFIX}_OPENSSL_VERSION`] = String(build.openssl_version);
      }
    } else if (key === 'verbose_makefile') {
      if (resolveVerboseMakefile(cfg)) {
        out[`${PROJECT_PREFIX}_VERBOSE_MAKEFILE`] = 'ON';
      }
    }
  }
  return out;
}

/** Per-unit prebuild selector env (the Node analog of Python's `wheel-env`).
 *
 * Ground-truthed against scripts/prebuilds.js's buildBinary()/configureBinary(),
 * which both resolve `runtime`/`runtimeVersion` from CN_PREBUILD_RUNTIME /
 * CN_PREBUILD_RUNTIME_VERSION (falling back to 'node' / the ambient `process.version`
 * when unset) and pass them straight through as cmake-js's `--runtime`/`--runtime-
 * version`. There is no separate "napi version" or "electron node version" env input
 * on the real build side — those were an earlier, unverified design of this file;
 * NAPI_VERSION is in fact hardcoded in CMakeLists.txt (`-DNAPI_VERSION=6`), not
 * env-driven, so nothing is emitted for it here.
 *
 * Build-unit dimensions are read from the env the adapter sets per unit:
 *   CBCI_BUILD_PLATFORM (linux|alpine|macos|windows), CBCI_BUILD_ARCH (x64|arm64),
 *   CBCI_BUILD_LIBC (manylinux|musllinux), CBCI_BUILD_RUNTIME (node|electron),
 *   CBCI_BUILD_ELECTRON_VERSION (electron units only — the ACTUAL Electron version
 *   cmake-js builds against, e.g. "20.0.0"),
 *   CBCI_BUILD_NODE_VERSION (node units — the ACTUAL Node version cmake-js builds
 *   against). Both are ported from the legacy pipeline's own
 *   `envs.add("CN_PREBUILD_RUNTIME_VERSION=${electronVersion}")` /
 *   `envs.add("CN_PREBUILD_RUNTIME_VERSION=${nodeVersion}")` — the legacy pipeline
 *   pins a representative version for NODE builds too (the single oldest configured
 *   node_versions entry for boringssl, or the ABI-floor's representative for
 *   openssl), it is never left to the ambient build-agent Node. jenkins.js resolves
 *   which representative version via its `electronBuildBuckets()`/
 *   `opensslBuildBuckets()` (or, for the boringssl default, the oldest of
 *   support.node_versions directly) — see its buildJobsFromPlan().
 */
export function prebuildSelectEnv(cfg) {
  const runtime = (process.env.CBCI_BUILD_RUNTIME || 'node').toLowerCase();
  const out = { [`${PROJECT_PREFIX}_PREBUILD_RUNTIME`]: runtime };
  if (runtime === 'electron') {
    const electronVersion = process.env.CBCI_BUILD_ELECTRON_VERSION;
    if (electronVersion) out[`${PROJECT_PREFIX}_PREBUILD_RUNTIME_VERSION`] = electronVersion;
  } else {
    const nodeVersion = process.env.CBCI_BUILD_NODE_VERSION;
    if (nodeVersion) out[`${PROJECT_PREFIX}_PREBUILD_RUNTIME_VERSION`] = nodeVersion;
  }
  return out;
}

/** Facts tasks.sh needs to drive `validate` (install the built prebuild into a
 * clean env and smoke-require it). */
export function validateEnv(cfg) {
  const test = cfg.raw.test || {};
  const build = cfg.raw.build || {};
  const installTypes = test.install_types || ['prebuild', 'sdist'];
  const ssl = String(build.ssl || 'boringssl').toLowerCase();
  return {
    CBCI_VALIDATE_INSTALL_TYPES: installTypes.join(','),
    CBCI_VALIDATE_PACKAGE: '@couchbase/couchbase',
    CBCI_VALIDATE_IMPORT: 'couchbase',
    CBCI_VALIDATE_SSL: ssl,
  };
}

function resolvePublishDryRun(cfg) {
  const env = process.env.CBCI_PUBLISH_DRY_RUN;
  if (env !== undefined) return asBool(env);
  return Boolean(cfg.raw.publish?.publish_dry_run);
}

/** Facts tasks.sh needs to drive `publish` (npm publish of the platform packages). */
export function publishEnv(cfg) {
  const publish = cfg.raw.publish || {};
  return {
    CBCI_PUBLISH_PACKAGE: '@couchbase/couchbase',
    CBCI_PUBLISH_NPM: publish.publish_npm === false ? 'false' : 'true',
    CBCI_PUBLISH_ELECTRON_NPM: publish.publish_electron_npm ? 'true' : 'false',
    CBCI_PUBLISH_DRY_RUN: resolvePublishDryRun(cfg) ? 'true' : 'false',
  };
}

// ---------------------------------------------------------------------------
// Neutral build plan (no runner labels — see ../CONVENTIONS.md)
// ---------------------------------------------------------------------------

/** True if (platform, arch, runtime) is listed in support.unsupported. */
function isUnsupportedCombo(support, platform, arch, runtime) {
  for (const entry of support.unsupported || []) {
    if (entry.platform === platform && entry.arch === arch &&
        (!entry.runtime || entry.runtime === runtime)) {
      return true;
    }
  }
  return false;
}

/** Emit the vendor-NEUTRAL plan (ABSTRACT dimensions only — no runner labels or
 * container images; those are attached by the adapter). See CONVENTIONS.md.
 *
 *   * build units: ONE prebuild per (platform, arch, libc?, ssl, runtime) — NEVER
 *     per node_version/electron_version. N-API is ABI-stable across every runtime
 *     major that supports the configured napi_version floor, so build fan-out stops
 *     at `runtime`; version fan-out belongs to validate/test only.
 *   * electron build units carry no electron-node-version floor — bucketing
 *     electron_versions into concrete Node-ABI floors is adapter-owned (jenkins.js's
 *     Electron<->Node compat table), exactly like the libc "oldest glibc floor" pick.
 *     A single neutral unit may expand into MORE than one adapter job if the
 *     configured electron_versions span incompatible floors.
 *   * validate / test_unit: per (platform, arch, runtime, version, install_type) —
 *     wide fan-out, proving every declared Node/Electron version actually loads the
 *     (few) prebuilds.
 * libc (manylinux/musllinux) is present only for linux/alpine units, never macos/windows.
 */
export function buildPlan(cfg) {
  const support = cfg.raw.support || {};
  const build = cfg.raw.build || {};
  const test = cfg.raw.test || {};
  const nodeVersions = support.node_versions || [];
  const electronVersions = support.electron_versions || [];
  const runtimes = support.runtimes || ['node'];
  const arches = support.architectures || [];
  const platsByArch = support.platforms || {};
  const libcMap = build.libc || {};
  const ssl = String(build.ssl || 'boringssl').toLowerCase();
  const buildType = String(build.build_type || 'RelWithDebInfo');
  const napiVersion = build.napi_version ?? 8;
  const installTypes = test.install_types || ['prebuild', 'sdist'];

  const keyed = (platform, arch, libc) => {
    const d = { platform, arch };
    if (libc) d.libc = libc;
    return d;
  };

  const buildUnits = [];
  const validateUnits = [];
  const testUnits = [];
  const seen = new Set();

  for (const arch of arches) {
    for (const platform of platsByArch[arch] || []) {
      seen.add(platform);
      const libc = libcMap[platform]; // undefined for macos/windows

      for (const runtime of runtimes) {
        if (isUnsupportedCombo(support, platform, arch, runtime)) {
          continue;
        }

        const versions = runtime === 'electron' ? electronVersions : nodeVersions;
        if (runtime === 'electron' && versions.length === 0) continue; // nothing declared to build

        const unit = keyed(platform, arch, libc);
        Object.assign(unit, { ssl, runtime, build_type: buildType });
        if (runtime === 'node') unit.napi_version = napiVersion;
        buildUnits.push(unit);

        for (const version of versions) {
          for (const itype of installTypes) {
            const cell = keyed(platform, arch, libc);
            Object.assign(cell, { runtime, version, install_type: itype });
            validateUnits.push({ ...cell });
            testUnits.push({ ...cell });
          }
        }
      }
    }
  }

  return {
    build: {
      has_linux: seen.has('linux'),
      has_macos: seen.has('macos'),
      has_windows: seen.has('windows'),
      has_alpine: seen.has('alpine'),
      units: buildUnits,
    },
    validate: { units: validateUnits },
    test_unit: { units: testUnits },
  };
}

/** Coherence-check the MERGED config. Returns {errors, warnings}. Errors are
 * fatal (e.g. an override emptied the matrix); warnings are advisory. */
export function validateConfig(cfg) {
  const errors = [];
  const warnings = [];
  const support = cfg.raw.support || {};
  const build = cfg.raw.build || {};

  if (!support.node_versions || support.node_versions.length === 0) {
    errors.push('support.node_versions is empty (an override may have dropped everything)');
  }
  if (!support.architectures || support.architectures.length === 0) {
    errors.push('support.architectures is empty');
  }
  for (const arch of support.architectures || []) {
    if (!support.platforms?.[arch]?.length) {
      warnings.push(`no platforms selected for arch '${arch}' — it will produce no units`);
    }
  }

  const runtimes = support.runtimes || [];
  if (runtimes.length === 0) {
    errors.push('support.runtimes is empty');
  }
  for (const r of runtimes) {
    if (!VALID_RUNTIMES.includes(r)) {
      errors.push(`support.runtimes contains unknown runtime '${r}' (expected node|electron)`);
    }
  }
  if (runtimes.includes('electron') && !(support.electron_versions || []).length) {
    warnings.push("runtimes includes 'electron' but support.electron_versions is empty — no electron units will be produced");
  }

  const ssl = String(build.ssl || 'boringssl').toLowerCase();
  if (!['boringssl', 'openssl'].includes(ssl)) {
    errors.push(`build.ssl must be boringssl|openssl (got '${ssl}')`);
  }
  if (ssl === 'openssl' && !build.openssl_version) {
    warnings.push('build.ssl=openssl but build.openssl_version is unset');
  }

  const napi = build.napi_version;
  if (napi !== undefined && (!Number.isInteger(napi) || napi < 1)) {
    errors.push(`build.napi_version must be a positive integer (got ${JSON.stringify(napi)})`);
  }

  return { errors, warnings };
}

// ---------------------------------------------------------------------------
// Test-command generation
// ---------------------------------------------------------------------------

/** Mocha invocation for the test-unit stage, from ci-config test.mocha. A single
 * command line (unlike Python's per-API list — couchnode's test suite is one mocha
 * run), honoring CBCI_TEST_COMMAND/CBCI_TEST_ARGS overrides the same way Python's
 * test-cmds does. */
export function testCmds(cfg) {
  const overrideCmd = process.env.CBCI_TEST_COMMAND;
  const overrideArgs = process.env.CBCI_TEST_ARGS || '';
  if (overrideCmd) {
    return [`${overrideCmd} ${overrideArgs}`.trim()];
  }
  const mocha = cfg.raw.test?.mocha || {};
  const cmd = mocha.cmd || 'npm run test';
  return [overrideArgs ? `${cmd} ${overrideArgs}`.trim() : cmd];
}

/** Whether the test agent needs a `java` runtime (CouchbaseMock.jar fallback). */
export function requiresJava(cfg) {
  return Boolean(cfg.raw.test?.mocha?.require_java);
}

// ---------------------------------------------------------------------------
// CLI dispatch
// ---------------------------------------------------------------------------

function emit(obj) {
  console.log(JSON.stringify(obj));
}

function emitPairs(pairs) {
  console.log(Object.entries(pairs).map(([k, v]) => `${k}=${v}`).join(' '));
}

function emitLines(pairs) {
  for (const [k, v] of Object.entries(pairs)) {
    console.log(`${k}=${v}`);
  }
}

function usage() {
  process.stderr.write(
    'usage: engine.js [--config <path>] <plan|validate-config|project-env|build-env <stage>|' +
    'prebuild-select-env|validate-env|publish-env|test-cmds|requires-java>\n'
  );
}

export function main(argv = process.argv.slice(2)) {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { config: { type: 'string' } },
    allowPositionals: true,
  });

  const cmd = positionals[0];
  if (!cmd) {
    usage();
    return 1;
  }

  const cfg = loadConfig(values.config);

  switch (cmd) {
    case 'plan':
      emit(buildPlan(cfg));
      break;
    case 'validate-config': {
      const { errors, warnings } = validateConfig(cfg);
      for (const w of warnings) process.stderr.write(`WARNING: ${w}\n`);
      if (errors.length) {
        for (const e of errors) process.stderr.write(`ERROR: ${e}\n`);
        return 1;
      }
      console.log(`config OK: project=${cfg.project}`);
      break;
    }
    case 'project-env':
      emitPairs(projectEnv(cfg));
      break;
    case 'build-env': {
      const stage = positionals[1];
      if (!stage) {
        process.stderr.write('usage: engine.js build-env <sdist|prebuild>\n');
        return 1;
      }
      emitPairs(buildEnv(cfg, stage));
      break;
    }
    case 'prebuild-select-env':
      emitLines(prebuildSelectEnv(cfg));
      break;
    case 'validate-env':
      emitPairs(validateEnv(cfg));
      break;
    case 'publish-env':
      emitPairs(publishEnv(cfg));
      break;
    case 'test-cmds':
      for (const line of testCmds(cfg)) console.log(line);
      break;
    case 'requires-java':
      console.log(requiresJava(cfg) ? 'true' : 'false');
      break;
    default:
      usage();
      return 1;
  }
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
