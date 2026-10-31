#!/usr/bin/env python3
"""ca_bundle_check.py - verify the Mozilla CA bundle the C++ core embeds.

The core downloads https://curl.se/ca/cacert.pem at configure time and compiles every
certificate into the binary, along with the bundle's date and sha256. The SDKs bake that
download into the sdist (deps/couchbase-cxx-cache/mozilla-ca-bundle.{crt,sha256}), so what
a release trusts depends on the day its sdist was built, not on the core version. Two ways
that has gone wrong:

  * a stale bundle: a release shipped roots Mozilla had already distrusted (CBSE-24000).
  * a format change: curl added "# Fingerprint" lines between each cert's "====" underline
    and its PEM in Oct 2026, the core < 1.5.1 parser matched none of them, and the binary
    shipped with ZERO Mozilla certs (CXXCBC-1112). The build stayed green.

Modes (all print key=value facts on stdout and a one-line verdict on stderr):

    ca_bundle_check.py normalize <bundle.crt>   strip comment lines the old parser rejects,
                                                rewrite the sibling .sha256, prove it parses
    ca_bundle_check.py bundle <bundle.crt>      check a bundle file against the policy
    ca_bundle_check.py wheel <file.whl> [--sdist <file.tar.gz>]
                                                check what a built wheel actually embeds
    ca_bundle_check.py interim-patch <sdk-root>
                                                apply the CI-only PYCBC-2044 fix (below)

Policy comes from the CBCI_CA_* env that `engine.py ca-bundle-env` emits, or flags:
    --min-date YYYY-MM-DD   oldest acceptable bundle (CBCI_CA_MIN_DATE)
    --min-certs N           fewest acceptable certs (CBCI_CA_MIN_CERTS, default 100)
    --deny SHA256           a distrusted root, repeatable (CBCI_CA_DENIED_SHA256, comma list)
    --release               a release build (CBCI_CA_RELEASE=ON): never patch, and fail a
                            wheel whose sdist carries the interim patch

Interim patch (PYCBC-2044): the SDK's CMakeLists.txt turns CA embedding off whenever the
CPM cache is used, so every wheel built from an sdist embeds only the Capella CA. Until the
fix lands, a non-release sdist gets it from `git apply`, which also tells the source states
apart: old (apply it), fixed (the reverse applies, do nothing), unrecognized (warn, do
nothing). A patched CMakeLists.txt is marked, and the sdist packs it, so a release that
reuses a patched build fails rather than ship source that differs from git. Delete the
patch, the mode and build.ca_bundle.interim_patch once PYCBC-2044 is on every built branch.

Certs are identified by the SHA-256 of their DER encoding, never by label: Mozilla renames
labels, and a missing label proves nothing. Exit 0 = pass, 1 = policy failure, 2 = usage.

Standard library only, and kept Python 3.6 compatible: it runs on the release agent's
system python as well as on every build host.
"""

import argparse
import base64
import binascii
import datetime
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
import zipfile

DEFAULT_MIN_CERTS = 100

_PEM = re.compile(rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", re.S)
# The core < 1.5.1 extraction regex (cmake/OpenSSL.cmake), verbatim. A bundle that matches
# fewer certs here than it holds embeds fewer certs than it holds.
_LEGACY_PARSE = re.compile(rb"[^=#]+=+\n-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----")
# Comment lines wedged between a label's underline and its PEM; the old parser rejects them.
_WEDGED_COMMENTS = re.compile(rb"(\n=+\n)(?:#[^\n]*\n)+(-----BEGIN CERTIFICATE-----)")
# A label line, its underline and any comment lines, right before a PEM block.
_LABEL = re.compile(rb"([^\n\x00=#]+)\n=+\n(?:#[^\n]*\n)*\Z")
_HEADER_DATE = re.compile(rb"Certificate data from Mozilla (?:as of|last updated on): ([^\n]*)")
_DATE = re.compile(rb"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
                   rb" +(\d{1,2}) \d{2}:\d{2}:\d{2} (\d{4}) GMT")
_MONTHS = {m: i + 1 for i, m in enumerate(
    (b"Jan", b"Feb", b"Mar", b"Apr", b"May", b"Jun", b"Jul", b"Aug", b"Sep", b"Oct", b"Nov", b"Dec"))}
_SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
_CACHE_BUNDLE = "deps/couchbase-cxx-cache/mozilla-ca-bundle.crt"
_BINARY_SUFFIXES = (".so", ".pyd", ".dylib")

# The PYCBC-2044 change's diff. Regenerate it from the change if review alters the fix, so
# CI and the change test the same CMake.
_INTERIM_PATCH_KEY = "PYCBC-2044"
_INTERIM_PATCH = b'''\
diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -218,14 +218,13 @@ endif()
 message(STATUS "USE_STATIC_STDLIB=${USE_STATIC_STDLIB}")

 option(DOWNLOAD_MOZILLA_CA_BUNDLE "Allow C++ client to download and embed Mozilla certificates" TRUE)
-if(DOWNLOAD_MOZILLA_CA_BUNDLE)
-  set(COUCHBASE_CXX_CLIENT_EMBED_MOZILLA_CA_BUNDLE
-      ON
-      CACHE BOOL "" FORCE)
+# OFF still embeds a bundle already in EMBED_MOZILLA_CA_BUNDLE_ROOT (the sdist's CPM cache).
+set(_pycbc_ca_root "${COUCHBASE_CXX_CLIENT_EMBED_MOZILLA_CA_BUNDLE_ROOT}")
+if(DOWNLOAD_MOZILLA_CA_BUNDLE
+   OR (EXISTS "${_pycbc_ca_root}/mozilla-ca-bundle.crt" AND EXISTS "${_pycbc_ca_root}/mozilla-ca-bundle.sha256"))
+  set(COUCHBASE_CXX_CLIENT_EMBED_MOZILLA_CA_BUNDLE ON CACHE BOOL "" FORCE)
 else()
-  set(COUCHBASE_CXX_CLIENT_EMBED_MOZILLA_CA_BUNDLE
-      OFF
-      CACHE BOOL "" FORCE)
+  set(COUCHBASE_CXX_CLIENT_EMBED_MOZILLA_CA_BUNDLE OFF CACHE BOOL "" FORCE)
 endif()
 message(STATUS "DOWNLOAD_MOZILLA_CA_BUNDLE=${DOWNLOAD_MOZILLA_CA_BUNDLE}")

'''.replace(b"\n\n", b"\n \n")  # blank context lines need their space; kept out of the source
# Appended to a patched CMakeLists.txt, which the sdist packs. --release looks for it.
_INTERIM_MARKER = b"# cbci-interim-patch: "


class Policy(object):
    def __init__(self, min_date, min_certs, denied, release=False):
        self.min_date = min_date
        self.min_certs = min_certs
        self.denied = denied
        self.release = release


def _fingerprints(data):
    """{sha256: label} for every decodable PEM certificate in `data` (a bundle or a binary).
    Labels are for messages only and come from a bundle's text: the core pools them apart
    from the PEMs, so a binary yields "" and borrows them from the sdist's bundle."""
    out = {}
    for m in _PEM.finditer(data):
        try:
            der = base64.b64decode(re.sub(rb"\s", b"", m.group(1)), validate=True)
        except (binascii.Error, ValueError):
            continue
        head = data[max(0, m.start() - 512):m.start()]
        lm = _LABEL.search(head)
        out[hashlib.sha256(der).hexdigest()] = lm.group(1).decode("utf-8", "replace").strip() if lm else ""
    return out


def _describe(fps, denied):
    return ", ".join("{} ({})".format(fps[d] or "unlabeled", d[:16]) for d in sorted(denied))


def _parse_date(raw):
    """A date.date from curl's 'Tue Oct 20 13:32:40 2026 GMT', or None. Parsed by hand so
    the result does not depend on the agent's locale."""
    m = _DATE.search(raw)
    if not m:
        return None
    return datetime.date(int(m.group(3)), _MONTHS[m.group(1)], int(m.group(2)))


def _bundle_date(data):
    m = _HEADER_DATE.search(data)
    return _parse_date(m.group(1)) if m else None


def _binary_date(data):
    """The bundle date the core compiled in (mozilla_ca_certs_date()). The oldest wins if a
    binary somehow carries several, so a stale one cannot hide behind a fresh one."""
    dates = [d for d in (_parse_date(m.group(0)) for m in _DATE.finditer(data)) if d]
    return min(dates) if dates else None


def _check(facts, problems, policy, fps, date):
    """Apply the policy shared by every mode. Appends to `problems`."""
    denied = set(fps) & policy.denied
    certs = len(fps)
    facts["ca_denied_found"] = ",".join(sorted(denied)) or "none"
    if denied:
        problems.append("distrusted root(s) present: " + _describe(fps, denied))
    if certs < policy.min_certs:
        problems.append("{} certs, minimum is {}".format(certs, policy.min_certs))
    facts["ca_bundle_date"] = date.isoformat() if date else "unknown"
    if policy.min_date:
        if date is None:
            problems.append("bundle date not found, cannot verify it is >= {}".format(policy.min_date))
        elif date < policy.min_date:
            problems.append("bundle dated {}, minimum is {}".format(date, policy.min_date))


def cmd_normalize(path, policy):
    with open(path, "rb") as f:
        data = f.read()
    fixed, stripped = _WEDGED_COMMENTS.subn(rb"\1\2", data)
    if stripped:
        with open(path, "wb") as f:
            f.write(fixed)
    # The core refuses a .crt whose hash differs from the .sha256 next to it, and reads only
    # the leading hex, so keep whatever followed it (curl writes "  cacert.pem").
    sha = hashlib.sha256(fixed).hexdigest()
    sha_path = os.path.splitext(path)[0] + ".sha256"
    # Written even when absent: the core would otherwise fetch curl's, which no longer matches.
    if stripped:
        old = ""
        if os.path.isfile(sha_path):
            with open(sha_path, "r") as f:
                old = f.read()
        with open(sha_path, "w") as f:
            f.write(re.sub(r"^[0-9a-fA-F]+", sha, old, count=1) if old.strip() else sha + "  cacert.pem\n")
    pem = len(_PEM.findall(fixed))
    legacy = len(_LEGACY_PARSE.findall(fixed))
    facts = {"ca_normalized_blocks": str(stripped), "ca_bundle_sha256": sha,
             "ca_bundle_certs": str(pem), "ca_legacy_parse_certs": str(legacy)}
    problems = []
    if legacy != pem:
        problems.append("the core < 1.5.1 parser still matches {} of {} certs".format(legacy, pem))
    return facts, problems, "normalize {}: stripped {} comment block(s), {}/{} certs parse".format(
        os.path.basename(path), stripped, legacy, pem)


def cmd_bundle(path, policy):
    with open(path, "rb") as f:
        data = f.read()
    fps = _fingerprints(data)
    facts = {"ca_bundle_sha256": hashlib.sha256(data).hexdigest(), "ca_bundle_certs": str(len(fps))}
    problems = []
    _check(facts, problems, policy, fps, _bundle_date(data))
    return facts, problems, "bundle {}: date={} certs={} denied={}".format(
        os.path.basename(path), facts["ca_bundle_date"], len(fps), len(set(fps) & policy.denied))


def _sdist_files(sdist):
    """(the cache bundle, the top-level CMakeLists.txt) from an sdist, None when absent."""
    bundle = cmake = None
    with tarfile.open(sdist, "r:*") as tf:
        for member in tf.getmembers():
            if not member.isfile():
                continue
            if member.name.endswith("/" + _CACHE_BUNDLE):
                bundle = tf.extractfile(member).read()
            elif member.name.count("/") == 1 and member.name.endswith("/CMakeLists.txt"):
                cmake = tf.extractfile(member).read()
    return bundle, cmake


def _interim_marker(cmake):
    """The patch key a marked CMakeLists.txt names, or None."""
    for line in (cmake or b"").splitlines():
        if line.startswith(_INTERIM_MARKER):
            return line[len(_INTERIM_MARKER):].split()[0].decode("ascii", "replace")
    return None


def cmd_wheel(path, policy, sdist=None):
    data = b""
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            if name.endswith(_BINARY_SUFFIXES) or ".so." in name:
                data += zf.read(name)
    if not data:
        return ({"ca_check": "fail"}, ["no compiled extension found in the wheel"],
                "wheel " + os.path.basename(path))
    fps = _fingerprints(data)
    bundle, cmake = _sdist_files(sdist) if sdist else (None, None)
    bundle_fps = _fingerprints(bundle) if bundle is not None else {}
    for fp in fps:
        fps[fp] = fps[fp] or bundle_fps.get(fp, "")
    facts = {"ca_certs_embedded": str(len(fps))}
    problems = []
    _check(facts, problems, policy, fps, _binary_date(data))

    # Tie the binary to the bundle its sdist shipped. The core compiles that bundle's sha256
    # in (mozilla_ca_certs_sha256()), so a hit proves which bundle was used, and every cert
    # in it must then be embedded. Extras are expected: the core adds the Capella CA.
    facts["ca_sdist_match"] = "unchecked"
    facts["ca_bundle_sha256"] = "unknown"
    if bundle is not None:
        sha = hashlib.sha256(bundle).hexdigest()
        missing = set(bundle_fps) - set(fps)
        if sha.encode() not in data:
            problems.append("binary was not built from the sdist's bundle (sha256 {} not embedded)".format(sha[:12]))
            facts["ca_sdist_match"] = "no"
        elif missing:
            problems.append("{} cert(s) in the sdist's bundle are not embedded".format(len(missing)))
            facts["ca_sdist_match"] = "no"
        else:
            facts["ca_sdist_match"] = "yes"
            facts["ca_bundle_sha256"] = sha

    patched = _interim_marker(cmake)
    facts["ca_interim_patch"] = patched or ("none" if sdist else "unchecked")
    if patched and policy.release:
        problems.append("the sdist carries the CI-only interim patch {}; a release must be built "
                        "from unpatched source".format(patched))
    return facts, problems, "wheel {}: date={} certs={} denied={} sdist_match={}{}".format(
        os.path.basename(path), facts["ca_bundle_date"], len(fps), len(set(fps) & policy.denied),
        facts["ca_sdist_match"], " interim_patch=" + patched if patched else "")


def _git_apply(root, *flags):
    proc = subprocess.Popen(["git", "apply"] + list(flags) + ["-"], cwd=root,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    _, err = proc.communicate(_INTERIM_PATCH)
    return proc.returncode == 0, err.decode("utf-8", "replace").strip()


def cmd_interim_patch(root, policy):
    """Apply the interim patch to a non-release checkout whose CMake still has the bug."""
    facts = {}
    problems = []
    try:
        old, err = _git_apply(root, "--check")
        fixed = not old and _git_apply(root, "--reverse", "--check")[0]
    except OSError as e:
        return {"ca_interim_patch": "error"}, ["cannot run git apply: {}".format(e)], "interim-patch"
    if fixed:
        state, note = "present", "the source already carries the fix"
    elif not old:
        # A warning, not a failure: the wheel check is what decides whether the CA bundle embeds.
        state, note = "unrecognized", "WARNING: CMakeLists.txt matches neither side of the patch ({})".format(err)
    elif policy.release:
        state, note = "skipped", "release build, not patching; the wheel check fails until the fix lands"
    else:
        ok, err = _git_apply(root)
        if not ok:
            return {"ca_interim_patch": "error"}, ["git apply failed: {}".format(err)], "interim-patch"
        with open(os.path.join(root, "CMakeLists.txt"), "ab") as f:
            f.write(_INTERIM_MARKER + _INTERIM_PATCH_KEY.encode() + b" (CI build only, never published)\n")
        state, note = "applied", "applied, so this build's sdist and wheels are CI-only"
    facts["ca_interim_patch"] = state
    return facts, problems, "interim-patch {}: {}".format(_INTERIM_PATCH_KEY, note)


_HINTS = (
    ("certs, minimum", "A near-zero count usually means the core parser rejected the bundle "
                       "format (CXXCBC-1112). Is build.ca_bundle_normalize gated off on this branch?"),
    ("distrusted", "Rebuild the sdist so it bakes a bundle from after the distrust. If curl's "
                   "current bundle still carries the root, the release has to wait for it."),
    ("bundle dated", "The sdist baked an old bundle. Rebuild the sdist rather than reusing one "
                     "(COPY_ARTIFACTS_FROM, a stale CPM cache)."),
    ("not built from the sdist's bundle", "If it embeds only the Capella CA, the SDK's CMakeLists.txt "
                                          "lacks PYCBC-2044, which a release must carry."),
    ("interim patch", "Rebuild with IS_RELEASE=true rather than reusing a non-release build."),
)


def _policy(args):
    min_date = args.min_date if args.min_date is not None else os.environ.get("CBCI_CA_MIN_DATE", "")
    min_certs = args.min_certs if args.min_certs is not None else os.environ.get("CBCI_CA_MIN_CERTS", "")
    denied = args.deny if args.deny else [
        d for d in os.environ.get("CBCI_CA_DENIED_SHA256", "").split(",") if d.strip()]
    denied = {d.strip().lower().replace(":", "") for d in denied}
    bad = [d for d in denied if not _SHA256_HEX.match(d)]
    if bad:
        raise ValueError("not a sha256 fingerprint: " + ", ".join(sorted(bad)))
    parsed_date = None
    if min_date:
        parsed_date = datetime.datetime.strptime(min_date.strip(), "%Y-%m-%d").date()
    release = args.release or os.environ.get("CBCI_CA_RELEASE", "").strip().upper() == "ON"
    return Policy(parsed_date, int(min_certs) if str(min_certs).strip() else DEFAULT_MIN_CERTS, denied,
                  release)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=("normalize", "bundle", "wheel", "interim-patch"))
    parser.add_argument("path")
    parser.add_argument("--sdist", default=None)
    parser.add_argument("--min-date", default=None)
    parser.add_argument("--min-certs", type=int, default=None)
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args(argv)
    try:
        policy = _policy(args)
    except ValueError as e:
        print("ca-bundle: ERROR: {}".format(e), file=sys.stderr)
        return 2
    exists = os.path.isdir if args.mode == "interim-patch" else os.path.isfile
    if not exists(args.path):
        print("ca-bundle: ERROR: no such {}: {}".format(
            "directory" if args.mode == "interim-patch" else "file", args.path), file=sys.stderr)
        return 2

    if args.mode == "normalize":
        facts, problems, summary = cmd_normalize(args.path, policy)
    elif args.mode == "bundle":
        facts, problems, summary = cmd_bundle(args.path, policy)
    elif args.mode == "interim-patch":
        facts, problems, summary = cmd_interim_patch(args.path, policy)
    else:
        facts, problems, summary = cmd_wheel(args.path, policy, args.sdist)

    facts["ca_check"] = "fail" if problems else "pass"
    out = io.StringIO()
    for k in sorted(facts):
        out.write("{}={}\n".format(k, facts[k]))
    sys.stdout.write(out.getvalue())
    if not problems:
        print("ca-bundle: {} OK".format(summary), file=sys.stderr)
        return 0
    print("ca-bundle: FAIL {}".format(summary), file=sys.stderr)
    for p in problems:
        print("ca-bundle:   - {}".format(p), file=sys.stderr)
        for key, hint in _HINTS:
            if key in p:
                print("ca-bundle:     {}".format(hint), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
