#!/usr/bin/env node
// ca_bundle_check.mjs - verify the Mozilla CA bundle the C++ core embeds.
//
// The core downloads https://curl.se/ca/cacert.pem at configure time and compiles every
// certificate into the binary, along with the bundle's date and sha256. couchnode bakes that
// download into the sdist (deps/couchbase-cxx-cache/mozilla-ca-bundle.{crt,sha256}), so what
// a release trusts depends on the day its sdist was built, not on the core version. Two ways
// that has gone wrong:
//
//   * a stale bundle: a release shipped roots Mozilla had already distrusted (CBSE-24000).
//   * a format change: curl added "# Fingerprint" lines between each cert's "====" underline
//     and its PEM in Oct 2026, the core < 1.5.1 parser matched none of them, and the binary
//     shipped with ZERO Mozilla certs (CXXCBC-1112). The build stayed green.
//
// Modes (all print key=value facts on stdout and a one-line verdict on stderr):
//
//   ca_bundle_check.mjs normalize <bundle.crt>   strip comment lines the old parser rejects,
//                                                rewrite the sibling .sha256, prove it parses
//   ca_bundle_check.mjs bundle <bundle.crt>      check a bundle file against the policy
//   ca_bundle_check.mjs binary <file.node> [--sdist <file.tgz|bundle.crt>]
//                                                check what a built prebuild actually embeds
//
// Policy comes from the CBCI_CA_* env that `engine.mjs ca-bundle-env` emits, or flags:
//   --min-date YYYY-MM-DD   oldest acceptable bundle (CBCI_CA_MIN_DATE)
//   --min-certs N           fewest acceptable certs (CBCI_CA_MIN_CERTS, default 100)
//   --deny SHA256           a distrusted root, repeatable (CBCI_CA_DENIED_SHA256, comma list)
//
// Certs are identified by the SHA-256 of their DER encoding, never by label: Mozilla renames
// labels, and a missing label proves nothing. Exit 0 = pass, 1 = policy failure, 2 = usage.
//
// Node builtins only, and kept Node 16 compatible: it runs on the prebuild agents' build
// Node as well as on the release agent. Mirrors ../python/ca_bundle_check.py.

import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

export const DEFAULT_MIN_CERTS = 100;

// Binaries are scanned as latin1 strings: one char per byte, so offsets and bytes agree.
const PEM = /-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/g;
// The core < 1.5.1 extraction regex (cmake/OpenSSL.cmake), verbatim. A bundle that matches
// fewer certs here than it holds embeds fewer certs than it holds.
export const LEGACY_PARSE = /[^=#]+=+\n-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----/g;
// Comment lines wedged between a label's underline and its PEM; the old parser rejects them.
const WEDGED_COMMENTS = /(\n=+\n)(?:#[^\n]*\n)+(-----BEGIN CERTIFICATE-----)/g;
// A label line, its underline and any comment lines, right before a PEM block.
const LABEL = /([^\n\x00=#]+)\n=+\n(?:#[^\n]*\n)*$/;
const HEADER_DATE = /Certificate data from Mozilla (?:as of|last updated on): ([^\n]*)/;
const DATE = /(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +(\d{1,2}) \d{2}:\d{2}:\d{2} (\d{4}) GMT/g;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const SHA256_HEX = /^[0-9a-f]{64}$/;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const CACHE_BUNDLE = 'deps/couchbase-cxx-cache/mozilla-ca-bundle.crt';

const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const latin1 = (path) => readFileSync(path).toString('latin1');

/** Map of sha256 -> label for every decodable PEM certificate in `text` (a bundle or a
 * binary). Labels are for messages only and come from a bundle's text: the core pools them
 * apart from the PEMs, so a binary yields "" and borrows them from the sdist's bundle. */
export function fingerprints(text) {
  const out = new Map();
  for (const m of text.matchAll(PEM)) {
    const b64 = m[1].replace(/\s/g, '');
    if (!b64 || b64.length % 4 !== 0 || !BASE64.test(b64)) continue;
    const der = Buffer.from(b64, 'base64');
    const lm = LABEL.exec(text.slice(Math.max(0, m.index - 512), m.index));
    out.set(sha256(der), lm ? lm[1].trim() : '');
  }
  return out;
}

function describe(fps, denied) {
  return [...denied].sort().map((d) => `${fps.get(d) || 'unlabeled'} (${d.slice(0, 16)})`).join(', ');
}

/** 'YYYY-MM-DD' from curl's 'Tue Oct 20 13:32:40 2026 GMT' match, parsed by hand so the
 * result does not depend on the agent's locale or timezone. */
function isoDate(m) {
  const mm = String(MONTHS.indexOf(m[1]) + 1).padStart(2, '0');
  return `${m[3]}-${mm}-${m[2].padStart(2, '0')}`;
}

function bundleDate(text) {
  const h = HEADER_DATE.exec(text);
  if (!h) return null;
  const m = [...h[1].matchAll(DATE)][0];
  return m ? isoDate(m) : null;
}

/** The bundle date the core compiled in (mozilla_ca_certs_date()). The oldest wins if a
 * binary somehow carries several, so a stale one cannot hide behind a fresh one. */
function binaryDate(text) {
  const dates = [...text.matchAll(DATE)].map(isoDate).sort();
  return dates.length ? dates[0] : null;
}

/** Apply the policy shared by every mode. Appends to `problems`. */
function check(facts, problems, policy, fps, date) {
  const denied = [...fps.keys()].filter((fp) => policy.denied.has(fp));
  facts.ca_denied_found = denied.sort().join(',') || 'none';
  if (denied.length) problems.push(`distrusted root(s) present: ${describe(fps, denied)}`);
  if (fps.size < policy.minCerts) problems.push(`${fps.size} certs, minimum is ${policy.minCerts}`);
  facts.ca_bundle_date = date || 'unknown';
  if (policy.minDate) {
    if (!date) {
      problems.push(`bundle date not found, cannot verify it is >= ${policy.minDate}`);
    } else if (date < policy.minDate) {
      problems.push(`bundle dated ${date}, minimum is ${policy.minDate}`);
    }
  }
}

export function cmdNormalize(path) {
  const data = latin1(path);
  let stripped = 0;
  const fixed = data.replace(WEDGED_COMMENTS, (_m, underline, begin) => { stripped += 1; return underline + begin; });
  if (stripped) writeFileSync(path, Buffer.from(fixed, 'latin1'));
  // The core refuses a .crt whose hash differs from the .sha256 next to it, and reads only
  // the leading hex, so keep whatever followed it (curl writes "  cacert.pem").
  const sha = sha256(Buffer.from(fixed, 'latin1'));
  const shaPath = path.replace(/\.[^./\\]*$/, '') + '.sha256';
  // Written even when absent: the core would otherwise fetch curl's, which no longer matches.
  if (stripped) {
    const old = existsSync(shaPath) ? readFileSync(shaPath, 'utf8') : '';
    writeFileSync(shaPath, old.trim() ? old.replace(/^[0-9a-fA-F]+/, sha) : `${sha}  cacert.pem\n`);
  }
  const pem = (fixed.match(PEM) || []).length;
  const legacy = (fixed.match(LEGACY_PARSE) || []).length;
  const facts = {
    ca_normalized_blocks: String(stripped), ca_bundle_sha256: sha,
    ca_bundle_certs: String(pem), ca_legacy_parse_certs: String(legacy),
  };
  const problems = legacy !== pem ? [`the core < 1.5.1 parser still matches ${legacy} of ${pem} certs`] : [];
  return { facts, problems, summary: `normalize ${basename(path)}: stripped ${stripped} comment block(s), ${legacy}/${pem} certs parse` };
}

export function cmdBundle(path, policy) {
  const raw = readFileSync(path);
  const text = raw.toString('latin1');
  const fps = fingerprints(text);
  const facts = { ca_bundle_sha256: sha256(raw), ca_bundle_certs: String(fps.size) };
  const problems = [];
  check(facts, problems, policy, fps, bundleDate(text));
  const denied = [...fps.keys()].filter((fp) => policy.denied.has(fp)).length;
  return { facts, problems, summary: `bundle ${basename(path)}: date=${facts.ca_bundle_date} certs=${fps.size} denied=${denied}` };
}

/** The member at `want` (or ending in /`want`) of a tar.gz, or null. npm writes ustar with
 * pax headers, so ustar prefixes, pax `path` records and GNU long names are all honored. */
export function tarMember(tgzPath, want) {
  const tar = gunzipSync(readFileSync(tgzPath));
  const str = (off, len) => tar.toString('latin1', off, off + len).replace(/\0[\s\S]*$/, '');
  let longName = null;
  for (let off = 0; off + 512 <= tar.length;) {
    if (tar[off] === 0) break;
    const size = parseInt(str(off + 124, 12).trim() || '0', 8);
    const type = String.fromCharCode(tar[off + 156] || 48);
    const body = off + 512;
    const prefix = str(off + 257, 6) === 'ustar' ? str(off + 345, 155) : '';
    const name = longName || (prefix ? `${prefix}/${str(off, 100)}` : str(off, 100));
    longName = null;
    if (type === 'x') {
      const m = /(?:^|\n)\d+ path=([^\n]*)\n/.exec(tar.toString('utf8', body, body + size));
      if (m) longName = m[1];
    } else if (type === 'L') {
      longName = str(body, size);
    } else if (type === '0' && (name === want || name.endsWith(`/${want}`))) {
      return tar.subarray(body, body + size);
    }
    off = body + Math.ceil(size / 512) * 512;
  }
  return null;
}

/** The bundle the sdist shipped: a .crt directly, or the cache member of an npm tarball. */
function sdistBundle(sdist) {
  if (/\.crt$/.test(sdist)) return readFileSync(sdist);
  return tarMember(sdist, CACHE_BUNDLE);
}

export function cmdBinary(path, policy, sdist = null) {
  const raw = readFileSync(path);
  if (!raw.length) return { facts: { ca_check: 'fail' }, problems: ['the binary is empty'], summary: `binary ${basename(path)}` };
  const text = raw.toString('latin1');
  const fps = fingerprints(text);
  const bundle = sdist ? sdistBundle(sdist) : null;
  const bundleFps = bundle ? fingerprints(bundle.toString('latin1')) : new Map();
  for (const fp of fps.keys()) fps.set(fp, fps.get(fp) || bundleFps.get(fp) || '');
  const facts = { ca_certs_embedded: String(fps.size) };
  const problems = [];
  check(facts, problems, policy, fps, binaryDate(text));
  if (sdist && !bundle) problems.push(`no ${CACHE_BUNDLE} in ${basename(sdist)}`);

  // Tie the binary to the bundle its sdist shipped. The core compiles that bundle's sha256
  // in (mozilla_ca_certs_sha256()), so a hit proves which bundle was used, and every cert
  // in it must then be embedded. Extras are expected: the core adds the Capella CA.
  facts.ca_sdist_match = 'unchecked';
  facts.ca_bundle_sha256 = 'unknown';
  if (bundle) {
    const sha = sha256(bundle);
    const missing = [...bundleFps.keys()].filter((fp) => !fps.has(fp));
    if (!text.includes(sha)) {
      problems.push(`binary was not built from the sdist's bundle (sha256 ${sha.slice(0, 12)} not embedded)`);
      facts.ca_sdist_match = 'no';
    } else if (missing.length) {
      problems.push(`${missing.length} cert(s) in the sdist's bundle are not embedded`);
      facts.ca_sdist_match = 'no';
    } else {
      facts.ca_sdist_match = 'yes';
      facts.ca_bundle_sha256 = sha;
    }
  }
  const denied = [...fps.keys()].filter((fp) => policy.denied.has(fp)).length;
  return {
    facts, problems,
    summary: `binary ${basename(path)}: date=${facts.ca_bundle_date} certs=${fps.size} denied=${denied} sdist_match=${facts.ca_sdist_match}`,
  };
}

const HINTS = [
  ['certs, minimum', 'A near-zero count usually means the core parser rejected the bundle '
    + 'format (CXXCBC-1112). Is build.ca_bundle_normalize gated off on this branch?'],
  ['distrusted', 'Rebuild the sdist so it bakes a bundle from after the distrust. If curl\'s '
    + 'current bundle still carries the root, the release has to wait for it.'],
  ['bundle dated', 'The sdist baked an old bundle. Rebuild the sdist rather than reusing one '
    + '(COPY_ARTIFACTS_FROM, a stale CPM cache).'],
];

/** The policy from flags, falling back to the CBCI_CA_* env. Throws on a malformed value. */
export function resolvePolicy(values, env = process.env) {
  const minDate = String(values['min-date'] ?? env.CBCI_CA_MIN_DATE ?? '').trim();
  const minCerts = String(values['min-certs'] ?? env.CBCI_CA_MIN_CERTS ?? '').trim();
  const rawDenied = values.deny?.length ? values.deny : String(env.CBCI_CA_DENIED_SHA256 || '').split(',');
  const denied = new Set(rawDenied.map((d) => d.trim().toLowerCase().replace(/:/g, '')).filter(Boolean));
  const bad = [...denied].filter((d) => !SHA256_HEX.test(d));
  if (bad.length) throw new Error(`not a sha256 fingerprint: ${bad.sort().join(', ')}`);
  if (minDate && !/^\d{4}-\d{2}-\d{2}$/.test(minDate)) throw new Error(`min-date must be YYYY-MM-DD (got '${minDate}')`);
  if (minCerts && !/^\d+$/.test(minCerts)) throw new Error(`min-certs must be a non-negative integer (got '${minCerts}')`);
  return { minDate: minDate || null, minCerts: minCerts ? parseInt(minCerts, 10) : DEFAULT_MIN_CERTS, denied };
}

export function main(argv = process.argv.slice(2)) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        sdist: { type: 'string' },
        'min-date': { type: 'string' },
        'min-certs': { type: 'string' },
        deny: { type: 'string', multiple: true },
      },
    });
  } catch (err) {
    process.stderr.write(`ca-bundle: ERROR: ${err.message}\n`);
    return 2;
  }
  const [mode, path] = parsed.positionals;
  if (!['normalize', 'bundle', 'binary'].includes(mode) || !path) {
    process.stderr.write('usage: ca_bundle_check.mjs <normalize|bundle|binary> <path> [--sdist <tgz|crt>] '
      + '[--min-date YYYY-MM-DD] [--min-certs N] [--deny SHA256]...\n');
    return 2;
  }
  let policy;
  try {
    policy = resolvePolicy(parsed.values);
  } catch (err) {
    process.stderr.write(`ca-bundle: ERROR: ${err.message}\n`);
    return 2;
  }
  for (const p of [path, parsed.values.sdist].filter(Boolean)) {
    if (!existsSync(p) || !statSync(p).isFile()) {
      process.stderr.write(`ca-bundle: ERROR: no such file: ${p}\n`);
      return 2;
    }
  }

  const { facts, problems, summary } = mode === 'normalize' ? cmdNormalize(path)
    : mode === 'bundle' ? cmdBundle(path, policy)
      : cmdBinary(path, policy, parsed.values.sdist || null);

  facts.ca_check = problems.length ? 'fail' : 'pass';
  process.stdout.write(Object.keys(facts).sort().map((k) => `${k}=${facts[k]}\n`).join(''));
  if (!problems.length) {
    process.stderr.write(`ca-bundle: ${summary} OK\n`);
    return 0;
  }
  process.stderr.write(`ca-bundle: FAIL ${summary}\n`);
  for (const p of problems) {
    process.stderr.write(`ca-bundle:   - ${p}\n`);
    for (const [key, hint] of HINTS) {
      if (p.includes(key)) process.stderr.write(`ca-bundle:     ${hint}\n`);
    }
  }
  return 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exitCode = main();
}
