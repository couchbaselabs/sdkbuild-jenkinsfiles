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
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { parse as parseYaml } from 'yaml';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG_FILENAME = 'ci-config.yaml';

// Promoted override vars (empty = use file). Map 1:1 to Jenkins params / GHA inputs.
export const PROMOTED_VARS = [
  'PLATFORMS', 'ARCHES', 'NODE_VERSIONS', 'VALIDATE_NODE_VERSIONS', 'BUILD_NODE_VERSION',
  'ELECTRON_VERSIONS', 'RUNTIMES', 'USE_OPENSSL', 'OPENSSL_VERSION', 'INSTALL_TYPES',
];

const VALID_RUNTIMES = ['node', 'electron'];
const VALID_PLATFORMS = ['linux', 'alpine', 'macos', 'windows'];
const VALID_INSTALL_TYPES = ['prebuild', 'sdist'];

// Where commit-gate bookkeeping lives on the merged config.
const GATE_KEY = '_gates';
// Which version lists a promoted var replaced outright. An explicit list is taken as given:
// it outranks a runner's own node_versions and skips the engines filter.
const PINNED_KEY = '_pinned';

// Which gated domains each CLI command actually reads. A gate decision is only WORTH
// reporting where the value it produces gets consumed: every per-unit command runs on an
// agent whose Node/Electron version was already fixed by the plan, so matrix chatter there
// describes a matrix nobody reads. Commands absent from this map report nothing; the
// resolution itself (and its `indeterminate` bookkeeping) is unconditional, so
// validate-config still fails hard on a gate it could not evaluate.
const ALL_GATE_DOMAINS = ['node_versions', 'validate_node_versions', 'runner_node_versions', 'electron_versions'];
export const GATE_REPORT_DOMAINS = {
  plan: ALL_GATE_DOMAINS,
  'validate-config': ALL_GATE_DOMAINS,
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

  // NODE_VERSIONS is the TEST list for whichever runner is selected, so it also replaces a
  // runner's own node_versions (see testNodeVersions). VALIDATE_NODE_VERSIONS replaces the
  // validate pool and skips the engines filter. BUILD_NODE_VERSION replaces the build floor.
  const pinned = (cfg[PINNED_KEY] ||= {});
  const nodeVersions = (process.env.NODE_VERSIONS || '').trim();
  if (nodeVersions) {
    support.node_versions = parseList(nodeVersions);
    pinned.node_versions = true;
  }
  const validateVersions = (process.env.VALIDATE_NODE_VERSIONS || '').trim();
  if (validateVersions) {
    support.validate_node_versions = parseList(validateVersions);
    pinned.validate_node_versions = true;
  }
  const buildNode = (process.env.BUILD_NODE_VERSION || '').trim();
  if (buildNode) {
    build.node_version = buildNode;
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
function evalVersionEntry(entry, keyName, projectRoot, gates, report = true, domain = keyName) {
  if (typeof entry === 'string') return entry.trim();
  if (!entry || typeof entry !== 'object') return null;
  const version = String(entry.version || '').trim();
  if (!version) return null;

  const recordIndeterminate = (kind, sha) => {
    const where = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
    const msg = `${keyName} '${version}': ${kind} '${sha.slice(0, 7)}' could not be evaluated `
      + `(no git repo, or sha absent, at ${where})`;
    if (report) process.stderr.write(`[engine] WARNING: ${msg}\n`);
    if (gates) (gates.indeterminate ||= []).push({ domain, msg });
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

// Build flags that may be a dict carrying min_commit/drop_commit. Each resolves to a plain
// bool, and its verdict lands in cfg[GATE_KEY][key] for validateConfig to read.
const GATED_BUILD_FLAGS = ['ca_bundle_normalize'];
// Gates only the sdist stage reads. The other stages build from a tarball with no git, so
// an indeterminate verdict there is moot; `ca-bundle-env sdist` enforces it instead.
const SDIST_ONLY_GATES = ['ca_bundle_normalize'];

/** Resolve `build[key]` in place. A plain value is left as-is and recorded as ungated. */
function resolveGatedFlag(build, key, projectRoot, gates, report) {
  const val = build[key];
  if (!isPlainObject(val)) {
    gates[key] = 'ungated';
    return;
  }
  let enabled = val.enabled === undefined ? true : Boolean(val.enabled);
  for (const [kind, disableWhen] of [['min_commit', false], ['drop_commit', true]]) {
    if (!val[kind]) continue;
    const sha = String(val[kind]).trim();
    const isAnc = isCommitAncestor(sha, projectRoot);
    if (isAnc === null) {
      const where = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
      const msg = `build.${key}: ${kind} '${sha.slice(0, 7)}' could not be evaluated (no git repo, or sha absent, at ${where})`;
      if (report) process.stderr.write(`[engine] WARNING: ${msg}\n`);
      (gates.indeterminate ||= []).push({ domain: key, msg });
    } else if (isAnc === disableWhen) {
      if (report) {
        process.stderr.write(`[engine] build.${key}: disabling ${key} (${kind} '${sha.slice(0, 7)}' `
          + `${disableWhen ? 'is' : 'is not'} in HEAD history)\n`);
      }
      enabled = false;
    }
  }
  build[key] = enabled;
  gates[key] = enabled ? 'enabled' : 'disabled';
}

/** Resolve every commit-gated version list and build flag against the SDK checkout.
 *
 * `reportDomains` limits which domains narrate their decisions (null = all of them). */
export function resolveCommitGatedVersions(cfg, projectRoot, reportDomains = null) {
  const gates = (cfg[GATE_KEY] ||= {});
  const reports = (domain) => reportDomains === null || reportDomains.includes(domain);

  const resolveList = (list, keyName, domain) => {
    const resolved = [];
    for (const item of list) {
      const v = evalVersionEntry(item, keyName, projectRoot, gates, reports(domain), domain);
      if (v && !resolved.includes(v)) {
        resolved.push(v);
      }
    }
    return resolved;
  };

  const support = cfg.support;
  if (support && typeof support === 'object') {
    for (const key of ['node_versions', 'validate_node_versions', 'electron_versions']) {
      if (Array.isArray(support[key])) {
        support[key] = resolveList(support[key], key, key);
      }
    }
  }
  for (const r of Array.isArray(cfg.test?.runners) ? cfg.test.runners : []) {
    if (r && Array.isArray(r.node_versions)) {
      r.node_versions = resolveList(r.node_versions, `test.runners[${r.name}].node_versions`, 'runner_node_versions');
    }
  }
  if (isPlainObject(cfg.build)) {
    for (const key of GATED_BUILD_FLAGS) {
      if (key in cfg.build) resolveGatedFlag(cfg.build, key, projectRoot, gates, reports(key));
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

// Policy for ca_bundle_check.mjs, as CBCI_* pairs (tasks.sh consumes them, not prebuilds.js).
// The sdist stage also gets the normalize switch; prebuild and package only check.
const CA_BUNDLE_STAGES = ['sdist', 'prebuild', 'package'];
const SHA256_HEX = /^[0-9a-f]{64}$/;

export function caBundleEnv(cfg, stage) {
  if (!CA_BUNDLE_STAGES.includes(stage)) {
    throw new Error(`ca-bundle-env: unknown stage: ${stage} (expected ${CA_BUNDLE_STAGES.join('|')})`);
  }
  const build = cfg.raw.build || {};
  const policy = build.ca_bundle || {};
  const out = {
    CBCI_CA_MIN_CERTS: String(policy.min_certs ?? 100),
    CBCI_CA_DENIED_SHA256: (policy.denied_sha256 || []).map((d) => String(d).trim().toLowerCase()).join(','),
  };
  if (policy.min_date) out.CBCI_CA_MIN_DATE = String(policy.min_date);
  if (stage === 'sdist') out.CBCI_CA_BUNDLE_NORMALIZE = build.ca_bundle_normalize === true ? 'ON' : 'OFF';
  return out;
}

/** Shape errors in build.ca_bundle. A typo here would silently weaken a release gate. */
function caBundleErrors(policy) {
  if (policy === undefined || policy === null) return [];
  if (!isPlainObject(policy)) return ['build.ca_bundle must be a mapping'];
  const errors = [];
  // YAML may hand back an unquoted date as a Date; the engine only accepts the string form.
  const minDate = policy.min_date;
  if (minDate !== undefined && minDate !== null
      && !(typeof minDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(minDate) && !Number.isNaN(Date.parse(minDate)))) {
    errors.push(`build.ca_bundle.min_date must be a quoted "YYYY-MM-DD" (got ${JSON.stringify(minDate)})`);
  }
  const minCerts = policy.min_certs;
  if (minCerts !== undefined && minCerts !== null && !(Number.isInteger(minCerts) && minCerts >= 0)) {
    errors.push(`build.ca_bundle.min_certs must be a non-negative integer (got ${JSON.stringify(minCerts)})`);
  }
  for (const d of policy.denied_sha256 || []) {
    if (!SHA256_HEX.test(String(d).trim().toLowerCase())) {
      errors.push(`build.ca_bundle.denied_sha256: not a sha256 fingerprint: '${d}'`);
    }
  }
  return errors;
}

/** Per-unit prebuild selector env.
 *
 * scripts/prebuilds.js's buildBinary()/configureBinary() both resolve
 * `runtime`/`runtimeVersion` from CN_PREBUILD_RUNTIME / CN_PREBUILD_RUNTIME_VERSION,
 * falling back to 'node' and the ambient `process.version`, and pass them straight
 * through as cmake-js's `--runtime`/`--runtime-version`. There is no napi-version env
 * input: NAPI_VERSION is hardcoded in CMakeLists.txt, so nothing is emitted for it here
 * (`napi-version` reads it back for the prebuild filename).
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

export const VALID_PACKAGE_MANAGERS = ['npm', 'yarn', 'yarn-classic'];
export const VALID_YARN_LINKERS = ['pnp', 'node-modules'];
const DEFAULT_NPM_REGISTRY = 'https://registry.npmjs.org';

// Yarn 4 needs Node >= 18.12; below that, Berry is pinned to the last 3.x.
const YARN4_MIN_NODE = '18.12.0';

// Yarn is npm-installed, which has no 'stable' tag to resolve, so config pins exact versions.
function exactYarnVersion(v) {
  const s = String(v).trim();
  if (!/^\d+\.\d+\.\d+$/.test(s)) {
    throw new Error(`test.validate.yarn versions must be exact x.y.z (got '${s}')`);
  }
  return s;
}

// cmake-js@8's engines field (^20.17.0 || >=22.9.0). Yarn classic enforces engines as a hard
// error, so below this floor it needs --ignore-engines; npm and Berry only warn.
function meetsCmakeJsEngines(nodeVersion) {
  const major = parseInt(String(nodeVersion).split('.')[0], 10);
  if (major === 20) return cmpVersionTriples(nodeVersion, '20.17.0') >= 0;
  return cmpVersionTriples(nodeVersion, '22.9.0') >= 0;
}

/** Facts tasks.sh needs to drive `validate` (install the built prebuild, or in registry
 * mode the published package, into a clean env and smoke it). `nodeVersion` is the node
 * running this, which is the node the install runs under: it picks the yarn release and
 * whether yarn classic needs --ignore-engines. */
export function validateEnv(cfg, nodeVersion = process.versions.node) {
  const test = cfg.raw.test || {};
  const build = cfg.raw.build || {};
  const validate = test.validate || {};
  const yarn = validate.yarn || {};
  const installTypes = test.install_types || ['prebuild', 'sdist'];
  const ssl = String(build.ssl || 'boringssl').toLowerCase();

  const pm = String(process.env.CBCI_VALIDATE_PACKAGE_MANAGER || 'npm').trim().toLowerCase();
  if (!VALID_PACKAGE_MANAGERS.includes(pm)) {
    throw new Error(`CBCI_VALIDATE_PACKAGE_MANAGER must be ${VALID_PACKAGE_MANAGERS.join('|')} (got '${pm}')`);
  }
  const linker = String(process.env.CBCI_VALIDATE_YARN_LINKER || validate.yarn_linker || 'pnp')
    .trim().toLowerCase();
  if (!VALID_YARN_LINKERS.includes(linker)) {
    throw new Error(`CBCI_VALIDATE_YARN_LINKER must be ${VALID_YARN_LINKERS.join('|')} (got '${linker}')`);
  }
  // npm install specs. Berry's npm package is @yarnpkg/cli-dist; 'yarn' on npm is classic.
  let pmSpec = '';
  if (pm === 'yarn') {
    const berry = cmpVersionTriples(nodeVersion, YARN4_MIN_NODE) >= 0
      ? (yarn.berry || '4.18.1') : (yarn.berry_below_node18 || '3.6.1');
    pmSpec = `@yarnpkg/cli-dist@${exactYarnVersion(berry)}`;
  } else if (pm === 'yarn-classic') {
    pmSpec = `yarn@${exactYarnVersion(yarn.classic || '1.22.22')}`;
  }

  const registry = String(process.env.CBCI_NPM_REGISTRY || DEFAULT_NPM_REGISTRY).trim();
  const kv = process.env.CBCI_VALIDATE_KV !== undefined && process.env.CBCI_VALIDATE_KV !== ''
    ? asBool(process.env.CBCI_VALIDATE_KV) : Boolean(validate.kv_smoke);
  return {
    CBCI_VALIDATE_INSTALL_TYPES: installTypes.join(','),
    // The npm install spec, unscoped. The scope '@couchbase' belongs to the platform
    // packages ('@couchbase/couchbase-linux-x64-napi'), never to the main package, and an
    // install of '@couchbase/couchbase' resolves to nothing.
    CBCI_VALIDATE_PACKAGE_NAME: 'couchbase',
    CBCI_VALIDATE_IMPORT: 'couchbase',
    CBCI_VALIDATE_SSL: ssl,
    CBCI_VALIDATE_PACKAGE_MANAGER: pm,
    // The yarn to npm-install ('@yarnpkg/cli-dist@4.18.1', 'yarn@1.22.22'); empty for npm.
    CBCI_VALIDATE_PM_SPEC: pmSpec,
    // Where that yarn comes from: always the public registry, so a bare test registry
    // (NPM_REGISTRY) only has to serve the SDK.
    CBCI_VALIDATE_PM_REGISTRY: DEFAULT_NPM_REGISTRY,
    CBCI_VALIDATE_YARN_LINKER: linker,
    CBCI_VALIDATE_IGNORE_ENGINES: String(pm === 'yarn-classic' && !meetsCmakeJsEngines(nodeVersion)),
    CBCI_VALIDATE_IGNORE_SCRIPTS: String(asBool(process.env.CBCI_VALIDATE_IGNORE_SCRIPTS || '')),
    CBCI_VALIDATE_PRUNE: String(asBool(process.env.CBCI_VALIDATE_PRUNE || '')),
    CBCI_VALIDATE_KV: String(kv),
    CBCI_VALIDATE_CAVES_VERSION: String(validate.gocaves_version || 'v0.0.1-78'),
    // Registry mode only. Always explicit, so a stale registry in an agent's ~/.npmrc or
    // ~/.yarnrc.yml cannot decide where the package comes from.
    CBCI_VALIDATE_REGISTRY: registry,
    // Yarn Berry refuses plain-http registries unless the host is whitelisted.
    CBCI_VALIDATE_REGISTRY_HTTP_HOST: registry.startsWith('http://') ? new URL(registry).host : '',
  };
}

/* The validate smoke check. Never called here: validateSmokeScript() emits its source, which
 * tasks.sh/tasks.ps1 stage in the install dir and run with `node` (or `yarn node`, so Yarn
 * PnP can resolve). Plain CommonJS that runs on every supported Node (16+), and pure ASCII
 * because tasks.ps1 captures it through the console encoding.
 *
 * 1. require the package. On failure, name what actually shipped: the loader's own error
 *    ("Could not find native build for platform=...") reports only what it WANTED.
 * 2. In registry mode, the installed version must be CBCI_VERSION exactly.
 * 3. cbppMetadata must parse as JSON. It comes from the native binding, so this also proves
 *    the addon loaded rather than just the JS wrapper. Its SSL backend is only WARNED on:
 *    the metadata schema is the C++ core's, not a contract this package makes.
 * 4. With CBCI_VALIDATE_KV=true, a KV round-trip against a GoCAVES mock. GoCAVES ships one
 *    static binary per platform, so the agent needs nothing installed (no java). */
function validateSmoke() {
  const fs = require('fs');
  const path = require('path');
  const https = require('https');
  const net = require('net');
  const assert = require('assert');
  const { spawn } = require('child_process');
  const { createRequire } = require('module');
  const env = process.env;

  function dumpAddons() {
    const facts = [`node ${process.versions.node}`, `Node-API ${process.versions.napi}`,
      `${process.platform}/${process.arch}`, `ssl=${env.CBCI_VALIDATE_SSL || '?'}`];
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
    // Yarn PnP has no node_modules; packages with native files are unplugged instead.
    walk('node_modules');
    walk(path.join('.yarn', 'unplugged'));

    if (!found.length) {
      console.error('[validate]   shipped: NO .node addon under node_modules/ or .yarn/unplugged/ '
        + '(the prebuild never landed, or a source build was expected and did not produce one)');
      return;
    }
    // The loader matches on the FILENAME's tokens, so the name is the diagnosis:
    //   couchbase-v<pkg>-<runtime>-v<abi>-<platform|libc>-<arch>-<ssl>.node
    // A mismatch in any one of them (musl vs glibc, openssl3 vs boringssl, arch) presents
    // as "no native build found", identical to nothing having shipped at all.
    for (const p of found) console.error(`[validate]   shipped: ${p}`);
  }

  function cavesAsset() {
    const arm = process.arch === 'arm64';
    if (process.platform === 'linux') return arm ? 'gocaves-linux-arm64' : 'gocaves-linux-amd64';
    if (process.platform === 'darwin') return arm ? 'gocaves-macos-arm64' : 'gocaves-macos';
    if (process.platform === 'win32') return arm ? 'gocaves-windows-arm64.exe' : 'gocaves-windows.exe';
    throw new Error(`no GoCAVES build for ${process.platform}/${process.arch}`);
  }

  function download(url, dest, redirects) {
    return new Promise((resolve, reject) => {
      const req = https.get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          if (redirects >= 5) { reject(new Error(`too many redirects fetching ${url}`)); return; }
          resolve(download(new URL(res.headers.location, url).toString(), dest, redirects + 1));
          return;
        }
        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`GET ${url} returned HTTP ${res.statusCode}`));
          return;
        }
        const out = fs.createWriteStream(dest);
        res.pipe(out);
        out.on('finish', () => out.close(resolve));
        out.on('error', reject);
        res.on('error', reject);
      });
      req.setTimeout(120000, () => req.destroy(new Error(`timed out fetching ${url}`)));
      req.on('error', reject);
    });
  }

  // Cached across runs on the same agent, keyed by version. Downloaded to a temp name and
  // renamed, so an interrupted fetch never leaves a truncated binary behind for the next run.
  async function cavesBinary() {
    const version = env.CBCI_VALIDATE_CAVES_VERSION;
    const asset = cavesAsset();
    const dir = path.join(env.CBCI_VALIDATE_CAVES_DIR || path.join(require('os').tmpdir(), 'cbci-gocaves'), version);
    const bin = path.join(dir, asset);
    if (fs.existsSync(bin) && fs.statSync(bin).size > 0) return bin;
    fs.mkdirSync(dir, { recursive: true });
    const url = `https://github.com/couchbaselabs/gocaves/releases/download/${version}/${asset}`;
    console.log(`[validate] fetching ${url}`);
    const partial = `${bin}.${process.pid}.partial`;
    await download(url, partial, 0);
    fs.chmodSync(partial, 0o755);
    fs.renameSync(partial, bin);
    return bin;
  }

  // GoCAVES control protocol: we listen, GoCAVES connects to --control-port and greets with
  // {"type":"hello"}; every message either way is JSON terminated by a NUL byte.
  function startCaves(bin) {
    return new Promise((resolve, reject) => {
      const server = net.createServer();
      let proc;
      const timer = setTimeout(() => {
        server.close();
        if (proc) {
          dumpCavesOutput(proc);
          proc.kill();
        }
        reject(new Error('GoCAVES never connected to the control port'));
      }, 30000);
      server.once('connection', (sock) => {
        clearTimeout(timer);
        server.close();
        let buf = Buffer.alloc(0);
        const waiters = [];
        sock.on('data', (d) => {
          buf = Buffer.concat([buf, d]);
          let i;
          while ((i = buf.indexOf(0)) >= 0) {
            const msg = JSON.parse(buf.subarray(0, i).toString());
            buf = buf.subarray(i + 1);
            const w = waiters.shift();
            if (w) w(msg);
          }
        });
        const next = () => new Promise((res) => waiters.push(res));
        const send = (cmd) => { sock.write(`${JSON.stringify(cmd)}\0`); return next(); };
        resolve({ proc, sock, next, send });
      });
      server.on('error', reject);
      server.listen(0, '127.0.0.1', () => {
        proc = spawn(bin, [`--control-port=${server.address().port}`],
          { stdio: ['ignore', 'pipe', 'pipe'] });
        // Kept for the failure report only. Bounded, and always drained so a chatty mock
        // can never block on a full pipe.
        proc.output = '';
        const keep = (d) => { proc.output = (proc.output + d.toString()).slice(-65536); };
        proc.stdout.on('data', keep);
        proc.stderr.on('data', keep);
        proc.on('error', (err) => { clearTimeout(timer); server.close(); reject(err); });
      });
    });
  }

  function dumpCavesOutput(proc) {
    const lines = (proc?.output || '').trimEnd().split('\n').slice(-40);
    if (!lines[0]) {
      console.error('[validate] GoCAVES wrote no output');
      return;
    }
    console.error('[validate] GoCAVES output (last 40 lines):');
    // GoCAVES logs whole packets; the head of each line is the part that reads.
    for (const line of lines) console.error(`[validate]   ${line.slice(0, 240)}`);
  }

  // assert.rejects would turn a timeout into an AssertionError, hiding it from the retry.
  // Any error other than the expected one is rethrown as itself.
  async function expectError(promise, cls) {
    try {
      await promise;
    } catch (err) {
      if (err instanceof cls) return;
      throw err;
    }
    throw new assert.AssertionError({ message: `expected ${cls.name}, but the operation succeeded` });
  }

  // One attempt, on its own key: a timed-out insert may still have landed, so a retry on
  // the same key could fail with DocumentExistsError for a reason that is not the SDK's.
  async function kvOps(couchbase, cluster, key) {
    const coll = cluster.bucket('default').defaultCollection();
    const doc = { a: 'aa', b: 1, c: ['foo', 'bar'], what: 'insert' };
    await expectError(coll.get(key), couchbase.DocumentNotFoundError);
    assert.ok((await coll.insert(key, doc)).cas, 'insert returned no cas');
    assert.deepStrictEqual((await coll.get(key)).content, doc);
    await expectError(coll.insert(key, doc), couchbase.DocumentExistsError);
    doc.what = 'upsert';
    assert.ok((await coll.upsert(key, doc)).cas, 'upsert returned no cas');
    assert.deepStrictEqual((await coll.get(key)).content, doc);
    doc.what = 'replace';
    assert.ok((await coll.replace(key, doc)).cas, 'replace returned no cas');
    assert.deepStrictEqual((await coll.get(key)).content, doc);
    assert.ok((await coll.remove(key)).cas, 'remove returned no cas');
    await expectError(coll.get(key), couchbase.DocumentNotFoundError);
  }

  async function kvRoundTrip(couchbase) {
    const caves = await startCaves(await cavesBinary());
    try {
      const hello = await caves.next();
      assert.strictEqual(hello.type, 'hello', `GoCAVES did not greet: ${JSON.stringify(hello)}`);
      const created = await caves.send({ type: 'createcluster', id: 'validate' });
      assert.ok(created.connstr, `createcluster returned no connstr: ${JSON.stringify(created)}`);

      // Timeouts only, connect included, which a slow agent or a mock still settling can
      // produce. Any other error is a real failure and is not retried.
      const attempts = 5;
      for (let i = 1; ; i++) {
        try {
          const cluster = await couchbase.connect(created.connstr,
            { username: 'Administrator', password: 'password' });
          try {
            await kvOps(couchbase, cluster, `cbci-validate-${i}`);
          } finally {
            await cluster.close();
          }
          break;
        } catch (err) {
          if (i >= attempts || !(err instanceof couchbase.TimeoutError)) throw err;
          console.error(`[validate] KV attempt ${i}/${attempts} timed out (${err.message}); retrying`);
          await new Promise((r) => setTimeout(r, 1000 * i));
        }
      }
    } catch (err) {
      dumpCavesOutput(caves.proc);
      throw err;
    } finally {
      caves.sock.destroy();
      caves.proc.kill();
    }
  }

  // The package's own package.json. Requiring it directly is the common case; walking up
  // from the entry point covers a package whose `exports` map does not list it.
  function installedVersion(req, mod) {
    try {
      return req(`${mod}/package.json`).version;
    } catch {
      let dir = path.dirname(req.resolve(mod));
      for (;;) {
        const p = path.join(dir, 'package.json');
        if (fs.existsSync(p)) {
          const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
          if (pkg.name === mod) return pkg.version;
        }
        const up = path.dirname(dir);
        if (up === dir) return undefined;
        dir = up;
      }
    }
  }

  function checkSsl(meta) {
    const want = (env.CBCI_VALIDATE_SSL || '').toLowerCase();
    const got = String(meta.openssl_runtime || '');
    if (!want || !got) {
      console.error(`[validate] WARNING: cannot check the SSL backend (expected '${want}', `
        + `openssl_runtime '${got}')`);
      return;
    }
    const isBoring = /boringssl/i.test(got);
    if ((want === 'boringssl') !== isBoring) {
      console.error(`[validate] WARNING: expected ssl backend '${want}', `
        + `metadata openssl_runtime is '${got}'`);
    } else {
      console.log(`[validate] ssl backend: ${got}`);
    }
  }

  async function main() {
    const mod = env.CBCI_VALIDATE_IMPORT || 'couchbase';
    // Resolve from the install dir (cwd), never from this script's own location.
    const req = createRequire(path.join(process.cwd(), 'package.json'));
    let pkg;
    try {
      pkg = req(mod);
    } catch (err) {
      dumpAddons();
      throw err;
    }
    if (typeof pkg.connect !== 'function') throw new Error(`${mod} module missing connect()`);
    console.log(`[validate] required ${mod} OK, connect() present`);

    const version = installedVersion(req, mod);
    console.log(`[validate] installed ${mod}@${version}`);
    // Registry mode only: a local artifact is whatever was just packed, so there is nothing
    // to compare it against.
    const want = env.CBCI_PACKAGING_INDEX ? env.CBCI_VERSION : '';
    if (want && version !== want) {
      throw new Error(`installed ${mod}@${version}, expected ${want}`);
    }

    let meta;
    try {
      meta = JSON.parse(pkg.cbppMetadata);
    } catch (err) {
      throw new Error(`cbppMetadata is not valid JSON: ${err.message}`);
    }
    console.log(`[validate] cbppMetadata: ${JSON.stringify(meta)}`);
    checkSsl(meta);

    if (env.CBCI_VALIDATE_KV === 'true') {
      await kvRoundTrip(pkg);
      console.log('[validate] KV round-trip against GoCAVES OK');
    }
  }

  // Explicit exits: a lingering handle (a socket, the child) must not hang the stage, and a
  // failure must never end with exit 0.
  main().then(() => process.exit(0), (err) => {
    console.error('[validate] smoke failed:', err);
    process.exit(1);
  });
}

/** Source of the validate smoke check, as a standalone CommonJS script. */
export function validateSmokeScript() {
  return `'use strict';\n(${validateSmoke.toString()})();\n`;
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
 *     The two take their Node versions from different lists: validate from
 *     validateNodeVersions() (the pool, narrowed to the SDK's engines range), test_unit
 *     from testNodeVersions() (the selected runner's list), since the suite itself may need
 *     a newer Node than the package supports.
 * libc (manylinux/musllinux) is present only for linux/alpine units, never macos/windows.
 */
export function buildPlan(cfg) {
  const support = cfg.raw.support || {};
  const build = cfg.raw.build || {};
  const test = cfg.raw.test || {};
  const electronVersions = support.electron_versions || [];
  const runtimes = support.runtimes || ['node'];
  const arches = support.architectures || [];
  const platsByArch = support.platforms || {};
  const libcMap = build.libc || {};
  const ssl = String(build.ssl || 'boringssl').toLowerCase();
  const buildType = String(build.build_type || 'RelWithDebInfo');
  const napiVersion = build.napi_version ?? 8;
  const installTypes = test.install_types || ['prebuild', 'sdist'];
  const validateNodeVers = validateNodeVersions(cfg);
  const testNodeVers = testNodeVersions(cfg);

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

        if (runtime === 'electron' && electronVersions.length === 0) continue; // nothing declared to build

        const unit = keyed(platform, arch, libc);
        Object.assign(unit, { ssl, runtime, build_type: buildType });
        if (runtime === 'node') unit.napi_version = napiVersion;
        buildUnits.push(unit);

        const cells = (versions, out) => {
          for (const version of versions) {
            for (const itype of installTypes) {
              const cell = keyed(platform, arch, libc);
              Object.assign(cell, { runtime, version, install_type: itype });
              out.push(cell);
            }
          }
        };
        cells(runtime === 'electron' ? electronVersions : validateNodeVers, validateUnits);
        cells(runtime === 'electron' ? electronVersions : testNodeVers, testUnits);
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

// ---------------------------------------------------------------------------
// The SDK's engines.node range
// ---------------------------------------------------------------------------

/** Compile a package.json `engines.node` range into a predicate over Node versions.
 *
 * Hand-written rather than a semver dependency, so it covers only what an engines field
 * realistically holds: `||` alternatives of space-separated comparators, each one of
 * `>=` `>` `<=` `<` `=` `^` `~` or a bare version, with partial versions (`>=16`, `20`).
 * Anything else (hyphen ranges, `x`/`*` wildcards, prerelease tags) throws, since guessing
 * would quietly validate the wrong matrix. */
export function parseNodeRange(range) {
  const text = String(range).trim();
  const fail = (why) => { throw new Error(`unsupported engines.node range '${text}': ${why}`); };
  const alternatives = text.split('||').map((alt) => {
    const parts = alt.trim().replace(/(>=|<=|>|<|=|\^|~)\s+/g, '$1').split(/\s+/).filter(Boolean);
    if (!parts.length) fail('empty alternative');
    return parts.flatMap((part) => {
      const m = /^(>=|<=|>|<|=|\^|~)?v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$/.exec(part);
      if (!m) fail(`cannot read comparator '${part}'`);
      const [, op = '', M, mi, pa] = m;
      const major = Number(M);
      const minor = mi === undefined ? undefined : Number(mi);
      const patch = pa === undefined ? undefined : Number(pa);
      const low = `${major}.${minor ?? 0}.${patch ?? 0}`;
      // The first version past a partial: 20 -> 21.0.0, 20.17 -> 20.18.0.
      const past = minor === undefined ? `${major + 1}.0.0` : `${major}.${minor + 1}.0`;
      const full = patch !== undefined;
      switch (op) {
        case '>=': return [['>=', low]];
        case '<': return [['<', low]];
        case '>': return [full ? ['>', low] : ['>=', past]];
        case '<=': return [full ? ['<=', low] : ['<', past]];
        case '~': return [['>=', low], ['<', past]];
        case '^': {
          let upper;
          if (major > 0 || minor === undefined) upper = `${major + 1}.0.0`;
          else if (minor > 0 || patch === undefined) upper = `0.${minor + 1}.0`;
          else upper = `0.0.${patch + 1}`;
          return [['>=', low], ['<', upper]];
        }
        default: return full ? [['=', low]] : [['>=', low], ['<', past]];
      }
    });
  });
  const holds = (v, [op, bound]) => {
    const c = cmpVersionTriples(v, bound);
    return { '>=': c >= 0, '>': c > 0, '<=': c <= 0, '<': c < 0, '=': c === 0 }[op];
  };
  return (version) => alternatives.some((alt) => alt.every((cmp) => holds(version, cmp)));
}

/** The checkout's `engines.node`, or null when there is no SDK package.json to read (no
 * checkout, or a different package such as CI-core's own) or it declares none. */
export function projectEnginesNode(projectRoot) {
  const root = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
  const path = join(root, 'package.json');
  if (!existsSync(path)) return null;
  const pkg = JSON.parse(readFileSync(path, 'utf8'));
  if (pkg.name !== 'couchbase') return null;
  return pkg.engines?.node ? String(pkg.engines.node) : null;
}

/** The Node-API level the checkout compiles against: CMakeLists.txt's
 * `-DNAPI_VERSION=<n>`, the only place the level reaches the compiler. package.json's
 * `binary.napi_versions` is declarative (nothing reads it), so it is only cross-checked
 * here, to catch a bump that edits one file and not the other. Returns null when there is
 * no SDK checkout; throws when there is one but the level cannot be determined. */
export function projectNapiVersion(projectRoot) {
  const root = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
  const pkgPath = join(root, 'package.json');
  if (!existsSync(pkgPath)) return null;
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
  if (pkg.name !== 'couchbase') return null;

  const cmakePath = join(root, 'CMakeLists.txt');
  if (!existsSync(cmakePath)) throw new Error(`no CMakeLists.txt under ${root} to read NAPI_VERSION from`);
  const levels = [...readFileSync(cmakePath, 'utf8').matchAll(/-DNAPI_VERSION=(\d+)\b/g)]
    .map((m) => parseInt(m[1], 10));
  const distinct = [...new Set(levels)];
  if (distinct.length !== 1) {
    throw new Error(distinct.length === 0
      ? `no -DNAPI_VERSION=<n> in ${cmakePath}`
      : `conflicting -DNAPI_VERSION values in ${cmakePath}: ${distinct.join(', ')}`);
  }
  const napi = distinct[0];

  const declared = pkg.binary?.napi_versions;
  if (declared !== undefined && !(Array.isArray(declared) && declared.includes(napi))) {
    throw new Error(`CMakeLists.txt compiles NAPI_VERSION=${napi} but package.json `
      + `binary.napi_versions is ${JSON.stringify(declared)}; update them together`);
  }
  return napi;
}

/** Node versions the validate stage installs on: support.validate_node_versions (falling
 * back to node_versions), narrowed to the checkout's engines.node so a branch is only
 * validated where it claims to run. A VALIDATE_NODE_VERSIONS override is taken as given. */
export function validateNodeVersions(cfg, projectRoot) {
  const support = cfg.raw.support || {};
  const pool = support.validate_node_versions || support.node_versions || [];
  if (cfg.raw[PINNED_KEY]?.validate_node_versions) return pool;
  const range = projectEnginesNode(projectRoot);
  if (!range) return pool;
  return pool.filter(parseNodeRange(range));
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
  const PIN_VAR = {
    node_versions: 'NODE_VERSIONS',
    runner_node_versions: 'NODE_VERSIONS',
    validate_node_versions: 'VALIDATE_NODE_VERSIONS',
    electron_versions: 'ELECTRON_VERSIONS',
  };
  for (const rec of gates.indeterminate || []) {
    const pinned = Boolean(PIN_VAR[rec.domain] && (process.env[PIN_VAR[rec.domain]] || '').trim());
    const suffix = pinned ? ' (superseded by an explicit override)' : '';
    const advisory = pinned || SDIST_ONLY_GATES.includes(rec.domain);
    (advisory ? warnings : errors).push(`commit gate could not be evaluated: ${rec.msg}${suffix}`);
  }

  if (!support.node_versions || support.node_versions.length === 0) {
    errors.push('support.node_versions is empty (an override may have dropped everything)');
  }

  // --- validate pool vs the SDK's engines range ------------------------------
  const pinnedValidate = Boolean(cfg.raw[PINNED_KEY]?.validate_node_versions);
  let enginesRange = null;
  try {
    enginesRange = projectEnginesNode();
  } catch (err) {
    errors.push(`cannot read the SDK package.json: ${err.message}`);
  }
  if (!pinnedValidate && support.validate_node_versions && enginesRange === null) {
    warnings.push('no SDK package.json with engines.node (CBCI_PROJECT_ROOT or cwd), so the validate pool is not narrowed to it');
  }
  try {
    const pool = support.validate_node_versions || support.node_versions || [];
    if (pool.length && !validateNodeVersions(cfg).length) {
      errors.push(`engines.node '${enginesRange}' matches none of the validate pool [${pool.join(', ')}]; `
        + 'add a version it allows to support.validate_node_versions, or set VALIDATE_NODE_VERSIONS');
    }
  } catch (err) {
    errors.push(err.message);
  }

  const buildNode = build.node_version;
  if (buildNode !== undefined && buildNode !== null && !/^\d+\.\d+\.\d+$/.test(String(buildNode))) {
    errors.push(`build.node_version must be an exact x.y.z Node version (got ${JSON.stringify(buildNode)})`);
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
  errors.push(...caBundleErrors(build.ca_bundle));

  // --- test runners ----------------------------------------------------------
  const runners = configuredRunners(cfg);
  for (const r of runners) {
    if (!r.name || !r.cmd) errors.push(`test.runners entry ${JSON.stringify(r)} needs a name and a cmd`);
    if (r.junit !== undefined && !VALID_JUNIT_MODES.includes(r.junit)) {
      errors.push(`test runner '${r.name}': junit must be ${VALID_JUNIT_MODES.join('|')} (got '${r.junit}')`);
    }
    if (r.junit_env !== undefined) {
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(String(r.junit_env))) {
        errors.push(`test runner '${r.name}': junit_env must be an environment variable name (got ${JSON.stringify(r.junit_env)})`);
      } else if (r.junit !== 'inline') {
        errors.push(`test runner '${r.name}': junit_env needs junit: inline (got '${r.junit}')`);
      }
      if (/(^|\s)--reporter\b/.test(r.cmd || '')) {
        errors.push(`test runner '${r.name}': cmd passes --reporter, which replaces the reporter junit_env enables`);
      }
    }
    if (r.tier !== undefined && !VALID_TEST_TIERS.includes(r.tier)) {
      errors.push(`test runner '${r.name}': tier must be ${VALID_TEST_TIERS.join('|')} (got ${JSON.stringify(r.tier)})`);
    }
    if (r.min_node !== undefined && (!Number.isInteger(r.min_node) || r.min_node < 1)) {
      errors.push(`test runner '${r.name}': min_node must be a Node major (got ${JSON.stringify(r.min_node)})`);
    }
    // min_node trims an override; the runner's own list should never need trimming.
    const below = (r.node_versions || []).filter((v) => r.min_node && parseInt(String(v).split('.')[0], 10) < r.min_node);
    if (below.length) {
      errors.push(`test runner '${r.name}': node_versions [${below.join(', ')}] are below its min_node ${r.min_node}`);
    }
  }
  if (!runners.some((r) => !r.when_exists && !r.opt_in)) {
    errors.push('test.runners has no fallback (an entry with neither when_exists nor opt_in), so some checkouts match no runner');
  }
  // Selection reads the SDK tree. Without one every when_exists misses and the fallback
  // wins, which is a plausible-looking but possibly wrong plan.
  const root = process.env.CBCI_PROJECT_ROOT || process.cwd();
  if (runners.some((r) => r.when_exists) && !existsSync(join(root, 'test'))) {
    warnings.push(`no SDK test/ directory at ${root}, so test-runner selection falls back to the default runner`);
  }
  try {
    const r = testRunner(cfg);
    if (!testNodeVersions(cfg).length) {
      errors.push(`test runner '${r.name}' has no Node version to test on`
        + (r.min_node ? ` (it needs Node >= ${r.min_node})` : ''));
    }
  } catch (err) {
    errors.push(err.message);
  }

  const validate = cfg.raw.test?.validate || {};
  if (validate.yarn_linker !== undefined && !VALID_YARN_LINKERS.includes(validate.yarn_linker)) {
    errors.push(`test.validate.yarn_linker must be ${VALID_YARN_LINKERS.join('|')} (got '${validate.yarn_linker}')`);
  }

  const napi = build.napi_version;
  if (napi !== undefined && (!Number.isInteger(napi) || napi < 1)) {
    errors.push(`build.napi_version must be a positive integer (got ${JSON.stringify(napi)})`);
  } else if (napi !== undefined) {
    // The whole "ONE prebuild serves every Node version" claim rests on every configured
    // version implementing the compiled Node-API level. A version below it gets a binary it
    // cannot load, and nothing before the validate stage says so.
    const nodeVersions = [...new Set([
      ...(support.node_versions || []),
      ...(support.validate_node_versions || []),
      ...runners.flatMap((r) => r.node_versions || []),
    ])];
    const unknown = [];
    for (const v of nodeVersions) {
      const ok = nodeSupportsNapi(v, napi);
      if (ok === null) {
        unknown.push(v);
      } else if (!ok) {
        errors.push(
          `configured Node version '${v}' does not implement Node-API ${napi} `
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

    // build.napi_version is the highest level any supported branch compiles, so the check
    // above covers every branch. A checkout above it would escape the check.
    let compiled = null;
    try {
      compiled = projectNapiVersion();
    } catch (err) {
      errors.push(err.message);
    }
    if (compiled !== null && compiled > napi) {
      errors.push(`the checkout compiles Node-API ${compiled} but build.napi_version is ${napi}; `
        + 'raise build.napi_version so the configured Node versions are checked against it');
    }
  }

  return { errors, warnings };
}

// ---------------------------------------------------------------------------
// Test-command generation
// ---------------------------------------------------------------------------

const VALID_JUNIT_MODES = ['mocha-multi-reporters', 'inline'];
export const VALID_TEST_TIERS = ['fast', 'slow', 'nightly'];

/** The configured test runners, in selection order. `test.runners` is an ordered list;
 * a config that still has only `test.mocha` is read as a single mocha runner. */
function configuredRunners(cfg) {
  const test = cfg.raw.test || {};
  if (Array.isArray(test.runners) && test.runners.length) return test.runners;
  return [{ name: 'mocha', cmd: 'npm run test', junit: 'mocha-multi-reporters', ...(test.mocha || {}) }];
}

/** Pick the test runner for the SDK checkout: CBCI_TEST_RUNNER names one outright,
 * otherwise the first runner that is not `opt_in` and whose `when_exists` file is present
 * (or that has no `when_exists`).
 *
 * Keyed on files rather than a commit gate, so the cutover patchset selects its own runner
 * before its sha exists, and maintenance branches keep the runner their tree carries.
 * Throws when CBCI_TEST_RUNNER names an unknown runner or one whose file is missing. */
export function testRunner(cfg, projectRoot) {
  const root = projectRoot || process.env.CBCI_PROJECT_ROOT || process.cwd();
  const runners = configuredRunners(cfg);
  const present = (r) => !r.when_exists || existsSync(join(root, r.when_exists));
  const forced = (process.env.CBCI_TEST_RUNNER || '').trim();
  if (forced) {
    const r = runners.find((x) => x.name === forced);
    if (!r) {
      throw new Error(`CBCI_TEST_RUNNER='${forced}' is not a configured test runner (${runners.map((x) => x.name).join(', ')})`);
    }
    if (!present(r)) {
      throw new Error(`CBCI_TEST_RUNNER='${forced}' needs ${r.when_exists}, which is not in the checkout at ${root}`);
    }
    return r;
  }
  const r = runners.find((x) => !x.opt_in && present(x));
  if (!r) throw new Error(`no test runner matches the checkout at ${root}; add a fallback runner without when_exists`);
  return r;
}

/** Node versions the selected runner tests on: NODE_VERSIONS when set, else the runner's
 * own node_versions, else support.node_versions. Anything below the runner's `min_node`
 * major is dropped, so an override cannot put the suite on a Node it cannot start on. */
export function testNodeVersions(cfg, projectRoot) {
  const runner = testRunner(cfg, projectRoot);
  const pinned = cfg.raw[PINNED_KEY]?.node_versions;
  const versions = (!pinned && runner.node_versions) || cfg.raw.support?.node_versions || [];
  const floor = runner.min_node;
  if (!floor) return versions;
  return versions.filter((v) => parseInt(String(v).split('.')[0], 10) >= floor);
}

/** The test-unit command line for the selected runner. One line, since each runner is a
 * single suite run, honoring the CBCI_TEST_COMMAND / CBCI_TEST_ARGS overrides. */
export function testCmds(cfg) {
  const overrideCmd = process.env.CBCI_TEST_COMMAND;
  const overrideArgs = process.env.CBCI_TEST_ARGS || '';
  if (overrideCmd) {
    return [`${overrideCmd} ${overrideArgs}`.trim()];
  }
  const cmd = testRunner(cfg).cmd || 'npm run test';
  return [overrideArgs ? `${cmd} ${overrideArgs}`.trim() : cmd];
}

/** How the test run produces xunit.xml, for tasks.sh/tasks.ps1:
 *   mocha-multi-reporters  the task installs that reporter and appends it
 *   inline                 the runner's cmd writes xunit.xml itself; the task only checks it
 *   none                   nothing to vouch for (a CBCI_TEST_COMMAND override of an inline
 *                          runner may not write it) */
export function testJunit(cfg) {
  const junit = testRunner(cfg).junit || 'none';
  if (junit === 'inline' && process.env.CBCI_TEST_COMMAND) return 'none';
  return junit;
}

/** The env var the task points at xunit.xml's absolute path, or '' when the runner's cmd
 * names the file itself. Set under a CBCI_TEST_COMMAND override too: it costs nothing, and
 * an override that keeps the suite's config still writes the same file. */
export function testJunitEnv(cfg) {
  return testRunner(cfg).junit_env || '';
}

/** The CNTIER for the run: CBCI_TEST_TIER (the TEST_TIER job param), else the runner's
 * `tier`, else '' so the suite keeps its own default. */
export function testTier(cfg) {
  const forced = (process.env.CBCI_TEST_TIER || '').trim();
  if (forced) {
    if (!VALID_TEST_TIERS.includes(forced)) {
      throw new Error(`CBCI_TEST_TIER must be ${VALID_TEST_TIERS.join('|')} (got '${forced}')`);
    }
    return forced;
  }
  return testRunner(cfg).tier || '';
}

/** Whether the test agent needs a `java` runtime (CouchbaseMock.jar fallback). */
export function requiresJava(cfg) {
  return Boolean(testRunner(cfg).require_java);
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
    'prebuild-select-env|ca-bundle-env <sdist|prebuild|package>|napi-version|validate-env|validate-smoke|publish-env|test-cmds|test-junit|test-junit-env|test-tier|requires-java>\n'
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

  // The sdist is the one stage with git that reads the normalize gate, so it narrates it.
  const reportDomains = cmd === 'ca-bundle-env' && positionals[1] === 'sdist'
    ? SDIST_ONLY_GATES : GATE_REPORT_DOMAINS[cmd] || [];
  const cfg = loadConfig(values.config, reportDomains);

  try {
    return dispatch(cmd, positionals, cfg);
  } catch (err) {
    process.stderr.write(`ERROR: ${err.message}\n`);
    return 1;
  }
}

function dispatch(cmd, positionals, cfg) {
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
    case 'ca-bundle-env': {
      const stage = positionals[1];
      // An unevaluated normalize gate would silently pack a bundle the core cannot parse.
      const unresolved = stage === 'sdist'
        ? (cfg.raw[GATE_KEY]?.indeterminate || []).filter((r) => SDIST_ONLY_GATES.includes(r.domain)) : [];
      if (unresolved.length) {
        for (const r of unresolved) process.stderr.write(`ERROR: commit gate could not be evaluated: ${r.msg}\n`);
        return 1;
      }
      emitPairs(caBundleEnv(cfg, stage));
      break;
    }
    case 'napi-version': {
      const napi = projectNapiVersion();
      if (napi === null) {
        process.stderr.write('ERROR: napi-version: no couchbase package.json (CBCI_PROJECT_ROOT or cwd)\n');
        return 1;
      }
      console.log(napi);
      break;
    }
    case 'validate-env':
      try {
        emitPairs(validateEnv(cfg));
      } catch (err) {
        process.stderr.write(`ERROR: ${err.message}\n`);
        return 1;
      }
      break;
    case 'validate-smoke':
      process.stdout.write(validateSmokeScript());
      break;
    case 'publish-env':
      emitPairs(publishEnv(cfg));
      break;
    case 'test-cmds':
      for (const line of testCmds(cfg)) console.log(line);
      break;
    case 'test-junit':
      console.log(testJunit(cfg));
      break;
    case 'test-junit-env':
      console.log(testJunitEnv(cfg));
      break;
    case 'test-tier':
      console.log(testTier(cfg));
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
