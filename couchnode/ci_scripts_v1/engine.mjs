#!/usr/bin/env node
// engine.mjs - CI-core brain for the Couchbase Node.js SDK (couchnode).
//
// Responsibilities (single file by design; growth = new subcommands, not new files):
//   * load + merge + validate config (ci-config.yaml < CBCI_CONFIG_OVERRIDE < promoted vars)
//   * emit a vendor-NEUTRAL build plan (ABSTRACT platforms only, no runner labels/images)
//
// Vendor-NEUTRAL: this module knows only abstract platforms (linux/alpine/macos/windows)
// and abstract runtimes (node/electron). Runner labels, container images, and the
// distro/agent vocabulary live in the per-CI adapter modules that `import` this file
// (jenkins.mjs, gha.mjs). The core must NEVER import an adapter. See ../CONVENTIONS.md.

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

// Where commit-gate bookkeeping lives on the merged config.
const GATE_KEY = '_gates';

// Which gated domains each CLI command actually reads. A gate decision is only WORTH
// reporting where the value it produces gets consumed: every per-unit command runs on an
// agent whose Node/Electron version was already fixed by the plan, so matrix chatter there
// describes a matrix nobody reads. Commands absent from this map report nothing; the
// resolution itself (and its `indeterminate` bookkeeping) is unconditional, so
// validate-config still fails hard on a gate it could not evaluate.
export const GATE_REPORT_DOMAINS = {
  plan: ['node_versions', 'electron_versions'],
  'validate-config': ['node_versions', 'electron_versions'],
};

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
 * (scalars AND arrays) overwrites: an array override replaces, never concatenates. */
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
 * platform names). Mutates in place. An empty set narrows to NO platforms; callers
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

/** Apply promoted override vars (HIGHEST precedence). Empty = leave as-is.
 *
 * Values are comma/space lists, validated against the support matrix where one exists;
 * an unsupported entry warns and is dropped rather than failing the run.
 * NODE_VERSIONS/ELECTRON_VERSIONS are a straight list REPLACEMENT: there is no fixed
 * "supported Node version" boundary to validate against, since any semver the SDK's
 * engines field allows is fair game.
 */
function applyPromotedVars(cfg) {
  const support = cfg.support || (cfg.support = {});
  const build = cfg.build || (cfg.build = {});

  // INSTALL_TYPES: narrows validate/test's install_type axis. ci-config declares the full
  // CAPABILITY (["prebuild", "sdist"]); this picks what a given RUN exercises, and the
  // consumers default it to 'prebuild' so neither stage compiles anything.
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

  // ARCHES: normalize aarch64->arm64, x86_64->x64 (Node's own arch vocabulary).
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

  // PLATFORMS: narrow each selected arch's platform list to the request. The engine speaks
  // ONLY abstract platforms (linux/alpine/macos/windows). Mapping vendor/distro tokens
  // (qe-grav2-amzn2, m1, ubuntu-22.04) to abstract is the ADAPTER's job: it pops PLATFORMS
  // and calls narrowToPlatforms() itself. A non-abstract token here warns and is dropped.
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
          `the CI adapter, not engine.mjs)\n`
        );
      }
    }
    narrowPlatformsInPlace(support, new Set(requested.filter((p) => validAnywhere.has(p))));
  }

  // USE_OPENSSL / OPENSSL_VERSION: flip the SSL backend + pin.
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

/** Resolve one version entry (a plain string, or a dict carrying min_commit/drop_commit)
 * to its version string, or null when a gate filters it out.
 *
 * A gate that cannot be evaluated (no git repo at projectRoot, or the sha is absent from a
 * shallow clone) is recorded in `gates.indeterminate` rather than quietly leaving the entry
 * in place: silently KEEPING a version that should have been dropped builds the wrong
 * matrix, and the resulting plan looks perfectly plausible. validateConfig turns those
 * records into hard errors.
 *
 * `report` only silences the narration (see GATE_REPORT_DOMAINS); what the gate decides,
 * and what it records, is identical either way. */
function evalVersionEntry(entry, keyName, projectRoot, gates, report = true) {
  if (typeof entry === 'string') return entry.trim();
  if (!entry || typeof entry !== 'object') return null;
  const version = String(entry.version || '').trim();
  if (!version) return null;

  const recordIndeterminate = (kind, sha) => {
    const where = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
    const msg = `${keyName} '${version}': ${kind} '${sha.slice(0, 7)}' could not be evaluated `
      + `(no git repo, or sha absent, at ${where})`;
    if (report) process.stderr.write(`[engine] WARNING: ${msg}\n`);
    if (gates) (gates.indeterminate ||= []).push({ domain: keyName, msg });
  };

  if (entry.min_commit) {
    const minCommit = String(entry.min_commit).trim();
    const isAnc = isCommitAncestor(minCommit, projectRoot);
    if (isAnc === null) {
      recordIndeterminate('min_commit', minCommit);
    } else if (isAnc === false) {
      if (report) {
        process.stderr.write(`[engine] ${keyName}: omitting '${version}' (min_commit '${minCommit.slice(0, 7)}' is not in HEAD history)\n`);
      }
      return null;
    }
  }

  if (entry.drop_commit) {
    const dropCommit = String(entry.drop_commit).trim();
    const isAnc = isCommitAncestor(dropCommit, projectRoot);
    if (isAnc === null) {
      recordIndeterminate('drop_commit', dropCommit);
    } else if (isAnc === true) {
      if (report) {
        process.stderr.write(`[engine] ${keyName}: omitting '${version}' (drop_commit '${dropCommit.slice(0, 7)}' is in HEAD history)\n`);
      }
      return null;
    }
  }

  return version;
}

/** Resolve every commit-gated version list against the SDK checkout.
 *
 * `reportDomains` limits which domains narrate their decisions (null = all of them).
 * COUCHNODE gates versions only; there is no build-option gate here. */
export function resolveCommitGatedVersions(cfg, projectRoot, reportDomains = null) {
  const gates = (cfg[GATE_KEY] ||= {});
  const reports = (domain) => reportDomains === null || reportDomains.includes(domain);

  const support = cfg.support;
  if (support && typeof support === 'object') {
    for (const key of ['node_versions', 'electron_versions']) {
      if (Array.isArray(support[key])) {
        const resolved = [];
        for (const item of support[key]) {
          const v = evalVersionEntry(item, key, projectRoot, gates, reports(key));
          if (v && !resolved.includes(v)) {
            resolved.push(v);
          }
        }
        support[key] = resolved;
      }
    }
  }
  return cfg;
}

/** Load + merge config with precedence: file < CBCI_CONFIG_OVERRIDE < promoted vars.
 *
 * Config path precedence: explicit arg > CBCI_CONFIG_FILE env > ci-config.yaml
 * alongside engine.mjs.
 *
 * `reportDomains` scopes commit-gate narration to the domains the caller consumes
 * (null = narrate everything; the CLI passes GATE_REPORT_DOMAINS[cmd]).
 */
export function loadConfig(configPath, reportDomains = null) {
  const path = configPath
    || process.env.CBCI_CONFIG_FILE
    || join(__dirname, CONFIG_FILENAME);
  let cfg = loadYamlFile(resolvePath(path));
  // Order is load-bearing. The override merges FIRST so a gating dict supplied through
  // CBCI_CONFIG_OVERRIDE is actually resolved; left unresolved it survives as an OBJECT
  // inside node_versions and leaks "[object Object]" into job env. Gating runs SECOND so
  // promoted vars see plain version strings. Promoted vars run LAST: they outrank both.
  cfg = applyConfigOverride(cfg);
  cfg = resolveCommitGatedVersions(cfg, undefined, reportDomains);
  cfg = applyPromotedVars(cfg);
  return new Config(cfg);
}

// ---------------------------------------------------------------------------
// Per-project facts + build-env exports (consumed by tasks.sh / tasks.ps1)
// ---------------------------------------------------------------------------

// COUCHNODE only. CN_* is the SDK's OWN env-var prefix, already read by
// scripts/prebuilds.js (CN_USE_OPENSSL, CN_CXXCBC_CACHE_DIR, ...), so emit into that
// namespace rather than inventing a new one. A future Node SDK would extend this table.
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
 * Keyed to what scripts/prebuilds.js actually reads:
 *   - `sdist` runs the CONFIGURE-ONLY path (`configureBinary()`, invoked via
 *     `npm run prebuild -- --configure --set-cpm-cache`), which reads only
 *     CN_USE_OPENSSL + CN_SET_CPM_CACHE. It does NOT read CN_BUILD_CONFIG or
 *     CN_VERBOSE_MAKEFILE; those apply only to the actual compile step.
 *   - `prebuild` runs the BUILD path (`buildBinary()`), which reads CN_USE_OPENSSL,
 *     CN_BUILD_CONFIG (that is the script's own name for it, NOT CN_BUILD_TYPE), and
 *     CN_VERBOSE_MAKEFILE. CN_OPENSSL_VERSION is not read by prebuilds.js at all; it
 *     is reserved for tasks.sh's build-openssl-from-source helper, consumed there
 *     directly rather than passed through to cmake-js.
 * Values are space-free so callers can `export $(engine.mjs build-env <stage>)`.
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

/** Per-unit prebuild selector env.
 *
 * scripts/prebuilds.js's buildBinary()/configureBinary() both resolve
 * `runtime`/`runtimeVersion` from CN_PREBUILD_RUNTIME / CN_PREBUILD_RUNTIME_VERSION,
 * falling back to 'node' and the ambient `process.version`, and pass them straight
 * through as cmake-js's `--runtime`/`--runtime-version`. There is no napi-version env
 * input: NAPI_VERSION is hardcoded in CMakeLists.txt (`-DNAPI_VERSION=6`), so nothing
 * is emitted for it here.
 *
 * Build-unit dimensions are read from the env the adapter sets per unit:
 *   CBCI_BUILD_PLATFORM (linux|alpine|macos|windows), CBCI_BUILD_ARCH (x64|arm64),
 *   CBCI_BUILD_LIBC (manylinux|musllinux), CBCI_BUILD_RUNTIME (node|electron),
 *   CBCI_BUILD_ELECTRON_VERSION (electron units: the ACTUAL Electron version cmake-js
 *   builds against, e.g. "20.0.0"),
 *   CBCI_BUILD_NODE_VERSION (node units: the ACTUAL Node version cmake-js builds
 *   against).
 * A representative version is pinned for NODE builds too, never left to the ambient
 * build-agent Node. jenkins.mjs picks it via electronBuildBuckets() /
 * opensslBuildBuckets(), or the oldest of support.node_versions for the boringssl
 * default. See its buildJobsFromPlan().
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
    // The npm install spec, unscoped. The scope '@couchbase' belongs to the platform
    // packages ('@couchbase/couchbase-linux-x64-napi'), never to the main package, and an
    // install of '@couchbase/couchbase' resolves to nothing.
    CBCI_VALIDATE_PACKAGE_NAME: 'couchbase',
    CBCI_VALIDATE_IMPORT: 'couchbase',
    CBCI_VALIDATE_SSL: ssl,
  };
}

function resolvePublishDryRun(cfg) {
  const env = process.env.CBCI_PUBLISH_DRY_RUN;
  if (env !== undefined) return asBool(env);
  return Boolean(cfg.raw.publish?.publish_dry_run);
}

/** Facts tasks.sh needs to drive `package` and `publish` (the platform packages plus the
 * repacked main tarball). */
export function publishEnv(cfg) {
  const publish = cfg.raw.publish || {};
  const out = {
    CBCI_PUBLISH_PACKAGE_NAME: 'couchbase',
    CBCI_PUBLISH_NPM: publish.publish_npm === false ? 'false' : 'true',
    CBCI_PUBLISH_ELECTRON_NPM: publish.publish_electron_npm ? 'true' : 'false',
    CBCI_PUBLISH_DRY_RUN: resolvePublishDryRun(cfg) ? 'true' : 'false',
  };
  // A prerelease must not take the 'latest' dist-tag, which is what npm assigns when no
  // tag is given. Passed through from the vendor rather than derived, so a release can be
  // staged under any tag without a config change.
  const tag = process.env.CBCI_NPM_TAG;
  if (tag) out.CBCI_NPM_TAG = tag;
  return out;
}

// ---------------------------------------------------------------------------
// Neutral build plan (no runner labels; see ../CONVENTIONS.md)
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

/** Emit the vendor-NEUTRAL plan: ABSTRACT dimensions only, no runner labels or container
 * images (the adapter attaches those). See ../CONVENTIONS.md.
 *
 *   * build units: ONE prebuild per (platform, arch, libc?, ssl, runtime), NEVER per
 *     node_version/electron_version. N-API is ABI-stable across every runtime major that
 *     supports the configured napi_version floor, so build fan-out stops at `runtime` and
 *     version fan-out belongs to validate/test only.
 *   * electron build units carry no electron-node-version floor. Bucketing
 *     electron_versions into concrete Node-ABI floors is adapter-owned (jenkins.mjs's
 *     Electron/Node compat table), exactly like the libc "oldest glibc floor" pick. A
 *     single neutral unit may expand into MORE than one adapter job when the configured
 *     electron_versions span incompatible floors.
 *   * validate / test_unit: per (platform, arch, runtime, version, install_type), a wide
 *     fan-out proving every declared Node/Electron version actually loads the prebuilds.
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

// Which Node releases actually implement a given Node-API level. Ground-truthed against
// the "Node-API version matrix" table in the Node docs (nodejs.org/api/n-api.html); to
// extend, copy a row from there rather than inferring one. `lines` pins the minimum
// PATCH-level release for majors that got the level mid-line (Node-API levels are
// routinely backported, so "major >= N" alone is wrong); `allFrom` is the first major
// that shipped with it from .0. A major below every listed line and below `allFrom`
// does not support the level at all.
const NAPI_MIN_NODE = {
  6: { lines: { 10: '10.20.0', 12: '12.17.0' }, allFrom: 14 },
  7: { lines: { 10: '10.23.0', 12: '12.19.0', 14: '14.12.0' }, allFrom: 15 },
  8: { lines: { 12: '12.22.0', 14: '14.17.0', 15: '15.12.0' }, allFrom: 16 },
  9: { lines: { 18: '18.17.0', 20: '20.3.0' }, allFrom: 21 },
  10: { lines: { 22: '22.14.0', 23: '23.6.0' }, allFrom: 24 },
};

function cmpVersionTriples(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i += 1) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  }
  return 0;
}

/** Does `nodeVersion` implement Node-API level `napi`? null = no table row for that
 * level, so the caller cannot decide. */
function nodeSupportsNapi(nodeVersion, napi) {
  const row = NAPI_MIN_NODE[napi];
  if (!row) return null;
  const major = parseInt(String(nodeVersion).split('.')[0], 10);
  if (Number.isNaN(major)) return null;
  const line = row.lines[major];
  if (line) return cmpVersionTriples(nodeVersion, line) >= 0;
  return major >= row.allFrom;
}

/** Coherence-check the MERGED config. Returns {errors, warnings}. Errors are
 * fatal (e.g. an override emptied the matrix); warnings are advisory. */
export function validateConfig(cfg) {
  const errors = [];
  const warnings = [];
  const support = cfg.raw.support || {};
  const build = cfg.raw.build || {};

  // --- commit gates ---------------------------------------------------------
  // A gate that could not be evaluated is fatal, not advisory. The failure is silent by
  // nature (the entry simply stays put), so it produces a plausible-looking plan built
  // from the wrong matrix. Nearly always this means the node resolving the plan has no
  // SDK checkout: give the config a real git tree, via CBCI_PROJECT_ROOT or cwd.
  // An EXPLICIT override supersedes its gate, so a gate whose domain was pinned is moot
  // and its indeterminacy is only advisory - that is how a pipeline with no SDK checkout
  // stays legitimate without a bypass flag a source-building pipeline could inherit.
  const gates = cfg.raw[GATE_KEY] || {};
  const PIN_VAR = { node_versions: 'NODE_VERSIONS', electron_versions: 'ELECTRON_VERSIONS' };
  for (const rec of gates.indeterminate || []) {
    const pinned = Boolean((process.env[PIN_VAR[rec.domain]] || '').trim());
    const suffix = pinned ? ' (superseded by an explicit override)' : '';
    (pinned ? warnings : errors).push(`commit gate could not be evaluated: ${rec.msg}${suffix}`);
  }

  if (!support.node_versions || support.node_versions.length === 0) {
    errors.push('support.node_versions is empty (an override may have dropped everything)');
  }
  if (!support.architectures || support.architectures.length === 0) {
    errors.push('support.architectures is empty');
  }
  for (const arch of support.architectures || []) {
    if (!support.platforms?.[arch]?.length) {
      warnings.push(`no platforms selected for arch '${arch}'; it will produce no units`);
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
    warnings.push("runtimes includes 'electron' but support.electron_versions is empty, so no electron units will be produced");
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
  } else if (napi !== undefined) {
    // The whole "ONE prebuild serves every node_versions entry" claim rests on every
    // configured version implementing the compiled Node-API level. A version below it
    // gets a binary it cannot load, and nothing before the validate stage says so.
    const nodeVersions = support.node_versions || [];
    const unknown = [];
    for (const v of nodeVersions) {
      const ok = nodeSupportsNapi(v, napi);
      if (ok === null) {
        unknown.push(v);
      } else if (!ok) {
        errors.push(
          `support.node_versions entry '${v}' does not implement Node-API ${napi} `
          + '(the level the addon is compiled against), so it cannot load the prebuild. '
          + 'Drop the entry, or lower build.napi_version and CMakeLists.txt\'s NAPI_VERSION together.');
      }
    }
    if (unknown.length) {
      warnings.push(
        `build.napi_version=${napi} could not be checked against [${unknown.join(', ')}] `
        + '(no NAPI_MIN_NODE row for that level, or an unparseable version) - the '
        + '"one prebuild serves every version" claim is unverified for those entries');
    }
    // Deliberately NOT checked: the mirror direction, a napi_version well below what every
    // configured version could run. The level is hardcoded as NAPI_VERSION in
    // CMakeLists.txt, so that observation is a source-code opinion rather than a CI defect,
    // and it would fire on every healthy run.
  }

  return { errors, warnings };
}

// ---------------------------------------------------------------------------
// Test-command generation
// ---------------------------------------------------------------------------

/** Mocha invocation for the test-unit stage, from ci-config test.mocha. One command line,
 * since couchnode's test suite is a single mocha run, honoring the CBCI_TEST_COMMAND /
 * CBCI_TEST_ARGS overrides. */
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
    'usage: engine.mjs [--config <path>] <plan|validate-config|project-env|build-env <stage>|' +
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

  const cfg = loadConfig(values.config, GATE_REPORT_DOMAINS[cmd] || []);

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
        process.stderr.write('usage: engine.mjs build-env <sdist|prebuild>\n');
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
