#!/usr/bin/env python3
"""jenkins.py - the Jenkins ADAPTER for the Couchbase Python SDK CI-core.

Translates the vendor-NEUTRAL plan from `engine.py` into Jenkins jobs, attaching the ONE
deployment-specific thing the core deliberately does not know: runner agent labels and
container images (CONVENTIONS.md). The neutral core (engine.py / tasks.sh) never carries
a label; this file is the sole place they live for Jenkins.

This module OWNS the distro/agent vocabulary end-to-end. The user's `PLATFORMS` list is
Jenkins vocabulary: distro families (`amzn2`, `ubuntu24`) and even raw agent labels
(`m1`, `qe-grav2-amzn2`). `engine.py` speaks only ABSTRACT platforms (linux/alpine/macos/
windows), so `tags()` translates the requested distro tokens to abstract, narrows the
plan via `engine.narrow_to_platforms()`, and uses the raw distro list for the validate/
test fan-out. engine must NEVER import this module (core cannot depend on an adapter).

CLI:
    python3 jenkins.py tags               # emit the Jenkins job plan (JSON) the groovy consumes
    python3 jenkins.py integration-tags    # emit the cbdyncluster integration-test job plan (JSON)
    python3 jenkins.py verify-tags         # emit the release-verify (post-publish install check) job plan (JSON)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
from typing import Any, Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine  # noqa: E402  (the neutral core; this adapter builds on it)


# EDIT FOR YOUR JENKINS: the ONE deployment-specific thing (CONVENTIONS.md). Three label
# roles, because each needs a different kind of agent:
#
#   _JENKINS_LABELS       WHEEL build. linux/alpine run the thin manylinux/musllinux IMAGE,
#                         so the agent is a DOCKER HOST of the right arch (qe-docker[-aarch64]).
#                         macOS/Windows build natively, so real arch-specific agents.
#   _JENKINS_SDIST_LABEL  sdist runs NATIVELY (configure_ext needs cmake + the C++ toolchain),
#                         so a build-capable linux node.
#   _JENKINS_CHECK_LABELS validate/test-unit install + run the artifact NATIVELY. Defaults to
#                         the build label; override per (platform,arch) for broader distro
#                         coverage, since a manylinux wheel runs on any glibc distro.
_JENKINS_LABELS = {
    ("linux", "x86_64"):   "qe-docker",          # docker host (runs the thin manylinux image)
    ("linux", "arm64"):    "qe-docker-aarch64",  # docker host, aarch64
    ("alpine", "x86_64"):  "qe-docker",           # musllinux build is also containerized
    ("macos", "x86_64"):   "macos",
    ("macos", "arm64"):    "m1",
    ("windows", "x86_64"): "windows",
}
_JENKINS_SDIST_LABEL = "ubuntu20"                 # native build node (cmake + C++ toolchain)
_JENKINS_CHECK_LABELS: Dict[tuple, str] = {}      # e.g. {("linux","x86_64"): "ubuntu20"}

_LIBC_FAMILY = {"manylinux": "manylinux2014", "musllinux": "musllinux_1_2"}

# Platform FAMILIES: the validate/test fan-out. A PLATFORMS token is a family the user
# lists (a distro name); each fans out to an abstract platform plus the concrete agent
# labels PER ARCH. Listing `amzn2` therefore covers its x86 box AND its Graviton arm64
# boxes, so the wheel built for (linux, arm64) actually gets a test cell. Editing a label
# here is a CI-core change, since this file is sha256-pinned; that is the cost of keeping
# the map in one unit-tested place.
_PLATFORM_FAMILIES: Dict[str, Dict[str, Any]] = {
    #  family token   abstract                 x86_64 labels          arm64 labels
    "ubuntu20":   {"platform": "linux",   "x86_64": ["ubuntu20"],   "arm64": ["qe-ubuntu20-arm64"]},
    # ubuntu24 has an arm64 box only (no x86 agent exists): its aarch64 wheel builds on
    # qe-docker-aarch64 and tests on qe-ubuntu24-arm64. Same shape as ubuntu22.
    "ubuntu24":   {"platform": "linux",   "x86_64": [],             "arm64": ["qe-ubuntu24-arm64"]},
    "centos7":    {"platform": "linux",   "x86_64": ["centos7"],    "arm64": []},
    "almalinux8": {"platform": "linux",   "x86_64": ["almalinux8"], "arm64": []},
    "amzn2":      {"platform": "linux",   "x86_64": ["amzn2"],      "arm64": ["qe-grav2-amzn2", "qe-grav3-amzn2", "qe-grav4-amzn2"]},
    "rhel9":      {"platform": "linux",   "x86_64": ["rhel9"],      "arm64": ["qe-rhel9-arm64"]},
    # ubuntu22 has an arm64 box only (no x86 agent).
    "ubuntu22":   {"platform": "linux",   "x86_64": [],             "arm64": ["qe-ubuntu22-arm64"]},
    "alpine":     {"platform": "alpine",  "x86_64": ["alpine"],     "arm64": []},
    "macos":      {"platform": "macos",   "x86_64": ["macos"],      "arm64": ["m1"]},
    "windows":    {"platform": "windows", "x86_64": ["windows"],    "arm64": []},
}

# The abstract platforms this adapter maps onto (derived, so it can't drift from the map).
_ABSTRACT_PLATFORMS = {f["platform"] for f in _PLATFORM_FAMILIES.values()}


def _norm_arch_key(arch: str) -> str:
    """Map any arch spelling to the family-table arch key."""
    return "arm64" if arch in ("arm64", "aarch64") else "x86_64"


def _platform_token_to_abstract(token: str) -> Optional[str]:
    """Resolve a PLATFORMS token to its abstract platform. Accepts an abstract platform
    (linux/alpine/macos/windows), a family name (amzn2), a raw agent label (qe-grav2-amzn2,
    m1), or a versioned alpine token (alpine3.20). Returns None if unrecognized (caller
    keeps the raw token so the support-matrix intersection / fan-out can warn)."""
    t = token.lower()
    if t in _ABSTRACT_PLATFORMS:
        return t
    if t in _PLATFORM_FAMILIES:
        return _PLATFORM_FAMILIES[t]["platform"]
    for fam in _PLATFORM_FAMILIES.values():
        for akey in ("x86_64", "arm64"):
            if t in (lbl.lower() for lbl in fam.get(akey, [])):
                return fam["platform"]
    if t.startswith("alpine"):
        return "alpine"
    return None


def _check_labels(platform: str, arch: str, requested: List[str]) -> List[str]:
    """Concrete agent labels for a (platform, arch) validate/test cell.

    `requested` is the lowercased PLATFORMS list; empty means no filter, so every label on
    this platform. A token selects labels when it is (a) the abstract platform name, which
    takes all families on it, (b) a family on this platform, which takes its labels for
    this arch, or (c) a raw label that lives on this cell. Order-preserving, de-duplicated.
    """
    akey = _norm_arch_key(arch)
    fams_here = {tok: f for tok, f in _PLATFORM_FAMILIES.items() if f["platform"] == platform}
    all_here = [lbl for f in fams_here.values() for lbl in f.get(akey, [])]
    if not requested:
        chosen = list(all_here)
    else:
        chosen = []
        all_here_lc = {lbl.lower() for lbl in all_here}
        for t in requested:
            if t == platform or (t.startswith("alpine") and platform == "alpine"):
                chosen.extend(all_here)                                      # abstract: all
            elif t in fams_here:
                chosen.extend(fams_here[t].get(akey, []))                    # family on this platform
            elif t in all_here_lc:
                chosen.extend(lbl for lbl in all_here if lbl.lower() == t)   # raw label on this cell
    seen: set = set()
    out: List[str] = []
    for lbl in chosen:
        if lbl not in seen:
            seen.add(lbl)
            out.append(lbl)
    return out


def _jenkins_label(platform: str, arch: str) -> str:
    label = _JENKINS_LABELS.get((platform, arch))
    if label is None:
        print(f"WARNING: no Jenkins label for ({platform}, {arch}); using '{platform}'", file=sys.stderr)
        return platform
    return label


def _jenkins_check_label(platform: str, arch: str) -> str:
    """validate/test agent: an explicit check label, else the (native-capable) build label."""
    return _JENKINS_CHECK_LABELS.get((platform, arch)) or _jenkins_label(platform, arch)


def _norm_arch(arch: str) -> str:
    return "aarch64" if arch in ("arm64", "aarch64") else "x86_64"


def _ondemand_image(libc: Optional[str], arch: str) -> Optional[str]:
    """The deterministic local tag `tasks.sh image` builds on demand for this unit.
    None for macos/windows, which have no container."""
    family = _LIBC_FAMILY.get(libc or "")
    return f"couchbase/pycbc-ci-{family}_{_norm_arch(arch)}:local" if family else None


def _cibw_image_var(libc: str, arch: str) -> str:
    fam = "MANYLINUX" if libc == "manylinux" else "MUSLLINUX"
    return f"CBCI_{fam}_{_norm_arch(arch).upper()}_IMAGE"


def _requested_tokens() -> List[str]:
    """The lowercased distro/label tokens the user requested via PLATFORMS (space/comma
    separated). Empty list = no filter (fan out to every label on each platform)."""
    raw = (os.environ.get("PLATFORMS") or "").strip()
    return [p.strip().lower() for p in raw.replace(",", " ").split() if p.strip()]


def _abstract_platforms(tokens: List[str]) -> set:
    """Union the requested distro/label tokens down to abstract platforms.

    An unresolvable token is FATAL. PLATFORMS narrows the fan-out, so a typo (`ubunut24`)
    dropped with a warning silently produces a matrix nobody asked for, and if it was the
    only token there is nothing left to narrow with and the run fans out to everything.
    Same contract as the engine's promoted vars.
    """
    out: set = set()
    bad: List[str] = []
    for t in tokens:
        abstract = _platform_token_to_abstract(t)
        if abstract is None:
            bad.append(t)
        else:
            out.add(abstract)
    if bad:
        known = sorted(_ABSTRACT_PLATFORMS | set(_PLATFORM_FAMILIES))
        print(f"ERROR: PLATFORMS: {sorted(set(bad))} not a known Jenkins platform, distro "
              f"family, or agent label (families and abstract platforms: {known}; raw agent "
              f"labels from those families are accepted too). Adding one is a "
              f"_PLATFORM_FAMILIES edit in jenkins.py.", file=sys.stderr)
        sys.exit(1)
    return out


def _tags_from_plan(plan: Dict[str, Any], requested: List[str]) -> Dict[str, Any]:
    """Translate the neutral plan into Jenkins jobs: one per build unit / validate cell /
    test cell, each carrying its agent `label` and the `env` the thin pipeline exports
    before `./tasks.sh <stage>`. Runner labels and container images are attached HERE
    (CONVENTIONS.md), never in the core or config. `sdist` is a single pre-step, no
    fan-out. `requested` is the lowercased PLATFORMS list driving the validate/test
    fan-out.
    """
    def _build_job(u: Dict[str, Any]) -> Dict[str, Any]:
        platform, arch, libc = u["platform"], u["arch"], u.get("libc")
        env = {"CBCI_BUILD_PLATFORM": platform, "CBCI_BUILD_ARCH": arch}
        if libc:
            env["CBCI_BUILD_LIBC"] = libc
        if not u["abi3"]:
            env["CBCI_PYTHON_VERSION"] = u["python"]
        image = _ondemand_image(libc, arch)
        if image:
            # one tag, build-then-consume: `tasks.sh image` builds CBCI_IMAGE; `tasks.sh
            # wheel` reads the libc/arch-matching CIBW var (both the same ref).
            env["CBCI_IMAGE"] = image
            env[_cibw_image_var(libc, arch)] = image
        # Jenkins HOW-policy (CONVENTIONS.md): cibuildwheel for containerized linux/alpine,
        # native pip-wheel for macos/windows, where cibuildwheel's interpreter provisioning
        # (sudo on mac, nuget on windows) is unwanted. Another vendor adapter may choose
        # `wheel` everywhere; the core exposes both verbs.
        stage = "wheel" if platform in ("linux", "alpine") else "wheel-native"
        job = {"label": _jenkins_label(platform, arch), "stage": stage}
        # "python" is present only on non-abi3 units (one build unit per Python); propagate
        # it so the Jenkins side can give each Python its own parallel branch + wheel stash.
        # "build_python" is the mirror for abi3 units (the floor). Only wheel-native consumes
        # it: cibuildwheel provisions its own interpreter from CIBW_BUILD, but a native
        # macOS/Windows build compiles under whatever the agent installed.
        job.update({k: u[k] for k in ("platform", "arch", "libc", "abi3", "python", "build_python")
                    if k in u})
        job["env"] = env
        return job

    def _check_jobs(units: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        # PLATFORMS filters the fan-out: a distro family (amzn2) selects its labels for this
        # cell's arch, so listing amzn2 tests its x86 box AND its Graviton boxes. Empty
        # PLATFORMS means every label on the cell's platform (see _check_labels).
        jobs = []
        for u in units:
            for label in _check_labels(u["platform"], u["arch"], requested):
                env = {"CBCI_PYTHON_VERSION": u["python"], "CBCI_INSTALL_TYPE": u["install_type"]}
                job = {"label": label}
                job.update({k: u[k] for k in ("platform", "arch", "libc", "python", "install_type") if k in u})
                job["env"] = env
                jobs.append(job)
        return jobs

    return {
        "sdist": {"label": _JENKINS_SDIST_LABEL, "stage": "sdist", "env": {}},
        "build": [_build_job(u) for u in plan["build"]["units"]],
        "validate": _check_jobs(plan["validate"]["units"]),
        "test": _check_jobs(plan["test"]["units"]),
    }


def tags(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Full pipeline: build the neutral plan (narrowed to the requested platforms) and
    translate it into the Jenkins job plan the groovy consumes.

    Owns PLATFORMS: reads the distro/label tokens, hides them from the neutral engine
    (which speaks only abstract platforms) while it loads config, narrows the plan to the
    derived abstract set, then fans validate/test out over the raw distro tokens.
    """
    requested = _requested_tokens()
    abstract = _abstract_platforms(requested)
    # Hide vendor tokens from the neutral engine's PLATFORMS handling, then restore. The
    # engine would (correctly) reject distro/label tokens as non-abstract.
    saved = os.environ.pop("PLATFORMS", None)
    try:
        cfg = engine.load_config(config_path)
    finally:
        if saved is not None:
            os.environ["PLATFORMS"] = saved
    if abstract:
        engine.narrow_to_platforms(cfg, abstract)
    plan = engine.build_plan(cfg)
    return _tags_from_plan(plan, requested)


# ---------------------------------------------------------------------------
# Integration tests (cbdyncluster)
# ---------------------------------------------------------------------------

# Jenkins agent for integration testing: needs the cbdyncluster CLI, which (unlike
# cbdinocluster) is only installed on this class of QE agent. A single platform is
# deliberate; integration coverage comes from the server-version matrix, not from
# build-platform breadth.
_JENKINS_INTEGRATION_LABEL = "sdkqe-rockylinux9"

# The wheel under test is built once per Python via the same containerized cibuildwheel
# path the main build pipeline uses (linux/x86_64/manylinux, qe-docker). A single fixed
# unit, since integration does not fan out across platform/arch.
_INTEGRATION_BUILD_PLATFORM = "linux"
_INTEGRATION_BUILD_ARCH = "x86_64"
_INTEGRATION_BUILD_LIBC = "manylinux"


def _cbdyn_topology(server_version: str) -> List[str]:
    """Per-node `cbdyncluster setup --node=<services>` list for one server version.

    The node/service split decides what a real cluster can actually test (fts/cbas/eventing
    placement), so the branches are version-specific rather than one generic topology.
    """
    version = server_version.split("-", 1)[0]
    if version >= "7.0":
        return ["kv,index,n1ql", "kv,index,n1ql,eventing", "kv,index,n1ql,fts,cbas"]
    if version >= "6.0":
        return ["kv,index,n1ql", "kv,index,n1ql", "kv,index,n1ql,fts,cbas"]
    return ["kv,index,n1ql", "kv,index,n1ql", "kv,index,n1ql,fts"]


def _resolve_server_versions(spec: Dict[str, Any]) -> List[str]:
    """Resolve `test.integration.server_versions` to a concrete list, logging the choice
    (stderr) so a CI run's console output records exactly what it tested.

    SERVER_VERSIONS (env, comma/space list) wins outright, so a random-subset failure can
    be reproduced exactly. Otherwise: one random version per era-group when version_subset
    is set, which keeps the matrix broad without exhaustive runtime, else every version in
    every group.
    """
    pin = (os.environ.get("SERVER_VERSIONS") or "").strip()
    if pin:
        versions = [v.strip() for v in pin.replace(",", " ").split() if v.strip()]
        print(f"[integration-tags] SERVER_VERSIONS pin: {versions}", file=sys.stderr)
        return versions

    groups = spec.get("server_versions", [])
    if spec.get("version_subset", True):
        versions = [random.choice(group) for group in groups if group]
    else:
        versions = [v for group in groups for v in group]
    print(f"[integration-tags] resolved server versions: {versions}", file=sys.stderr)
    return versions


def _resolve_integration_python_versions(pyvers: List[str]) -> List[str]:
    """cbdyncluster runs are expensive (real server clusters), so integration defaults to
    testing ONE python version per run rather than the whole support matrix: randomly the
    min or max of `support.python_versions`, on the theory that the oldest/newest
    interpreter is where a version-specific regression is most likely to show up.

    An explicit PYTHON_VERSIONS (env) escapes this default: engine.py's promoted vars have
    already narrowed `support.python_versions` to exactly what was requested before this
    runs, so that case passes `pyvers` through unchanged.
    """
    if (os.environ.get("PYTHON_VERSIONS") or "").strip():
        print(f"[integration-tags] PYTHON_VERSIONS override: testing {pyvers}", file=sys.stderr)
        return pyvers
    if len(pyvers) <= 1:
        return pyvers
    ordered = sorted(pyvers, key=lambda v: tuple(int(p) for p in v.split(".")))
    chosen = random.choice([ordered[0], ordered[-1]])
    print(
        f"[integration-tags] no PYTHON_VERSIONS override; randomly testing one version: "
        f"{chosen} (min={ordered[0]}, max={ordered[-1]})",
        file=sys.stderr,
    )
    return [chosen]


def integration_tags(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Emit the Jenkins integration-test job plan: one `build` job per Python (the wheel
    under test) and one `test` cell per (python x server_version), each carrying its
    cbdyncluster provisioning params and the CBCI_* env `tasks.sh test` needs to run
    against a realserver cluster.

    The Python fan-out defaults to a single version rather than the full support matrix, to
    keep the per-run cbdyncluster footprint small. See _resolve_integration_python_versions.
    """
    cfg = engine.load_config(config_path)
    spec = cfg.raw.get("test", {}).get("integration", {})
    pyvers = _resolve_integration_python_versions(list(cfg.raw.get("support", {}).get("python_versions", [])))
    versions = _resolve_server_versions(spec)

    build_jobs = []
    for py in pyvers:
        env = {
            "CBCI_BUILD_PLATFORM": _INTEGRATION_BUILD_PLATFORM,
            "CBCI_BUILD_ARCH": _INTEGRATION_BUILD_ARCH,
            "CBCI_BUILD_LIBC": _INTEGRATION_BUILD_LIBC,
            "CBCI_PYTHON_VERSION": py,
        }
        image = _ondemand_image(_INTEGRATION_BUILD_LIBC, _INTEGRATION_BUILD_ARCH)
        if image:
            env["CBCI_IMAGE"] = image
            env[_cibw_image_var(_INTEGRATION_BUILD_LIBC, _INTEGRATION_BUILD_ARCH)] = image
        build_jobs.append({
            "label": _jenkins_label(_INTEGRATION_BUILD_PLATFORM, _INTEGRATION_BUILD_ARCH),
            "python": py,
            # An abi3 wheel is tagged for the stable-ABI floor (cpXY-abi3), not for
            # `python`, so the groovy cannot select it from a prior build's artifacts by
            # this job's interpreter tag. Carry the flag so it can filter on abi3 instead.
            "abi3": bool(cfg.raw.get("build", {}).get("abi3", False)),
            "env": env,
        })

    test_cells = []
    for py in pyvers:
        for server_version in versions:
            test_cells.append({
                "label": _JENKINS_INTEGRATION_LABEL,
                "python": py,
                "server_version": server_version,
                "num_nodes": spec.get("num_nodes", 3),
                "node_topology": _cbdyn_topology(server_version),
                "ram_quota": spec.get("ram_quota", 2048),
                "storage_mode": spec.get("storage_mode", "plasma"),
                "buckets": spec.get("buckets", ["default"]),
                "sample_buckets": spec.get("sample_buckets", []),
                "developer_preview": spec.get("developer_preview", False),
                "env": {
                    "CBCI_TEST_CLUSTER": "realserver",
                    "CBCI_INSTALL_TYPE": "wheel",
                    "CBCI_PYTHON_VERSION": py,
                },
            })

    return {"build": build_jobs, "test": test_cells}


# ---------------------------------------------------------------------------
# Release verify (post-publish install check)
# ---------------------------------------------------------------------------


def verify_tags(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Emit the Jenkins release-verify job plan: one cell per (platform, arch, python),
    installing the PUBLISHED package (CBCI_PACKAGING_INDEX=PYPI|TEST_PYPI, set by the
    pipeline per its PYPI_LOCATION param) via the SAME `validate` stage the build pipeline
    already runs.

    There is no install_type dimension here: the index install goes by package name, not by
    local artifact file, so two cells differing only by install_type would be duplicates,
    and the dedup below collapses them. No `build`/`sdist` job either, since nothing is
    compiled. PLATFORMS/ARCHES/PYTHON_VERSIONS narrowing works exactly as in `tags`.
    """
    requested = _requested_tokens()
    abstract = _abstract_platforms(requested)
    saved = os.environ.pop("PLATFORMS", None)
    try:
        cfg = engine.load_config(config_path)
    finally:
        if saved is not None:
            os.environ["PLATFORMS"] = saved
    if abstract:
        engine.narrow_to_platforms(cfg, abstract)
    plan = engine.build_plan(cfg)

    seen: set = set()
    units: List[Dict[str, Any]] = []
    for u in plan["validate"]["units"]:
        key = (u["platform"], u["arch"], u["python"])
        if key in seen:
            continue
        seen.add(key)
        units.append(u)

    cells: List[Dict[str, Any]] = []
    for u in units:
        for label in _check_labels(u["platform"], u["arch"], requested):
            cell: Dict[str, Any] = {"label": label, "platform": u["platform"], "arch": u["arch"], "python": u["python"]}
            if u.get("libc"):
                cell["libc"] = u["libc"]
            # CBCI_PACKAGING_INDEX / CBCI_VERSION come from pipeline params (PYPI_LOCATION,
            # COUCHBASE_VERSION), so the groovy sets them rather than this adapter.
            cell["env"] = {}
            cells.append(cell)
    return {"verify": cells}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="jenkins.py", description="Jenkins adapter for the CI core")
    parser.add_argument("--config", help="path to ci-config.yaml (default: alongside engine.py)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tags", help="emit the Jenkins job plan (JSON)")
    sub.add_parser("integration-tags", help="emit the cbdyncluster integration-test job plan (JSON)")
    sub.add_parser("verify-tags", help="emit the release-verify (post-publish install check) job plan (JSON)")

    args = parser.parse_args(argv)
    if args.cmd == "tags":
        print(json.dumps(tags(args.config)))
    elif args.cmd == "integration-tags":
        print(json.dumps(integration_tags(args.config)))
    elif args.cmd == "verify-tags":
        print(json.dumps(verify_tags(args.config)))
    else:  # pragma: no cover - argparse enforces
        parser.error(f"unknown command: {args.cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
