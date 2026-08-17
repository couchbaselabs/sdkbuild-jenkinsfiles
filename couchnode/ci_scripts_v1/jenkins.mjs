#!/usr/bin/env node
// jenkins.mjs - the Jenkins ADAPTER for the Couchbase Node.js SDK (couchnode) CI-core.
//
// Translates the vendor-NEUTRAL plan from `engine.mjs` into Jenkins jobs, attaching the
// ONE deployment-specific thing the core deliberately does not know: runner agent labels
// (../CONVENTIONS.md). The neutral core (engine.mjs / tasks.sh) never carries a label;
// this file is the sole place they live for Jenkins. engine.mjs must NEVER import this
// module (core cannot depend on an adapter).
//
// Builds run NATIVELY on distro-labeled agents (centos7, almalinux8, alpine,
// qe-grav2-amzn2, ...) with no on-demand container image, so this adapter has no `image`
// concept: a build job is just "run tasks.sh prebuild on the right label".
//
// Electron is genuinely different from Node here. Node prebuilds are N-API, ABI-stable
// across every configured node_version, so ONE build covers a (platform, arch, ssl).
// Electron prebuilds are classic NODE_MODULE_VERSION ABI, keyed by which Node version
// Electron bundles. So one neutral electron build UNIT from engine.mjs can expand into
// MULTIPLE Jenkins build jobs, one per distinct ABI floor the configured
// electron_versions actually require (see `electronBuildBuckets`).
//
// CLI:
//     node jenkins.mjs tags     # emit the Jenkins job plan (JSON) the groovy consumes

import { parseArgs } from 'node:util';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as engine from './engine.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Alpine ARM64 has no general-purpose agent: the fleet is one pinned-Node box per major.
// This list is the SINGLE source of truth for which ones exist: both the label range
// table and PLATFORM_FAMILIES.alpine.arm64 derive from it, so no code path can mint a
// label like `alpine-node-16-arm64` that no agent answers.
const ALPINE_ARM64_NODE_MAJORS = [18, 20, 22];
const alpineArm64Label = (major) => `alpine-node-${major}-arm64`;

/** The alpine arm64 agent for this Node version, or [] when no such agent exists. */
function alpineArm64Labels(nodeVersion) {
  if (!nodeVersion) return ALPINE_ARM64_NODE_MAJORS.map(alpineArm64Label);
  const major = parseInt(String(nodeVersion).split('.')[0], 10);
  return ALPINE_ARM64_NODE_MAJORS.includes(major) ? [alpineArm64Label(major)] : [];
}

// Node major-version range supported by each Jenkins AGENT LABEL: the glibc >= 2.28 floor
// Node 18+ needs, which centos7/amzn2/Graviton agents lack, plus alpine-arm64's 18..22
// window.
//
// Keyed on LABEL, not (platform, arch), because one abstract platform+arch spans agents
// with DIFFERENT floors: linux:x64 covers almalinux8 (all versions) AND centos7/amzn2
// (Node 16 only). A (platform, arch) key cannot express that, and `max` cannot be
// expressed by a min-only table.
//
// DELIBERATELY Jenkins-only, since this is the adapter (CONVENTIONS.md): these are facts
// about OUR agent fleet's distros, not about the SDK. GHA's runner images have entirely
// different floors, so gha.mjs will need its OWN table, or none at all since ubuntu-latest
// and friends carry no comparable glibc gap. engine.mjs must never learn about labels.
const LABEL_NODE_MAJORS = {
  // glibc < 2.28 -> Node 18+ will not run
  centos7: { max: 17 },
  amzn2: { max: 17 },
  'qe-grav2-amzn2': { max: 17 },
  'qe-grav3-amzn2': { max: 17 },
  'qe-grav4-amzn2': { max: 17 },
  // each alpine arm64 agent runs exactly the Node major it is pinned to
  ...Object.fromEntries(
    ALPINE_ARM64_NODE_MAJORS.map((m) => [alpineArm64Label(m), { min: m, max: m }]),
  ),
};

/** Does agent `label` support this Node version? Unlisted labels support everything. */
function labelSupportsNodeVersion(label, version) {
  const range = LABEL_NODE_MAJORS[label];
  if (!range || !version) return true;
  const major = parseInt(String(version).split('.')[0], 10);
  if (Number.isNaN(major)) return true;
  if (range.min !== undefined && major < range.min) return false;
  if (range.max !== undefined && major > range.max) return false;
  return true;
}

/** The Node major window a BUILD on (platform, arch) must stay inside.
 *
 * Normally the build label is fixed (centos7, m1, windows...) so the window is just that
 * label's range. Alpine arm64 is the exception: its label is DERIVED from the version
 * (one pinned agent per major), so no label resolves before a version is picked. There the
 * window is the union over every label the family offers for this arch, and jenkinsLabel()
 * resolves the concrete agent afterwards from the chosen representative. */
function buildNodeWindow(platform, arch) {
  const akey = normArchKey(arch);
  const labelDef = JENKINS_LABELS[`${platform}:${akey}`];
  if (typeof labelDef !== 'function') {
    return LABEL_NODE_MAJORS[labelDef] || {};
  }
  const labels = Object.values(PLATFORM_FAMILIES)
    .filter((f) => f.platform === platform)
    .flatMap((f) => getFamilyLabels(f, akey, null));
  const mins = [];
  const maxes = [];
  for (const label of labels) {
    const range = LABEL_NODE_MAJORS[label];
    if (!range) return {}; // an unconstrained agent exists -> no window at all
    if (range.min !== undefined) mins.push(range.min);
    if (range.max !== undefined) maxes.push(range.max);
  }
  const window = {};
  if (mins.length === labels.length && mins.length) window.min = Math.min(...mins);
  if (maxes.length === labels.length && maxes.length) window.max = Math.max(...maxes);
  return window;
}

/** Narrow `nodeVersions` to those a BUILD on (platform, arch) may pick as its driver Node.
 *
 * FLOOR ONLY, deliberately. There are exactly two cases: the globally OLDEST configured
 * version (centos7/grav2/macos/windows), and the oldest version >= 18 for alpine arm64,
 * whose agents start at Node 18. Neither applies a ceiling.
 *
 * A ceiling would be wrong here: on the validate/test side a `max` means "skip this cell",
 * but a build has only ONE floor agent, so an over-max representative is a misconfiguration
 * rather than a cell to drop. `warnBuildDriverNode` reports it instead of silently emitting
 * a job with no pinned version. */
function filterNodeVersionsForPlatform(nodeVersions, platform, arch) {
  const { min } = buildNodeWindow(platform, arch);
  if (min === undefined) return nodeVersions;
  const kept = [];
  const dropped = [];
  for (const v of nodeVersions) {
    const major = parseInt(String(v).split('.')[0], 10);
    (Number.isNaN(major) || major >= min ? kept : dropped).push(v);
  }
  // Say what was narrowed. Silent truncation reads as "we considered everything" when the
  // driver pick was in fact taken from a smaller list, and the pick is the ONE thing that
  // decides which agent compiles the prebuild.
  if (dropped.length) {
    process.stderr.write(
      `[jenkins] ${platform}:${arch} build driver: ignoring node_versions `
      + `[${dropped.join(', ')}] (below this platform's agent floor, Node ${min}) - `
      + `choosing from [${kept.join(', ') || 'nothing left'}]\n`
    );
  }
  return kept;
}

/** Warn when a build's chosen driver Node exceeds what its floor agent can run: say
 * NODE_VERSIONS='20.15.1 22.14.0' pinning Node 20 on centos7 (glibc < 2.28), which cannot
 * start it. */
function warnBuildDriverNode(label, version) {
  if (version && !labelSupportsNodeVersion(label, version)) {
    const r = LABEL_NODE_MAJORS[label];
    process.stderr.write(
      `WARNING: build driver Node ${version} is outside agent '${label}''s supported range ` +
      `(${r.min ?? '*'}..${r.max ?? '*'}); configure a node_versions entry that '${label}' ` +
      `can run, or the prebuild job will fail to install Node\n`
    );
  }
}

// EDIT FOR YOUR JENKINS: the ONE deployment-specific thing (CONVENTIONS.md).
// The oldest-compatible label per (platform, arch) for the boringssl/N-API node build.
// centos7 is the oldest x64 glibc; qe-grav2-amzn2 the oldest aarch64. macOS/Windows build
// natively on their own arch-specific agent, with no floor concept.
const JENKINS_LABELS = {
  'linux:x64': 'centos7',
  'linux:arm64': 'qe-grav2-amzn2',
  'alpine:x64': 'alpine',
  // version-derived: one pinned-Node agent per major (see ALPINE_ARM64_NODE_MAJORS).
  // Falls back to the lowest existing agent when no version is known yet.
  'alpine:arm64': (version) => alpineArm64Labels(version)[0] || alpineArm64Label(ALPINE_ARM64_NODE_MAJORS[0]),
  'macos:x64': 'macos',
  'macos:arm64': 'm1',
  'windows:x64': 'windows',
};

// Electron/Node ABI compat table. Ascending by maxElectronMajor; the first entry whose
// maxElectronMajor >= the target Electron major wins. Electron 23 is the one real cutoff:
// below it Electron bundles a Node ABI compatible with Node 16 (built against 16.16.0),
// at or above it Node 18 (built against 18.16.0). Each floor also carries the linux
// glibc-floor label picks: Electron >= 23 needs glibc >= 2.28, which centos7/amzn2 lack,
// hence the almalinux8 / qe-ubuntu20-arm64 bump.
//
// Bucketing is by MAJOR VERSION rather than the actual Electron ABI number, which would
// need a live `node -p "require('node-abi').getAbi(v,'electron')"` per version. Major is
// coarser but never wrong: an extra bucket builds one extra prebuild, it does not ship an
// incompatible one. Revisit if a dependency on `node-abi` becomes acceptable at
// tag-generation time.
//
// `nodeVersion` here is a LABEL/BUCKETING key only, deciding which floor a build lands on.
// The value actually passed to cmake-js is the real Electron version being built (see
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

// Platform FAMILIES: the validate/test fan-out. A PLATFORMS token is a family the user
// lists (a distro name); each fans out to an abstract platform plus the concrete agent
// labels PER ARCH. ubuntu22/ubuntu24/rhel9 are arm64-only, since no x64 agent exists for
// those families (JSCBC-1726 covers ubuntu24's x64 gap). Editing a label here is a CI-core
// change, since this file is sha256-pinned; that is the cost of keeping the map in one
// unit-tested place instead of several independently-drifting groovy copies.
const PLATFORM_FAMILIES = {
  //  family          abstract    x64 labels        arm64 labels
  almalinux8: { platform: 'linux', x64: ['almalinux8'], arm64: [] },
  centos7: { platform: 'linux', x64: ['centos7'], arm64: [] },
  amzn2: { platform: 'linux', x64: ['amzn2'], arm64: ['qe-grav2-amzn2', 'qe-grav3-amzn2', 'qe-grav4-amzn2'] },
  // ubuntu20 DOES have an x64 agent; it is also JENKINS_SDIST_LABEL. Only
  // ubuntu22/rhel9/ubuntu24 lack one.
  ubuntu20: { platform: 'linux', x64: ['ubuntu20'], arm64: ['qe-ubuntu20-arm64'] },
  ubuntu22: { platform: 'linux', x64: [], arm64: ['qe-ubuntu22-arm64'] },
  ubuntu24: { platform: 'linux', x64: [], arm64: ['qe-ubuntu24-arm64'] },
  rhel9: { platform: 'linux', x64: [], arm64: ['qe-rhel9-arm64'] },
  alpine: { platform: 'alpine', x64: ['alpine'], arm64: alpineArm64Labels },
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

/** Numeric ascending compare of two "x.y.z" version strings. No semver prerelease
 * handling is needed: electron_versions are always plain release versions. */
function compareVersions(a, b) {
  const at = String(a).split('.').map(Number);
  const bt = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(at.length, bt.length); i++) {
    const d = (at[i] || 0) - (bt[i] || 0);
    if (d) return d;
  }
  return 0;
}

/** Group configured electron_versions by the ABI floor each needs, so every distinct floor
 * becomes exactly ONE build job. Returns floors in table order, each with the list of
 * configured versions it covers (informational, for the job's env and logging). */
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
  // Representative version = the lowest in the bucket. This is the ACTUAL version cmake-js
  // builds against (CN_PREBUILD_RUNTIME_VERSION); the floor's nodeVersion string is a
  // bucketing/label key only, never a build input.
  return [...byFloorIdx.keys()].sort((a, b) => a - b).map((idx) => {
    const entry = byFloorIdx.get(idx);
    const versions = [...entry.versions].sort(compareVersions);
    return { floor: entry.floor, versions, representative: versions[0] };
  });
}

// Node/OpenSSL ABI floor table. ONLY applies when build.ssl == 'openssl'. BoringSSL builds
// never fan out by node_versions; they collapse to ONE build using the single oldest
// configured entry. This table is the OpenSSL-specific exception: pre-18 and 18+ Node link
// against different OpenSSL majors (1.1 vs 3), so each side of that cutoff needs its own
// prebuild. Same shape as ELECTRON_NODE_ABI_TABLE; macOS/Windows keep their direct label
// but still split into two jobs, exactly like the electron case.
const OPENSSL_NODE_FLOOR_TABLE = [
  // Jobs carry `id`, not `maxNodeMajor`: Infinity does not survive JSON.stringify (it
  // becomes `null`), which would leave the groovy consumer unable to identify the
  // top-open-ended floor.
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
 * config. Stash keys are disambiguated by everything that can collide on a shared label:
 * platform + arch + runtime + (for electron) the floor's node-version string. */
function buildJobsFromPlan(plan, cfg) {
  const jobs = [];
  const electronVersions = cfg.raw.support?.electron_versions || [];
  const nodeVersions = cfg.raw.support?.node_versions || [];
  const ssl = String(cfg.raw.build?.ssl || 'boringssl').toLowerCase();

  for (const u of plan.build.units) {
    const { platform, arch, libc } = u;
    if (u.runtime === 'node') {
      if (ssl === 'openssl') {
        // OpenSSL: fan out by the Node-18 ABI floor (see OPENSSL_NODE_FLOOR_TABLE), one
        // job per floor actually required by the configured node_versions.
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

      // BoringSSL (the default): ONE job per (platform, arch), with representative = the
      // single oldest configured node_versions entry. N-API makes that binary
      // ABI-compatible with every newer major, so no node-major cutoff applies. Filter out
      // versions below the platform floor (e.g. Node 16 on alpine:arm64).
      const validVersions = filterNodeVersionsForPlatform(nodeVersions, platform, arch);
      const representative = validVersions.length ? [...validVersions].sort(compareVersions)[0] : undefined;
      // No representative means no driver Node to install. Emitting the job anyway hands
      // groovy a null `node_version` and the failure surfaces as an unexplained installNode
      // error on the agent; name the cause here instead, where the config is in hand.
      if (!representative) {
        throw new Error(
          `no usable build driver Node for ${platform}:${arch} - every configured `
          + `node_versions entry [${nodeVersions.join(', ') || 'none'}] is below that `
          + `platform's agent floor (Node ${buildNodeWindow(platform, arch).min}). `
          + 'Add a NODE_VERSIONS entry that floor can run, or drop the platform.');
      }
      const env = { CBCI_BUILD_PLATFORM: platform, CBCI_BUILD_ARCH: arch, CBCI_BUILD_RUNTIME: 'node' };
      if (libc) env.CBCI_BUILD_LIBC = libc;
      env.CBCI_BUILD_NODE_VERSION = representative;
      const buildLabel = jenkinsLabel(platform, arch, representative);
      warnBuildDriverNode(buildLabel, representative);
      jobs.push({
        label: buildLabel,
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

/** validate/test cells: PLATFORMS filters the fan-out. A distro family (amzn2)
 * selects its labels for this cell's arch, so
 * listing amzn2 tests its x64 box AND its Graviton boxes. Empty PLATFORMS = every
 * label on the cell's platform. */
function checkJobs(units, requested) {
  const jobs = [];
  for (const u of units) {
    for (const label of checkLabels(u.platform, u.arch, requested, u.version)) {
      // Per-AGENT filter, not per-(platform,arch): one neutral linux/x64 cell expands to
      // almalinux8 (every Node) AND centos7/amzn2 (Node <18 only, glibc < 2.28). Dropping
      // the unsupported pairs here is what keeps validate/test off cells that would fail
      // to even start Node. See LABEL_NODE_MAJORS.
      if (u.runtime === 'node' && !labelSupportsNodeVersion(label, u.version)) {
        continue;
      }
      const env = {
        CBCI_TEST_RUNTIME: u.runtime,
        CBCI_TEST_VERSION: u.version,
        CBCI_TEST_PLATFORM: u.platform,
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
const JENKINS_INTEGRATION_LABEL = 'sdkqe-rockylinux9';
const INTEGRATION_BUILD_PLATFORM = 'linux';
const INTEGRATION_BUILD_ARCH = 'x64';
const INTEGRATION_BUILD_LIBC = 'manylinux';

function _cbdynTopology(serverVersion) {
  const version = String(serverVersion).split('-')[0];
  if (version >= '7.0') {
    return ['kv,index,n1ql', 'kv,index,n1ql,eventing', 'kv,index,n1ql,fts,cbas'];
  }
  if (version >= '6.0') {
    return ['kv,index,n1ql', 'kv,index,n1ql', 'kv,index,n1ql,fts,cbas'];
  }
  return ['kv,index,n1ql', 'kv,index,n1ql', 'kv,index,n1ql,fts'];
}

function _resolveServerVersions(spec) {
  const pin = (process.env.SERVER_VERSIONS || '').trim();
  if (pin) {
    const versions = pin.replace(/,/g, ' ').split(/\s+/).filter(Boolean);
    process.stderr.write(`[integration-tags] SERVER_VERSIONS pin: ${JSON.stringify(versions)}\n`);
    return versions;
  }

  const groups = spec.server_versions || [];
  let versions = [];
  if (spec.version_subset !== false) {
    versions = groups
      .map((group) => {
        if (!group || !group.length) return null;
        const idx = Math.floor(Math.random() * group.length);
        return group[idx];
      })
      .filter(Boolean);
  } else {
    versions = groups.flat().filter(Boolean);
  }
  process.stderr.write(`[integration-tags] resolved server versions: ${JSON.stringify(versions)}\n`);
  return versions;
}

function _resolveIntegrationNodeVersions(nodeVers) {
  const envOverride = (process.env.NODE_VERSIONS || '').trim();
  if (envOverride) {
    const versions = envOverride.replace(/,/g, ' ').split(/\s+/).filter(Boolean);
    process.stderr.write(`[integration-tags] NODE_VERSIONS override: testing ${JSON.stringify(versions)}\n`);
    return versions;
  }
  if (!nodeVers || nodeVers.length <= 1) {
    return nodeVers || [];
  }
  const ordered = [...nodeVers].sort(compareVersions);
  const min = ordered[0];
  const max = ordered[ordered.length - 1];
  const chosen = Math.random() < 0.5 ? min : max;
  process.stderr.write(
    `[integration-tags] no NODE_VERSIONS override; randomly testing one version: ${chosen} (min=${min}, max=${max})\n`
  );
  return [chosen];
}

export function integrationTags(configPath = null) {
  const cfg = engine.loadConfig(configPath);
  const spec = cfg.raw.test?.integration || {};
  const nodeVers = _resolveIntegrationNodeVersions(cfg.raw.support?.node_versions || []);
  const serverVersions = _resolveServerVersions(spec);

  const buildJobs = [];
  for (const v of nodeVers) {
    buildJobs.push({
      label: JENKINS_SDIST_LABEL,
      version: v,
      arch: INTEGRATION_BUILD_ARCH,
      platform: INTEGRATION_BUILD_PLATFORM,
      env: {
        CBCI_BUILD_PLATFORM: INTEGRATION_BUILD_PLATFORM,
        CBCI_BUILD_ARCH: INTEGRATION_BUILD_ARCH,
        CBCI_BUILD_LIBC: INTEGRATION_BUILD_LIBC,
        CBCI_BUILD_NODE_VERSION: v,
      },
    });
  }

  const testCells = [];
  for (const v of nodeVers) {
    for (const serverVersion of serverVersions) {
      testCells.push({
        label: JENKINS_INTEGRATION_LABEL,
        version: v,
        arch: INTEGRATION_BUILD_ARCH,
        server_version: serverVersion,
        num_nodes: spec.num_nodes || 3,
        node_topology: _cbdynTopology(serverVersion),
        ram_quota: spec.ram_quota || 2048,
        storage_mode: spec.storage_mode || 'plasma',
        buckets: spec.buckets || ['default'],
        sample_buckets: spec.sample_buckets || [],
        developer_preview: Boolean(spec.developer_preview),
        env: {
          CBCI_TEST_CLUSTER: 'realserver',
          CBCI_TEST_VERSION: v,
        },
      });
    }
  }

  return { build: buildJobs, test: testCells };
}

/** Load the config with PLATFORMS withheld (it speaks Jenkins label vocabulary, which the
 * neutral engine must never see), narrow it to the requested platforms, and build the
 * plan. */
function narrowedPlan(configPath, requested) {
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
  return { cfg, plan: engine.buildPlan(cfg) };
}

/** Post-publish verification: one cell per (label, arch, node version, install type),
 * installing the PUBLISHED package from the registry by name.
 *
 * Built from the VALIDATE units rather than a second matrix, so what gets verified after
 * publish is the same shape that was checked before it. Electron is dropped: its prebuilds
 * go to the snapshots bucket and never reach npm, so there is nothing on the registry for
 * a verify cell to install. */
export function verifyTags(configPath) {
  const requested = requestedTokens();
  const { plan } = narrowedPlan(configPath, requested);
  const units = plan.validate.units.filter((u) => u.runtime === 'node');
  return { verify: checkJobs(units, requested) };
}

/** Full pipeline: build the neutral plan (narrowed to the requested platforms) and
 * translate it into the Jenkins job plan the groovy consumes. */
export function tags(configPath) {
  const requested = requestedTokens();
  const { cfg, plan } = narrowedPlan(configPath, requested);

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
  process.stderr.write('usage: jenkins.mjs [--config <path>] <tags|integration-tags|verify-tags>\n');
}

export function main(argv = process.argv.slice(2)) {
  const { values, positionals } = parseArgs({
    args: argv,
    options: { config: { type: 'string' } },
    allowPositionals: true,
  });
  const cmd = positionals[0];
  // A plan that cannot be built is a CONFIG problem, not a crash: report it the way
  // engine.mjs reports its own fatal checks, so the groovy log shows the cause rather
  // than a stack trace with the message buried in it.
  try {
    if (cmd === 'tags') {
      console.log(JSON.stringify(tags(values.config)));
      return 0;
    }
    if (cmd === 'integration-tags') {
      console.log(JSON.stringify(integrationTags(values.config)));
      return 0;
    }
    if (cmd === 'verify-tags') {
      console.log(JSON.stringify(verifyTags(values.config)));
      return 0;
    }
  } catch (err) {
    process.stderr.write(`ERROR: ${err.message}\n`);
    return 1;
  }
  usage();
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
