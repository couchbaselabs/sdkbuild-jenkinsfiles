#!/usr/bin/env node
// jenkins.js — the Jenkins ADAPTER for the Couchbase Node.js SDK (couchnode) CI-core.
//
// Translates the vendor-NEUTRAL plan from `engine.js` into Jenkins jobs, attaching the
// ONE deployment-specific thing the core deliberately does not know: runner agent
// labels (../CONVENTIONS.md §4). The neutral core (engine.js / tasks.sh) never carries
// a label; this file is the sole place they live for Jenkins. engine.js must NEVER
// import this module (core can't depend on an adapter).
//
// UNLIKE Python's jenkins.py: Node's legacy pipeline builds NATIVELY on distro-labeled
// agents (centos7, almalinux8, alpine, qe-grav2-amzn2, ...) — there is no manylinux-
// style on-demand container image. So this adapter has no `image`/`tasks.sh image`
// concept; a build job is just "run tasks.sh prebuild on the right label".
//
// Electron is genuinely different from Node here, confirmed against the legacy
// pipeline's own comment: Node prebuilds are N-API (ABI-stable across every configured
// node_version — ONE build per (platform,arch,ssl)), but Electron prebuilds are NOT
// N-API ("we don't have the N-API luxury" — legacy getPrebuildTagsElectron) — they are
// classic NODE_MODULE_VERSION ABI, keyed by which Node version Electron bundles. So one
// neutral electron build UNIT from engine.js can expand into MULTIPLE Jenkins build
// jobs here — one per distinct ABI floor actually required by the configured
// electron_versions (see `_electronBuildBuckets`).
//
// CLI:
//     node jenkins.js tags     # emit the Jenkins job plan (JSON) the groovy consumes

import { parseArgs } from 'node:util';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as engine from './engine.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Minimum supported Node major version per (platform, arch) on Jenkins agents.
// e.g. Alpine ARM64 agents on Jenkins ship Node 18+ (no Node 16 agent exists).
const MIN_NODE_VERSION = {
  'alpine:arm64': 18,
};

function getMinNodeMajor(platform, arch) {
  const key = `${platform}:${normArchKey(arch)}`;
  return MIN_NODE_VERSION[key] || 0;
}

function filterNodeVersionsForPlatform(nodeVersions, platform, arch) {
  const minMajor = getMinNodeMajor(platform, arch);
  if (!minMajor) return nodeVersions;
  return nodeVersions.filter((v) => {
    const major = parseInt(String(v).split('.')[0], 10);
    return major >= minMajor;
  });
}

// EDIT FOR YOUR JENKINS — the ONE deployment-specific thing (CONVENTIONS §4).
// The "default"/oldest-compatible label per (platform, arch) for the boringssl/N-API
// node build — ported from the legacy getPrebuildTagsBoringSSL's glibc-floor picks
// (centos7 = oldest x64 glibc; qe-grav2-amzn2 = oldest aarch64 glibc). macOS/Windows
// build natively on their own arch-specific agent (no floor concept).
const JENKINS_LABELS = {
  'linux:x64': 'centos7',
  'linux:arm64': 'qe-grav2-amzn2',
  'alpine:x64': 'alpine',
  'alpine:arm64': (version) => {
    if (!version) return 'alpine-node-18-arm64';
    const major = parseInt(String(version).split('.')[0], 10);
    return `alpine-node-${major}-arm64`;
  },
  'macos:x64': 'macos',
  'macos:arm64': 'm1',
  'windows:x64': 'windows',
};

// Electron<->Node ABI compat table — REPLACES the legacy pipeline's hardcoded
// `getElectronNodeVersion()` if/else (duplicated independently 3x, one cutoff, no
// room for future Electron generations). Ascending by maxElectronMajor; the first
// entry whose maxElectronMajor >= the target Electron major wins. Ported verbatim
// from the one confirmed real cutoff (Electron 23): below it, Electron bundles a
// Node ABI compatible with Node 16 (built against 16.16.0); at/above it, Node 18
// (built against 18.16.0). Each floor also carries the linux glibc-floor label picks,
// ported from getPrebuildTagsElectron (centos7/almalinux8 x64, qe-grav2-amzn2/
// qe-ubuntu20-arm64 arm64) — Electron >= 23 needs glibc >= 2.28, which centos7/amzn2
// don't have, hence the almalinux8/qe-ubuntu20-arm64 floor bump.
//
// Simplification vs. the legacy pipeline (documented, not silently dropped): the
// legacy code additionally deduplicates by the ACTUAL Electron ABI number (a live
// `node -p "require('node-abi').getAbi(v,'electron')"` shell-out per version). This
// table buckets by MAJOR VERSION instead, which is coarser (never wrong — a coarser
// bucket just builds one extra prebuild, it doesn't ship an incompatible one — but
// could produce more buckets than the live ABI lookup would). Revisit if/when a
// dependency on the `node-abi` package is acceptable at tag-generation time.
//
// `nodeVersion` here is a LABEL/BUCKETING key only (which floor a build lands on) —
// ground-truthed against the legacy pipeline's own build invocation (line ~296-298:
// `envs.add("CN_PREBUILD_RUNTIME_VERSION=${electronVersion}")`), the value actually
// passed to cmake-js is the real Electron version being built (see
// `electronBuildBuckets`'s `representative`), never this Node version string.
const ELECTRON_NODE_ABI_TABLE = [
  {
    maxElectronMajor: 22,
    nodeVersion: '16.16.0',
    linuxLabel: { x64: 'centos7', arm64: 'qe-grav2-amzn2' },
  },
  {
    maxElectronMajor: Infinity,
    nodeVersion: '18.16.0',
    linuxLabel: { x64: 'almalinux8', arm64: 'qe-ubuntu20-arm64' },
  },
];

// Platform FAMILIES — the validate/test fan-out. A PLATFORMS token is a family the user
// lists (the historical distro names); each fans out to an abstract platform + the
// concrete agent labels PER ARCH. Ported from the legacy setBuildTags() arch remap.
// ubuntu22/ubuntu24/rhel9 are arm64-only (no x64 agent exists for those families —
// JSCBC-1726 for ubuntu24's x64 gap specifically). A label edit here is a CI-core
// change (this file is sha256-pinned): the cost of keeping the map in one unit-tested
// place instead of 3 independently-drifting groovy copies.
const PLATFORM_FAMILIES = {
  //  family          abstract    x64 labels        arm64 labels
  almalinux8: { platform: 'linux', x64: ['almalinux8'], arm64: [] },
  centos7: { platform: 'linux', x64: ['centos7'], arm64: [] },
  amzn2: { platform: 'linux', x64: ['amzn2'], arm64: ['qe-grav2-amzn2', 'qe-grav3-amzn2', 'qe-grav4-amzn2'] },
  ubuntu20: { platform: 'linux', x64: [], arm64: ['qe-ubuntu20-arm64'] },
  ubuntu22: { platform: 'linux', x64: [], arm64: ['qe-ubuntu22-arm64'] },
  ubuntu24: { platform: 'linux', x64: [], arm64: ['qe-ubuntu24-arm64'] },
  rhel9: { platform: 'linux', x64: [], arm64: ['qe-rhel9-arm64'] },
  alpine: {
    platform: 'alpine',
    x64: ['alpine'],
    arm64: (nodeVersion) => {
      if (!nodeVersion) return ['alpine-node-18-arm64', 'alpine-node-20-arm64', 'alpine-node-22-arm64'];
      const major = parseInt(String(nodeVersion).split('.')[0], 10);
      return [`alpine-node-${major}-arm64`];
    },
  },
  macos: { platform: 'macos', x64: ['macos'], arm64: ['m1'] },
  windows: { platform: 'windows', x64: ['windows'], arm64: [] },
};

const ABSTRACT_PLATFORMS = new Set(Object.values(PLATFORM_FAMILIES).map((f) => f.platform));

function normArchKey(arch) {
  return arch === 'aarch64' ? 'arm64' : arch === 'x86_64' ? 'x64' : arch;
}

function getFamilyLabels(fam, akey, nodeVersion) {
  const val = fam[akey];
  if (typeof val === 'function') {
    return val(nodeVersion);
  }
  return val || [];
}

/** Resolve a PLATFORMS token to its abstract platform. Accepts an abstract platform
 * (linux/alpine/macos/windows), a family name (amzn2), or a raw agent label
 * (qe-grav2-amzn2, m1). Returns null if unrecognized. */
function platformTokenToAbstract(token) {
  const t = token.toLowerCase();
  if (ABSTRACT_PLATFORMS.has(t)) return t;
  if (PLATFORM_FAMILIES[t]) return PLATFORM_FAMILIES[t].platform;
  if (t.startsWith('alpine-node-') || t.startsWith('alpine-')) return 'alpine';
  for (const fam of Object.values(PLATFORM_FAMILIES)) {
    for (const akey of ['x64', 'arm64']) {
      const labels = getFamilyLabels(fam, akey, null);
      if (labels.some((lbl) => lbl.toLowerCase() === t)) return fam.platform;
    }
  }
  return null;
}

/** Concrete agent labels for a (platform, arch) validate/test cell. `requested` is the
 * lowercased PLATFORMS list (empty = no filter -> every label on this cell). */
function checkLabels(platform, arch, requested, nodeVersion) {
  const akey = normArchKey(arch);
  const famsHere = Object.entries(PLATFORM_FAMILIES).filter(([, f]) => f.platform === platform);
  const allHere = famsHere.flatMap(([, f]) => getFamilyLabels(f, akey, nodeVersion));
  let chosen;
  if (!requested.length) {
    chosen = [...allHere];
  } else {
    chosen = [];
    const allHereLc = new Set(allHere.map((l) => l.toLowerCase()));
    for (const t of requested) {
      if (t === platform) {
        chosen.push(...allHere);
      } else if (PLATFORM_FAMILIES[t] && PLATFORM_FAMILIES[t].platform === platform) {
        chosen.push(...getFamilyLabels(PLATFORM_FAMILIES[t], akey, nodeVersion));
      } else if (allHereLc.has(t)) {
        chosen.push(...allHere.filter((l) => l.toLowerCase() === t));
      } else if (t.startsWith('alpine-node-') || t.startsWith('alpine-')) {
        chosen.push(...allHere.filter((l) => l.toLowerCase() === t));
      }
    }
  }
  return [...new Set(chosen)];
}

function jenkinsLabel(platform, arch, nodeVersion) {
  const akey = normArchKey(arch);
  const key = `${platform}:${akey}`;
  const labelDef = JENKINS_LABELS[key];
  if (typeof labelDef === 'function') {
    return labelDef(nodeVersion);
  }
  if (labelDef) {
    return labelDef;
  }
  process.stderr.write(`WARNING: no Jenkins label for (${platform}, ${arch}); using '${platform}'\n`);
  return platform;
}

/** The Electron<->Node ABI floor entry for a given Electron major version. */
function electronFloorFor(electronMajor) {
  return ELECTRON_NODE_ABI_TABLE.find((e) => electronMajor <= e.maxElectronMajor);
}

/** Group configured electron_versions by which ABI floor they need (dedup so each
 * distinct floor becomes exactly ONE build job, mirroring the legacy pipeline's own
 * "collapse to one binary per floor" trick — see ELECTRON_NODE_ABI_TABLE's docstring
 * for the coarser-than-legacy caveat). Returns floors in table order, each with the
 * list of configured versions it covers (informational, for the job's env/logging). */
/** Numeric ascending compare of two "x.y.z" version strings (no semver prerelease
 * handling needed here — electron_versions are always plain release versions). */
function compareVersions(a, b) {
  const at = String(a).split('.').map(Number);
  const bt = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(at.length, bt.length); i++) {
    const d = (at[i] || 0) - (bt[i] || 0);
    if (d) return d;
  }
  return 0;
}

function electronBuildBuckets(electronVersions) {
  const byFloorIdx = new Map();
  for (const v of electronVersions) {
    const major = parseInt(String(v).split('.')[0], 10);
    const floor = electronFloorFor(major);
    if (!floor) continue;
    const idx = ELECTRON_NODE_ABI_TABLE.indexOf(floor);
    if (!byFloorIdx.has(idx)) byFloorIdx.set(idx, { floor, versions: [] });
    byFloorIdx.get(idx).versions.push(v);
  }
  // Representative version = the lowest in the bucket (mirrors the legacy
  // pipeline's own pbTags dedup, which keys each bucket by the FIRST electron
  // version it encounters for that floor — see getPrebuildTagsElectron). This is
  // the ACTUAL version cmake-js builds against (CN_PREBUILD_RUNTIME_VERSION); the
  // floor's nodeVersion string is a bucketing/label key only, never a build input.
  return [...byFloorIdx.keys()].sort((a, b) => a - b).map((idx) => {
    const entry = byFloorIdx.get(idx);
    const versions = [...entry.versions].sort(compareVersions);
    return { floor: entry.floor, versions, representative: versions[0] };
  });
}

// Node<->OpenSSL ABI floor table — ground-truthed against the legacy pipeline's
// getPrebuildTagsOpenSSL(): ONLY applies when build.ssl == 'openssl'. BoringSSL builds
// never fan out by node_versions (getPrebuildTagsBoringSSL always collapses to ONE
// build using the single oldest configured node_versions entry, regardless of any
// cutoff) — this table is the OpenSSL-specific exception: pre-18 and 18+ Node link
// against different OpenSSL majors (1.1 vs 3), so each side of that cutoff needs its
// own prebuild. Same shape as ELECTRON_NODE_ABI_TABLE; macOS/Windows keep their direct
// label but still split into two jobs, exactly like the electron case.
const OPENSSL_NODE_FLOOR_TABLE = [
  // `id` (not `maxNodeMajor`) is what jobs carry — Infinity doesn't survive
  // JSON.stringify (becomes `null`), which would make the groovy consumer's job JSON
  // useless for identifying the top-open-ended floor.
  { id: '<18', maxNodeMajor: 17, linuxLabel: { x64: 'centos7', arm64: 'qe-grav2-amzn2' } },
  { id: '18+', maxNodeMajor: Infinity, linuxLabel: { x64: 'almalinux8', arm64: 'qe-ubuntu20-arm64' } },
];

function opensslFloorFor(nodeMajor) {
  return OPENSSL_NODE_FLOOR_TABLE.find((e) => nodeMajor <= e.maxNodeMajor);
}

/** Group configured node_versions by which OpenSSL floor they need (openssl builds
 * only). Mirrors electronBuildBuckets's shape/dedup logic. */
function opensslBuildBuckets(nodeVersions) {
  const byFloorIdx = new Map();
  for (const v of nodeVersions) {
    const major = parseInt(String(v).split('.')[0], 10);
    const floor = opensslFloorFor(major);
    if (!floor) continue;
    const idx = OPENSSL_NODE_FLOOR_TABLE.indexOf(floor);
    if (!byFloorIdx.has(idx)) byFloorIdx.set(idx, { floor, versions: [] });
    byFloorIdx.get(idx).versions.push(v);
  }
  return [...byFloorIdx.keys()].sort((a, b) => a - b).map((idx) => {
    const entry = byFloorIdx.get(idx);
    const versions = [...entry.versions].sort(compareVersions);
    return { floor: entry.floor, versions, representative: versions[0] };
  });
}

function requestedTokens() {
  const raw = (process.env.PLATFORMS || '').trim();
  return raw ? raw.replace(/,/g, ' ').split(/\s+/).map((t) => t.toLowerCase()).filter(Boolean) : [];
}

function abstractPlatforms(tokens) {
  const out = new Set();
  for (const t of tokens) {
    const abstract = platformTokenToAbstract(t);
    if (abstract === null) {
      process.stderr.write(`WARNING: PLATFORMS token '${t}' is not a known Jenkins platform/label; ignoring\n`);
    } else {
      out.add(abstract);
    }
  }
  return out;
}

/** One build job per NODE unit; the electron units each expand into one job PER
 * required ABI floor bucket, using electron_versions from the (already narrowed)
 * config. Stash keys are disambiguated by everything that can collide on a shared
 * label (mirrors Python's lesson: linux/alpine sharing a docker label) — here,
 * platform + arch + runtime + (for electron) the floor's node-version-string. */
function buildJobsFromPlan(plan, cfg) {
  const jobs = [];
  const electronVersions = cfg.raw.support?.electron_versions || [];
  const nodeVersions = cfg.raw.support?.node_versions || [];
  const ssl = String(cfg.raw.build?.ssl || 'boringssl').toLowerCase();

  for (const u of plan.build.units) {
    const { platform, arch, libc } = u;
    if (u.runtime === 'node') {
      if (ssl === 'openssl') {
        // OpenSSL: fan out by the Node-18 ABI floor (see OPENSSL_NODE_FLOOR_TABLE) —
        // one job per floor actually required by the configured node_versions.
        for (const { floor, versions, representative } of opensslBuildBuckets(nodeVersions)) {
          let label;
          if (platform === 'linux' || platform === 'alpine') {
            label = floor.linuxLabel[normArchKey(arch)] || jenkinsLabel(platform, arch);
          } else {
            label = jenkinsLabel(platform, arch);
          }
          const env = {
            CBCI_BUILD_PLATFORM: platform, CBCI_BUILD_ARCH: arch, CBCI_BUILD_RUNTIME: 'node',
            CBCI_BUILD_NODE_VERSION: representative,
          };
          if (libc) env.CBCI_BUILD_LIBC = libc;
          jobs.push({
            label, platform, arch, runtime: 'node',
            node_abi_floor: floor.id,
            node_version: representative,
            node_versions: versions,
            stash_key: `prebuild-${platform}-${arch}-node-${representative}`,
            env,
          });
        }
        continue;
      }

      // BoringSSL (the default): ONE job per (platform, arch), representative = the
      // single oldest configured node_versions entry (ground-truthed against
      // getPrebuildTagsBoringSSL, which always collapses to this regardless of any
      // node-major cutoff — N-API makes it ABI-compatible with every newer major too).
      // Filter out node versions below the platform floor (e.g. Node 16 on alpine:arm64).
      const validVersions = filterNodeVersionsForPlatform(nodeVersions, platform, arch);
      const representative = validVersions.length ? [...validVersions].sort(compareVersions)[0] : undefined;
      const env = { CBCI_BUILD_PLATFORM: platform, CBCI_BUILD_ARCH: arch, CBCI_BUILD_RUNTIME: 'node' };
      if (libc) env.CBCI_BUILD_LIBC = libc;
      if (representative) env.CBCI_BUILD_NODE_VERSION = representative;
      jobs.push({
        label: jenkinsLabel(platform, arch, representative),
        platform, arch, runtime: 'node',
        node_version: representative,
        stash_key: `prebuild-${platform}-${arch}-node`,
        env,
      });
      continue;
    }

    // electron: expand into one job per required ABI floor. The floor's nodeVersion
    // is a label/stash-key bucketing detail ONLY; `representative` (the lowest
    // configured Electron version in the bucket) is the actual build input.
    const buckets = electronBuildBuckets(electronVersions);
    for (const { floor, versions, representative } of buckets) {
      let label;
      if (platform === 'linux' || platform === 'alpine') {
        label = floor.linuxLabel[normArchKey(arch)] || jenkinsLabel(platform, arch, floor.nodeVersion);
      } else {
        label = jenkinsLabel(platform, arch, floor.nodeVersion);
      }
      const env = {
        CBCI_BUILD_PLATFORM: platform,
        CBCI_BUILD_ARCH: arch,
        CBCI_BUILD_RUNTIME: 'electron',
        CBCI_BUILD_ELECTRON_VERSION: representative,
      };
      if (libc) env.CBCI_BUILD_LIBC = libc;
      jobs.push({
        label,
        platform, arch, runtime: 'electron',
        electron_abi_floor: floor.nodeVersion,
        electron_version: representative,
        electron_versions: versions,
        stash_key: `prebuild-${platform}-${arch}-electron-${floor.nodeVersion}`,
        env,
      });
    }
  }
  return jobs;
}

/** validate/test cells: PLATFORMS filters the fan-out exactly like Python's
 * _check_jobs — a distro family (amzn2) selects its labels for this cell's arch, so
 * listing amzn2 tests its x64 box AND its Graviton boxes. Empty PLATFORMS = every
 * label on the cell's platform. */
function checkJobs(units, requested) {
  const jobs = [];
  for (const u of units) {
    if (u.runtime === 'node' && u.version) {
      const minMajor = getMinNodeMajor(u.platform, u.arch);
      const major = parseInt(String(u.version).split('.')[0], 10);
      if (minMajor && major < minMajor) {
        continue; // Skip node versions below minimum floor for this platform
      }
    }
    for (const label of checkLabels(u.platform, u.arch, requested, u.version)) {
      const env = {
        CBCI_TEST_RUNTIME: u.runtime,
        CBCI_TEST_VERSION: u.version,
        CBCI_INSTALL_TYPE: u.install_type,
      };
      const job = { label };
      for (const k of ['platform', 'arch', 'libc', 'runtime', 'version', 'install_type']) {
        if (k in u) job[k] = u[k];
      }
      job.env = env;
      jobs.push(job);
    }
  }
  return jobs;
}

const JENKINS_SDIST_LABEL = 'ubuntu20'; // native build node (cmake + C++ toolchain)

/** Full pipeline: build the neutral plan (narrowed to the requested platforms) and
 * translate it into the Jenkins job plan the groovy consumes. */
export function tags(configPath) {
  const requested = requestedTokens();
  const abstract = abstractPlatforms(requested);
  const saved = process.env.PLATFORMS;
  delete process.env.PLATFORMS;
  let cfg;
  try {
    cfg = engine.loadConfig(configPath);
  } finally {
    if (saved !== undefined) process.env.PLATFORMS = saved;
  }
  if (abstract.size) engine.narrowToPlatforms(cfg, abstract);
  const plan = engine.buildPlan(cfg);

  return {
    sdist: { label: JENKINS_SDIST_LABEL, stage: 'sdist', env: {} },
    build: buildJobsFromPlan(plan, cfg),
    validate: checkJobs(plan.validate.units, requested),
    test_unit: checkJobs(plan.test_unit.units, requested),
  };
}

// ---------------------------------------------------------------------------
// CLI dispatch
// ---------------------------------------------------------------------------

function usage() {
  process.stderr.write('usage: jenkins.js [--config <path>] tags\n');
}

export function main(argv = process.argv.slice(2)) {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { config: { type: 'string' } },
    allowPositionals: true,
  });
  const cmd = positionals[0];
  if (cmd === 'tags') {
    console.log(JSON.stringify(tags(values.config)));
    return 0;
  }
  usage();
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
