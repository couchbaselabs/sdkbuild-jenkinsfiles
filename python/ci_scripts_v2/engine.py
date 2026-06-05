#!/usr/bin/env python3
"""engine.py — CI-core brain for the Couchbase Python SDK.

Responsibilities (single file by design; growth = new subcommands, not new files):
  * load + merge + validate config (ci-config.yaml < CBCI_CONFIG_OVERRIDE < promoted vars)
  * emit a vendor-NEUTRAL build plan (no runner labels)
  * vendor ADAPTERS that translate the neutral plan -> GHA matrix / Jenkins tags
    (runner labels + images are attached HERE, never in the core or config)
  * robust test-setup generation (conftest / pytest.ini / dev-requirements)

Phase 1 scaffold: structure + dispatch are real; stage logic is stubbed with TODOs
pointing at the proven snippets in the prototype (gha/pygha.py, gha/gha.sh).

Reference for porting:
  * config parse/merge/validate ....... gha/pygha.py ConfigHandler / UserConfigHandler
  * stage matrices (per-vendor today) .. gha/pygha.py StageMatrixConfigHandler
  * test-setup generation ............. gha/pygha.py TestConfigHandler
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

CONFIG_FILENAME = "ci-config.yaml"

# Promoted override vars (empty = use file). Map 1:1 to Jenkins params / GHA inputs.
PROMOTED_VARS = ("PLATFORMS", "ARCHES", "PYTHON_VERSIONS", "USE_OPENSSL", "OPENSSL_VERSION", "ABI3")


# ---------------------------------------------------------------------------
# Config loading + merge
# ---------------------------------------------------------------------------


@dataclass
class Config:
    """Resolved, merged configuration. The single in-memory source of truth."""

    raw: Dict[str, Any] = field(default_factory=dict)

    @property
    def project(self) -> str:
        return self.raw.get("project", "PYCBC")


def _load_yaml(path: str) -> Dict[str, Any]:
    """Load ci-config.yaml.

    TODO(Phase 1): use PyYAML if available; otherwise document that the runner
    image must provide it. Keep the dependency surface tiny (stdlib + yaml).
    """
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:
        print("ERROR: PyYAML is required to load ci-config.yaml", file=sys.stderr)
        sys.exit(1)
    with open(path, "r") as f:
        return yaml.safe_load(f) or {}


def _deep_merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge `over` onto `base`. Dicts merge key-wise; everything else
    (scalars AND lists) overwrites — a list override replaces, never concatenates."""
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def _parse_list(value: str) -> List[str]:
    """Split a promoted-var list: comma- or space-separated (mirrors the prototype's
    `"${PLATFORMS}".split()` / `.replace(',', ' ').split()`)."""
    return [tok.strip() for tok in value.replace(",", " ").split() if tok.strip()]


def _apply_config_override(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Deep-merge CBCI_CONFIG_OVERRIDE (one JSON object string) over the file config.

    Tolerates a stray wrapping quote (a JSON string can pick one up when passed
    through a container/CLI layer — the prototype's user_config_as_json unwrap).
    Invalid JSON warns and is ignored rather than hard-failing the run.
    """
    raw = os.environ.get("CBCI_CONFIG_OVERRIDE")
    if not raw or not raw.strip():
        return cfg
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
        raw = raw[1:-1].strip()
    try:
        override = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"WARNING: CBCI_CONFIG_OVERRIDE is not valid JSON ({e}); ignoring", file=sys.stderr)
        return cfg
    if not isinstance(override, dict):
        print("WARNING: CBCI_CONFIG_OVERRIDE must be a JSON object; ignoring", file=sys.stderr)
        return cfg
    return _deep_merge(cfg, override)


def _apply_promoted_vars(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Apply promoted override vars (HIGHEST precedence). Each is empty = leave as-is.
    Values are comma/space lists, validated against the support matrix; unsupported
    entries warn and are dropped (never hard-fail on a stray value). Mirrors the
    prototype's set_python_versions / set_os_and_arch, adapted to our nested support
    matrix (per-arch platform lists).
    """
    support = cfg.setdefault("support", {})
    build = cfg.setdefault("build", {})

    # PYTHON_VERSIONS — filter to supported; keep file default if nothing valid.
    pv = (os.environ.get("PYTHON_VERSIONS") or "").strip()
    if pv:
        supported = support.get("python_versions", [])
        chosen = []
        for v in _parse_list(pv):
            if v in supported:
                chosen.append(v)
            else:
                print(f"WARNING: unsupported python version '{v}' (not in support matrix); ignoring", file=sys.stderr)
        if chosen:
            support["python_versions"] = chosen

    # ARCHES — normalize aarch64->arm64, filter to supported.
    ar = (os.environ.get("ARCHES") or "").strip()
    if ar:
        supported = support.get("architectures", [])
        chosen: List[str] = []
        for a in _parse_list(ar):
            a = "arm64" if a == "aarch64" else a
            a = "x86_64" if a == "x64" else a
            if a not in supported:
                print(f"WARNING: unsupported arch '{a}' (not in support matrix); ignoring", file=sys.stderr)
            elif a not in chosen:
                chosen.append(a)
        if chosen:
            support["architectures"] = chosen

    # PLATFORMS — intersect each (selected) arch's platform list with the request.
    pf = (os.environ.get("PLATFORMS") or "").strip()
    if pf:
        requested = _parse_list(pf)
        concrete_map = {
            "ubuntu20": "linux", "ubuntu24": "linux", "centos7": "linux",
            "almalinux8": "linux", "amzn2": "linux", "rhel9": "linux",
            "qe-ubuntu20-arm64": "linux", "qe-ubuntu22-arm64": "linux",
            "qe-ubuntu24-arm64": "linux", "qe-grav2-amzn2": "linux",
            "qe-rhel9-arm64": "linux",
            "alpine": "alpine", "alpine3.20": "alpine", "alpine3.21": "alpine",
            "macos": "macos", "m1": "macos", "windows": "windows"
        }
        normalized_requested = []
        for p in requested:
            norm_p = concrete_map.get(p.lower()) or p
            normalized_requested.append(norm_p)
        plats = support.get("platforms", {})
        arches = support.get("architectures", [])
        valid_anywhere = {p for a in arches for p in plats.get(a, [])}
        for p, norm_p in zip(requested, normalized_requested):
            if norm_p not in valid_anywhere:
                print(f"WARNING: platform '{p}' (normalized: '{norm_p}') not supported on any selected arch; ignoring", file=sys.stderr)
        req = set(normalized_requested)
        for a in arches:
            plats[a] = [p for p in plats.get(a, []) if p in req]

    # USE_OPENSSL / OPENSSL_VERSION — flip the SSL backend + pin.
    use_ssl = (os.environ.get("USE_OPENSSL") or "").strip()
    if use_ssl:
        build["ssl"] = "openssl" if use_ssl.lower() in ("1", "true", "y", "yes", "on") else "boringssl"
    ossl_ver = (os.environ.get("OPENSSL_VERSION") or "").strip()
    if ossl_ver:
        build["openssl_version"] = ossl_ver

    # ABI3 — boolean override
    abi3 = (os.environ.get("ABI3") or "").strip()
    if abi3:
        build["abi3"] = abi3.lower() in ("1", "true", "y", "yes", "on")

    return cfg


def load_config(config_path: Optional[str] = None) -> Config:
    """Load + merge config with precedence: file < CBCI_CONFIG_OVERRIDE < promoted vars.

    Config path precedence: --config arg > CBCI_CONFIG_FILE env > ci-config.yaml
    alongside engine.py. The env hook lets tooling (e.g. the Phase 0 spike) point
    at an alternate config without editing the shipped default.
    """
    path = (
        config_path
        or os.environ.get("CBCI_CONFIG_FILE")
        or os.path.join(os.path.dirname(os.path.abspath(__file__)), CONFIG_FILENAME)
    )
    cfg = _load_yaml(path)
    cfg = _apply_config_override(cfg)
    cfg = _apply_promoted_vars(cfg)
    return Config(raw=cfg)


# ---------------------------------------------------------------------------
# Per-project facts + build-env exports (consumed by tasks.sh / tasks.ps1)
# ---------------------------------------------------------------------------

# Normalize the various project spellings to a canonical prefix.
PROJECT_ALIASES = {
    "PYCBC": "PYCBC", "OPERATIONAL": "PYCBC",
    "PYCBCC": "PYCBCC", "COLUMNAR": "PYCBCC",
    "PYCBAC": "PYCBAC", "ANALYTICS": "PYCBAC",
}

# The per-project version script run as `python <script> --mode make`.
VERSION_SCRIPTS = {
    "PYCBC": "couchbase_version.py",
    "PYCBCC": "couchbase_columnar_version.py",
    "PYCBAC": "couchbase_analytics_version.py",
}

# Pure-Python project(s) that have no C++ core to configure (skip configure_ext).
PURE_PYTHON_PROJECTS = {"PYCBAC"}

# Per-project package facts for validate/test (Phase 1 exercises PYCBC only):
#   import  — top-level import package the smoke imports
#   dist    — pip distribution name (find-links / index install target)
#   metadata— exposes `get_metadata(detailed=True)` (the proven init smoke); PYCBC +
#             columnar do, analytics (pure-python) does not.
PROJECT_PACKAGES = {
    "PYCBC":  {"import": "couchbase",            "dist": "couchbase",            "metadata": True},
    "PYCBCC": {"import": "couchbase_columnar",   "dist": "couchbase-columnar",   "metadata": True},
    "PYCBAC": {"import": "couchbase_analytics",  "dist": "couchbase-analytics",  "metadata": False},
}


def resolve_project(cfg: Config) -> str:
    """Canonical project prefix. CBCI_PROJECT_TYPE (env) wins over ci-config `project`."""
    raw = os.environ.get("CBCI_PROJECT_TYPE") or cfg.project
    prefix = PROJECT_ALIASES.get(str(raw).upper())
    if prefix is None:
        print(f"ERROR: unknown project: {raw}", file=sys.stderr)
        sys.exit(1)
    # Phase 1 scope is PYCBC only; others are mapped but not yet exercised.
    return prefix


def _as_bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "y", "yes", "on")


def _resolve_use_uv(cfg: Config) -> bool:
    """CBCI_USE_UV (env) wins over ci-config build.use_uv."""
    env = os.environ.get("CBCI_USE_UV")
    if env is not None:
        return _as_bool(env)
    return bool(cfg.raw.get("build", {}).get("use_uv", False))


def _resolve_verbose_makefile(cfg: Config) -> bool:
    """CBCI_VERBOSE_MAKEFILE (env) wins over ci-config build.verbose_makefile — lets a
    single debug run turn on CMake/compiler echo without editing the committed config."""
    env = os.environ.get("CBCI_VERBOSE_MAKEFILE")
    if env is not None:
        return _as_bool(env)
    return bool(cfg.raw.get("build", {}).get("verbose_makefile", False))


def project_env(cfg: Config) -> Dict[str, str]:
    """CBCI-level facts tasks.sh needs to drive a stage. Values are space-free."""
    prefix = resolve_project(cfg)
    return {
        "CBCI_PROJECT_PREFIX": prefix,
        "CBCI_VERSION_SCRIPT": VERSION_SCRIPTS[prefix],
        "CBCI_IS_PURE_PYTHON": "true" if prefix in PURE_PYTHON_PROJECTS else "false",
        "CBCI_USE_UV": "true" if _resolve_use_uv(cfg) else "false",
    }


def validate_env(cfg: Config) -> Dict[str, str]:
    """Facts tasks.sh needs to drive `validate` (and Phase 3 verify-release).

    Resolved in the ORCHESTRATOR venv (this needs yaml); the actual smoke runs in a
    CLEAN venv where only the SDK is installed, so tasks.sh passes these through as
    env to a dependency-free Python snippet. Values are space-free.
    """
    prefix = resolve_project(cfg)
    pkg = PROJECT_PACKAGES[prefix]
    test = cfg.raw.get("test", {})
    build = cfg.raw.get("build", {})
    install_types = test.get("install_types", ["sdist", "wheel"])
    ssl = str(build.get("ssl", "boringssl")).lower()
    return {
        "CBCI_VALIDATE_INSTALL_TYPES": ",".join(install_types),
        "CBCI_VALIDATE_PACKAGE": pkg["dist"],
        "CBCI_VALIDATE_IMPORT": pkg["import"],
        "CBCI_VALIDATE_HAS_METADATA": "true" if pkg["metadata"] else "false",
        "CBCI_VALIDATE_SSL": ssl,
    }


# Per-stage list of build knobs to emit. sdist only needs enough to bake the CPM
# cache; wheel needs the full set (ported from gha/pygha.py DEFAULT_CONFIG).
_STAGE_BUILD_KEYS = {
    "sdist": ("set_cpm_cache", "build_type", "verbose_makefile"),
    "wheel": ("use_openssl", "openssl_version", "build_type", "abi3", "verbose_makefile", "set_cpm_cache"),
}


def build_env(cfg: Config, stage: str) -> Dict[str, str]:
    """Emit `{PREFIX}_*` env that setup.py / CMake read for the given stage.

    Mirrors the old gha.sh parse_build_config -> SDKPROJECT_* aliasing, but sourced
    from the merged ci-config rather than a JSON blob. Values are space-free so
    callers can `export $(engine.py build-env <stage>)`.
    """
    if stage not in _STAGE_BUILD_KEYS:
        print(f"ERROR: build-env: unknown stage: {stage}", file=sys.stderr)
        sys.exit(1)
    prefix = resolve_project(cfg)
    build = cfg.raw.get("build", {})
    ssl = str(build.get("ssl", "boringssl")).lower()
    out: Dict[str, str] = {}
    for key in _STAGE_BUILD_KEYS[stage]:
        if key == "set_cpm_cache":
            out[f"{prefix}_SET_CPM_CACHE"] = "ON" if build.get("set_cpm_cache", True) else "OFF"
        elif key == "build_type":
            out[f"{prefix}_BUILD_TYPE"] = str(build.get("build_type", "RelWithDebInfo"))
        elif key == "use_openssl":
            out[f"{prefix}_USE_OPENSSL"] = "ON" if ssl == "openssl" else "OFF"
        elif key == "openssl_version":
            ver = build.get("openssl_version")
            if ssl == "openssl" and ver:
                out[f"{prefix}_OPENSSL_VERSION"] = str(ver)
        elif key == "abi3":
            # abi3 (Py_LIMITED_API) -> only set the flag when enabled (matches old behavior)
            if build.get("abi3", False):
                out[f"{prefix}_LIMITED_API"] = "ON"
        elif key == "verbose_makefile":
            if _resolve_verbose_makefile(cfg):
                out[f"{prefix}_VERBOSE_MAKEFILE"] = "ON"
    return out


# ---------------------------------------------------------------------------
# cibuildwheel selector (CIBW_*) — the build-unit dimensions come from the env
# the vendor adapter sets per unit (CBCI_BUILD_PLATFORM/ARCH/LIBC, CBCI_PYTHON_VERSION).
# ---------------------------------------------------------------------------


def _py_tag(version: str) -> str:
    """'3.11' -> 'cp311-*' (a cibuildwheel build selector)."""
    return "cp" + version.replace(".", "") + "-*"


def _min_python(versions: List[str]) -> str:
    return min(versions, key=lambda v: tuple(int(x) for x in v.split(".")))


def _cibw_arch(platform: str, arch: str) -> str:
    """Map abstract platform/arch to a cibuildwheel CIBW_ARCHS value."""
    if platform == "macos":
        return "arm64" if arch in ("arm64", "aarch64") else "x86_64"
    # linux / alpine
    return "aarch64" if arch in ("arm64", "aarch64") else "x86_64"


def wheel_env(cfg: Config) -> Dict[str, str]:
    """Emit CIBW_* selector knobs for one build unit.

    Build-unit dimensions are read from the env the adapter sets per unit:
      CBCI_BUILD_PLATFORM (linux|alpine|macos), CBCI_BUILD_ARCH (x86_64|arm64),
      CBCI_BUILD_LIBC (manylinux|musllinux), CBCI_PYTHON_VERSION (non-abi3 fan-out).
    Values may contain spaces (multi-pattern CIBW_BUILD), so callers must read
    these LINE-BY-LINE, not via `export $(...)`.
    """
    support = cfg.raw.get("support", {})
    build = cfg.raw.get("build", {})
    pyvers = list(support.get("python_versions", []))
    abi3 = bool(build.get("abi3", False))
    platform = (os.environ.get("CBCI_BUILD_PLATFORM") or "").lower()
    libc = (os.environ.get("CBCI_BUILD_LIBC") or "").lower()
    arch = (os.environ.get("CBCI_BUILD_ARCH") or "").lower()
    single = os.environ.get("CBCI_PYTHON_VERSION")

    out: Dict[str, str] = {}

    # CIBW_PLATFORM: cibuildwheel defaults to `auto` (the HOST os). Pin it to the
    # build unit's platform so a linux unit builds in the manylinux/musllinux
    # container even when the orchestrator runs on macOS/Windows. linux + alpine
    # are both cibuildwheel's `linux` platform (the libc split is via CIBW_SKIP).
    cibw_platform = {"linux": "linux", "alpine": "linux", "macos": "macos", "windows": "windows"}.get(platform)
    if cibw_platform:
        out["CIBW_PLATFORM"] = cibw_platform

    # CIBW_BUILD: abi3 -> build once on the lowest python (the wheel is abi3-tagged
    # and forward-compatible). Non-abi3 -> a single python (per-unit fan-out) or all.
    if abi3 and pyvers:
        out["CIBW_BUILD"] = _py_tag(_min_python(pyvers))
    elif single:
        out["CIBW_BUILD"] = _py_tag(single)
    elif pyvers:
        out["CIBW_BUILD"] = " ".join(_py_tag(v) for v in pyvers)

    # CIBW_SKIP: never PyPy; restrict libc flavor on linux.
    skips = ["pp*"]
    if platform in ("linux", "alpine", ""):
        if platform == "alpine" or libc == "musllinux":
            skips.append("*-manylinux*")
        else:
            skips.append("*-musllinux*")
    out["CIBW_SKIP"] = " ".join(skips)

    if arch:
        out["CIBW_ARCHS"] = _cibw_arch(platform, arch)

    out["CIBW_BUILD_FRONTEND"] = "build[uv]" if _resolve_use_uv(cfg) else "pip"
    return out


# ---------------------------------------------------------------------------
# Neutral build plan (no runner labels — see CONVENTIONS.md §2)
# ---------------------------------------------------------------------------


def build_plan(cfg: Config) -> Dict[str, Any]:
    """Emit the vendor-NEUTRAL plan (ABSTRACT dimensions only — no runner labels or
    container images; those are attached by the adapter). See CONVENTIONS §2 / PLAN §4.

      * build units: abi3=true  -> one unit per (platform, arch, libc, ssl), pythons[]
                     abi3=false -> additionally keyed by python (one per python)
      * validate / test:         per (platform, arch, libc?, python, install_type)
                                 — wide fan-out for parallelism / fast feedback.
    libc (manylinux/musllinux) is present only for linux/alpine units, never macos/windows.
    """
    support = cfg.raw.get("support", {})
    build = cfg.raw.get("build", {})
    pyvers = list(support.get("python_versions", []))
    arches = list(support.get("architectures", []))
    plats_by_arch = support.get("platforms", {})
    libc_map = build.get("libc", {})
    ssl = str(build.get("ssl", "boringssl")).lower()
    abi3 = bool(build.get("abi3", False))
    build_type = str(build.get("build_type", "RelWithDebInfo"))
    install_types = list(cfg.raw.get("test", {}).get("install_types", ["sdist", "wheel"]))

    def _keyed(platform: str, arch: str, libc: Optional[str]) -> Dict[str, Any]:
        d: Dict[str, Any] = {"platform": platform, "arch": arch}
        if libc:
            d["libc"] = libc
        return d

    build_units: List[Dict[str, Any]] = []
    validate_units: List[Dict[str, Any]] = []
    test_units: List[Dict[str, Any]] = []
    seen: set = set()

    for arch in arches:
        for platform in plats_by_arch.get(arch, []):
            seen.add(platform)
            libc = libc_map.get(platform)  # None for macos/windows
            if abi3:
                unit = _keyed(platform, arch, libc)
                unit.update({"ssl": ssl, "abi3": True, "pythons": pyvers, "build_type": build_type})
                build_units.append(unit)
            else:
                for py in pyvers:
                    unit = _keyed(platform, arch, libc)
                    unit.update({"ssl": ssl, "abi3": False, "python": py, "build_type": build_type})
                    build_units.append(unit)
            for py in pyvers:
                for itype in install_types:
                    cell = _keyed(platform, arch, libc)
                    cell.update({"python": py, "install_type": itype})
                    validate_units.append(dict(cell))
                    test_units.append(dict(cell))

    return {
        "build": {
            "has_linux": "linux" in seen,
            "has_macos": "macos" in seen,
            "has_windows": "windows" in seen,
            "has_alpine": "alpine" in seen,
            "units": build_units,
        },
        "validate": {"units": validate_units},
        "test": {"units": test_units},
    }


def validate_config(cfg: Config) -> tuple:
    """Coherence-check the MERGED config. Returns (errors, warnings). Errors are
    fatal (e.g. an override emptied the matrix); warnings are advisory."""
    errors: List[str] = []
    warnings: List[str] = []
    support = cfg.raw.get("support", {})
    build = cfg.raw.get("build", {})

    if not support.get("python_versions"):
        errors.append("support.python_versions is empty (an override may have dropped everything)")
    if not support.get("architectures"):
        errors.append("support.architectures is empty")
    for arch in support.get("architectures", []):
        if not support.get("platforms", {}).get(arch):
            warnings.append(f"no platforms selected for arch '{arch}' — it will produce no units")

    ssl = str(build.get("ssl", "boringssl")).lower()
    if ssl not in ("boringssl", "openssl"):
        errors.append(f"build.ssl must be boringssl|openssl (got '{ssl}')")
    if ssl == "openssl" and not build.get("openssl_version"):
        warnings.append("build.ssl=openssl but build.openssl_version is unset")
    return errors, warnings


# ---------------------------------------------------------------------------
# Vendor adapters — the ONLY place runner labels + images live
# ---------------------------------------------------------------------------


def adapter_gha_matrix(plan: Dict[str, Any]) -> Dict[str, Any]:
    """Translate the neutral plan into a GitHub Actions matrix JSON.

    TODO(Phase 1): map platform/arch/libc -> runs-on label (ubuntu-22.04, macos-14,
    windows-2022) + container image; emit per-stage matrices with excludes.
    Reference the old GHA shape in StageMatrixConfigHandler._stage_matrix_as_dict.
    """
    return {}


# EDIT FOR YOUR JENKINS — the ONE deployment-specific thing (CONVENTIONS §4). Three label
# roles, because they need different agents (taken from the proven scripted-build-pipeline):
#
#   _JENKINS_LABELS       WHEEL build. linux/alpine run the thin manylinux/musllinux IMAGE,
#                         so the agent is a DOCKER HOST of the right arch (qe-docker[-aarch64]).
#                         macOS/Windows build natively, so real arch-specific agents.
#   _JENKINS_SDIST_LABEL  sdist runs NATIVELY (configure_ext needs cmake + the C++ toolchain),
#                         so a build-capable linux node (old DEFAULT_PLATFORM).
#   _JENKINS_CHECK_LABELS validate/test-unit install + run the artifact NATIVELY. Default =
#                         the build label; override per (platform,arch) for broader distro
#                         coverage (a manylinux wheel runs on any glibc distro).
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

_LIBC_FAMILY = {"manylinux": "manylinux_2_28", "musllinux": "musllinux_1_2"}


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
    """The deterministic local tag `tasks.sh image` builds for this unit (PLAN §9:
    build on demand). None for macos/windows (no container)."""
    family = _LIBC_FAMILY.get(libc or "")
    return f"couchbase/pycbc-ci-{family}_{_norm_arch(arch)}:local" if family else None


def _cibw_image_var(libc: str, arch: str) -> str:
    fam = "MANYLINUX" if libc == "manylinux" else "MUSLLINUX"
    return f"CBCI_{fam}_{_norm_arch(arch).upper()}_IMAGE"


def adapter_jenkins_tags(plan: Dict[str, Any]) -> Dict[str, Any]:
    """Translate the neutral plan into Jenkins jobs: one per build unit / validate cell /
    test cell, each carrying its agent `label` + the `env` the thin pipeline exports before
    `./tasks.sh <stage>`. Runner labels + container images are attached HERE (CONVENTIONS §4),
    never in the core/config. `sdist` is a single pre-step (no fan-out).
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
        job = {"label": _jenkins_label(platform, arch), "stage": "wheel"}
        job.update({k: u[k] for k in ("platform", "arch", "libc", "abi3") if k in u})
        job["env"] = env
        return job

    # Define concrete test/validation check labels per (platform, arch)
    check_labels_map = {
        ("linux", "x86_64"):   ["ubuntu20", "ubuntu24", "centos7", "almalinux8", "amzn2", "rhel9"],
        ("linux", "arm64"):    ["qe-ubuntu20-arm64", "qe-ubuntu22-arm64", "qe-ubuntu24-arm64", "qe-grav2-amzn2", "qe-rhel9-arm64"],
        ("alpine", "x86_64"):  ["alpine"],
        ("macos", "x86_64"):   ["macos"],
        ("macos", "arm64"):    ["m1"],
        ("windows", "x86_64"): ["windows"],
    }

    def _check_jobs(units: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        # Get requested platforms from environment
        raw_pf = (os.environ.get("PLATFORMS") or "").strip()
        requested_platforms = [p.strip().lower() for p in raw_pf.replace(",", " ").split() if p.strip()]
        
        jobs = []
        for u in units:
            platform, arch = u["platform"], u["arch"]
            
            # Resolve all potential check labels
            labels = check_labels_map.get((platform, arch), [platform])
            
            # If user explicitly requested platforms, filter to only those matches
            if requested_platforms:
                filtered_labels = []
                for label in labels:
                    is_matched = False
                    for rp in requested_platforms:
                        if rp == label.lower():
                            is_matched = True
                        elif rp == "macos" and label.lower() in ("macos", "m1"):
                            is_matched = True
                        elif rp == "windows" and label.lower().startswith("windows"):
                            is_matched = True
                        elif rp == "linux" and label.lower() in [l.lower() for l in check_labels_map.get(("linux", "x86_64")) + check_labels_map.get(("linux", "arm64"))]:
                            is_matched = True
                        elif rp.startswith("alpine") and label.lower() == "alpine":
                            is_matched = True
                    if is_matched:
                        filtered_labels.append(label)
                labels = filtered_labels
                
            for label in labels:
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


# ---------------------------------------------------------------------------
# Test-setup generation (robust; no brittle sed) — see PLAN.md §2 decision 9
# ---------------------------------------------------------------------------


# Per-project artifact-isolation test layout. `rename` maps each repo API package to
# the short test-tree dir (couchbase->cb) so that, running from the test tree, there
# is NO `couchbase/` source dir to shadow the INSTALLED package — `import couchbase`
# resolves to the wheel/sdist under test (PLAN.md decision #9). Phase 1 exercises PYCBC.
PROJECT_TEST_LAYOUT = {
    "PYCBC": {
        "tree": "pycbc_test",
        "rename": {"acouchbase": "acb", "couchbase": "cb", "txcouchbase": "txcb"},
        "dev_requirements": "dev_requirements.txt",
        "reqs": ["pytest", "pytest-asyncio", "pytest-rerunfailures", "requests", "Faker", "faker-vehicle", "Twisted"],
        "test_ini": "operational",
    },
    "PYCBCC": {
        "tree": "pycbcc_test",
        "rename": {"acouchbase_columnar": "acb", "couchbase_columnar": "cb"},
        "dev_requirements": "dev_requirements.txt",
        "reqs": ["pytest", "pytest-asyncio", "pytest-rerunfailures", "requests"],
        "test_ini": "columnar",
    },
    "PYCBAC": {
        "tree": "pycbac_test",
        "rename": {"acouchbase_analytics": "acb", "couchbase_analytics": "cb"},
        "dev_requirements": "requirements-dev.in",
        "reqs": ["aiohttp", "pytest"],
        "test_ini": "analytics",
    },
}


def _load_tomllib():
    """Return a TOML loader: stdlib `tomllib` (py3.11+) or the `tomli` backport."""
    try:
        import tomllib  # type: ignore[import-not-found]
        return tomllib
    except ImportError:
        try:
            import tomli  # type: ignore[import-not-found]
            return tomli
        except ImportError:
            print("ERROR: tomllib (py3.11+) or tomli is required to parse pyproject.toml", file=sys.stderr)
            sys.exit(1)


def _transform_conftest(text: str, rename: Dict[str, str]) -> str:
    """Remap API package names to the renamed test-tree dirs — the robust, unit-tested
    replacement for the gha.sh `sed`. Faithful to the sed's INTENT (only path refs and
    EQUALITY-comparison string literals — NOT every `'couchbase'`, so it never clobbers
    e.g. `import_module('couchbase')`), but quote- and whitespace-agnostic and order-safe.

    Longest API name first so `couchbase` can't partial-match inside `acouchbase`.
    """
    for api in sorted(rename, key=len, reverse=True):
        short = rename[api]
        q = re.escape(api)
        # path refs:   <api>/tests -> <short>/tests   (boundary before <api>)
        text = re.sub(rf'(?<![\w.]){q}/tests', f'{short}/tests', text)
        # comparison literals on either side of ==/!=, single OR double quoted:
        text = re.sub(rf'(==|!=)(\s*)([\'"]){q}\3', rf'\1\2\3{short}\3', text)
        text = re.sub(rf'([\'"]){q}\1(\s*)(==|!=)', rf'\1{short}\1\2\3', text)
    return text


def _remap_testpath(testpath: str, rename: Dict[str, str]) -> str:
    """Remap a pyproject testpaths entry's leading API package (couchbase/... -> cb/...)."""
    for api in sorted(rename, key=len, reverse=True):
        if testpath == api or testpath.startswith(api + "/"):
            return rename[api] + testpath[len(api):]
    return testpath


def _build_pytest_ini(pyproject_path: str, rename: Dict[str, str]) -> str:
    """Render pytest.ini from pyproject's [tool.pytest.ini_options], remapping testpaths.

    Ported from gha/pygha.py build_pytest_ini, hardened: missing optional keys are
    skipped (not KeyError'd), and testpath remap is shared with the conftest transform.
    """
    tomllib = _load_tomllib()
    with open(pyproject_path, "rb") as f:
        data = tomllib.load(f)
    ini = data.get("tool", {}).get("pytest", {}).get("ini_options")
    if not isinstance(ini, dict):
        raise ValueError(f"no [tool.pytest.ini_options] table in {pyproject_path}")

    out: List[str] = ["[pytest]"]
    if ini.get("minversion") is not None:
        out.append(f'minversion = {ini["minversion"]}')
    out.append("testpaths =")
    for tp in ini.get("testpaths", []):
        out.append(f"    {_remap_testpath(tp, rename)}")
    for key in ("python_classes", "python_files", "markers"):
        val = ini.get(key)
        if val is None:
            continue
        if isinstance(val, list):
            if len(val) > 1:
                out.append(f"{key} =")
                out.extend(f"    {item}" for item in val)
            else:
                out.append(f"{key} = {val[0]}")
        else:
            out.append(f"{key} = {val}")
    out.append("")
    return "\n".join(out)


def _build_test_config_ini(prefix: str, cfg: Config) -> str:
    """Render tests/test_config.ini. Operational uses realserver/gocaves; values come
    from PYCBC_* / CBCI_* env with sensible defaults. (Columnar/analytics: Phase 4.)
    """
    if prefix != "PYCBC":
        raise NotImplementedError(f"test_config.ini for {prefix} not implemented (Phase 4)")

    # Read from CBCI_TEST_CLUSTER (mock | realserver), falling back to config 'test.cluster'
    # and then to 'mock' as the default for unit.
    cluster = os.environ.get("CBCI_TEST_CLUSTER") or cfg.raw.get("test", {}).get("cluster", "mock")

    host = os.environ.get("PYCBC_HOST") or os.environ.get("CBCI_TEST_HOST")
    if not host:
        host = "localhost" if cluster == "mock" else "127.0.0.1"

    port = os.environ.get("PYCBC_PORT", "8091")
    username = os.environ.get("PYCBC_USERNAME", "Administrator")
    password = os.environ.get("PYCBC_PASSWORD", "password")
    bucket = os.environ.get("PYCBC_BUCKET_NAME", "default")

    if cluster == "mock":
        real_enabled = "False"
        mock_enabled = "True"
    else:
        real_enabled = "True"
        mock_enabled = "False"

    return "\n".join([
        "[realserver]",
        f"enabled = {real_enabled}",
        f"host = {host}",
        f"port = {port}",
        f"admin_username = {username}",
        f"admin_password = {password}",
        f"bucket_name = {bucket}",
        f"bucket_password = {password}",
        "",
        "[gocaves]",
        f"enabled = {mock_enabled}",
        "version = v0.0.1-78",
        "url = https://github.com/couchbaselabs/gocaves/releases/download",
        "",
    ])


def _build_requirements_test(root: str, dev_req_name: str, reqs: List[str]) -> str:
    """Filter the repo's dev-requirements file down to the test deps `reqs`, preserving
    each matched line's version pin. Ported from gha/pygha.py build_test_requirements_file
    (incl. the `pytest` vs `pytest-asyncio` non-prefix-collision guard)."""
    path = os.path.join(root, dev_req_name)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"dev requirements file not found: {path}")
    with open(path, "r") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]

    sep = re.compile(r"[=~><!]")
    matched: List[str] = []
    for req in reqs:
        for line in lines:
            tok0 = sep.split(line)[0]
            # don't let bare "pytest" swallow "pytest-asyncio" (and vice-versa)
            if not ("-" not in req and "-" in tok0) and tok0.startswith(req):
                matched.append(line)
    if not reqs:
        matched = lines
    return "\n".join(matched + [""])


def _copy_py_tree(src_dir: str, dst_dir: str, only_py: bool) -> None:
    """Copy a test dir into the test tree. only_py: just *.py (api/tests); else everything."""
    if not os.path.isdir(src_dir):
        return
    os.makedirs(dst_dir, exist_ok=True)
    if only_py:
        for f in glob.glob(os.path.join(src_dir, "*.py")):
            shutil.copy2(f, dst_dir)
    else:
        shutil.copytree(src_dir, dst_dir, dirs_exist_ok=True)


def test_setup(cfg: Config, output_path: str) -> None:
    """Build the artifact-isolation test tree + generated config, PROGRAMMATICALLY
    (replaces gha.sh build_test_setup's mkdir/cp/sed + pygha.py). Prints the resolved
    test-tree path as the LAST stdout line so tasks.sh can cd into it.

    Layout (PYCBC): <output>/pycbc_test/{cb,acb,txcb}/tests + /tests + conftest.py +
    pytest.ini, and tests/test_config.ini + requirements-test.txt.
    """
    prefix = resolve_project(cfg)
    if prefix not in PROJECT_TEST_LAYOUT:
        print(f"ERROR: test-setup unsupported for project {prefix}", file=sys.stderr)
        sys.exit(1)
    layout = PROJECT_TEST_LAYOUT[prefix]
    root = os.environ.get("CBCI_PROJECT_ROOT") or os.getcwd()
    test_root = os.path.join(os.path.abspath(output_path), layout["tree"])
    rename = layout["rename"]

    # 1. Renamed API test dirs (couchbase/tests -> cb/tests) + package __init__.
    for api, short in rename.items():
        _copy_py_tree(os.path.join(root, api, "tests"),
                      os.path.join(test_root, short, "tests"), only_py=True)
        open(os.path.join(test_root, short, "__init__.py"), "a").close()

    # 2. Top-level tests/ (shared fixtures/helpers) copied verbatim.
    _copy_py_tree(os.path.join(root, "tests"), os.path.join(test_root, "tests"), only_py=False)

    # 3. conftest.py — transformed (programmatic remap, not sed).
    conftest_src = os.path.join(root, "conftest.py")
    if os.path.isfile(conftest_src):
        with open(conftest_src, "r") as f:
            transformed = _transform_conftest(f.read(), rename)
        with open(os.path.join(test_root, "conftest.py"), "w") as f:
            f.write(transformed)

    # 4. pytest.ini (remapped testpaths) at the tree root.
    pyproject = os.path.join(root, "pyproject.toml")
    if os.path.isfile(pyproject):
        with open(os.path.join(test_root, "pytest.ini"), "w") as f:
            f.write(_build_pytest_ini(pyproject, rename))

    # 5. tests/test_config.ini + requirements-test.txt.
    os.makedirs(os.path.join(test_root, "tests"), exist_ok=True)
    with open(os.path.join(test_root, "tests", "test_config.ini"), "w") as f:
        f.write(_build_test_config_ini(prefix, cfg))
    with open(os.path.join(test_root, "requirements-test.txt"), "w") as f:
        f.write(_build_requirements_test(root, layout["dev_requirements"], layout["reqs"]))

    # TODO(Phase 2): cbdino cluster_def.yaml for integration tests.
    print(test_root)


def test_cmds(cfg: Config) -> List[str]:
    """Pytest invocations for the test stage, one per API, from ci-config test.pytest.
    Each line is `<cmd> <opts>` ready to run (cmd carries the `-m '<markers>'`)."""
    override_cmd = os.environ.get("CBCI_TEST_COMMAND")
    override_args = os.environ.get("CBCI_TEST_ARGS") or ""

    if override_cmd:
        opts = override_args
        return [f"{override_cmd} {opts}".strip()]

    pytest_cfg = cfg.raw.get("test", {}).get("pytest", {})
    cmds: List[str] = []
    for api in ("acouchbase", "couchbase", "txcouchbase"):
        cmd = pytest_cfg.get(f"{api}_cmd")
        if cmd:
            opts = pytest_cfg.get(f"{api}_opts", "")
            if override_args:
                opts = f"{opts} {override_args}"
            cmds.append(f"{cmd} {opts}".strip())
    return cmds


# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------


def _emit(obj: Any) -> None:
    print(json.dumps(obj))


def _emit_pairs(pairs: Dict[str, str]) -> None:
    """Print KEY=VALUE pairs on one line for `export $(...)` consumption.

    Use only for space-free values.
    """
    print(" ".join(f"{k}={v}" for k, v in pairs.items()))


def _emit_lines(pairs: Dict[str, str]) -> None:
    """Print KEY=VALUE pairs one per line (values may contain spaces)."""
    for k, v in pairs.items():
        print(f"{k}={v}")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="engine.py", description="Couchbase Python SDK CI core")
    parser.add_argument("--config", help="path to ci-config.yaml (default: alongside engine.py)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("plan", help="emit the vendor-neutral build plan (JSON)")
    sub.add_parser("gha-matrix", help="adapter: neutral plan -> GitHub Actions matrix (JSON)")
    sub.add_parser("jenkins-tags", help="adapter: neutral plan -> Jenkins tags (JSON)")
    sub.add_parser("validate-config", help="load + merge + validate config, exit non-zero on error")
    sub.add_parser("project-env", help="emit CBCI_* project facts as KEY=VALUE pairs")
    sub.add_parser("validate-env", help="emit CBCI_VALIDATE_* facts for the validate stage")

    p_build_env = sub.add_parser("build-env", help="emit {PREFIX}_* build knobs as KEY=VALUE pairs")
    p_build_env.add_argument("stage", choices=("sdist", "wheel"), help="build stage")

    sub.add_parser("wheel-env", help="emit CIBW_* selector knobs (one KEY=VALUE per line)")

    p_setup = sub.add_parser("test-setup", help="generate the artifact-isolation test tree + config")
    p_setup.add_argument("output_path", help="directory to write the test tree into")

    sub.add_parser("test-cmds", help="emit pytest invocations (one per line)")

    args = parser.parse_args(argv)
    cfg = load_config(args.config)

    if args.cmd == "plan":
        _emit(build_plan(cfg))
    elif args.cmd == "gha-matrix":
        _emit(adapter_gha_matrix(build_plan(cfg)))
    elif args.cmd == "jenkins-tags":
        _emit(adapter_jenkins_tags(build_plan(cfg)))
    elif args.cmd == "validate-config":
        errors, warnings = validate_config(cfg)
        for w in warnings:
            print(f"WARNING: {w}", file=sys.stderr)
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            return 1
        print(f"config OK: project={resolve_project(cfg)}")
    elif args.cmd == "project-env":
        _emit_pairs(project_env(cfg))
    elif args.cmd == "validate-env":
        _emit_pairs(validate_env(cfg))
    elif args.cmd == "build-env":
        _emit_pairs(build_env(cfg, args.stage))
    elif args.cmd == "wheel-env":
        _emit_lines(wheel_env(cfg))
    elif args.cmd == "test-setup":
        test_setup(cfg, args.output_path)
    elif args.cmd == "test-cmds":
        for line in test_cmds(cfg):
            print(line)
    else:  # pragma: no cover - argparse enforces
        parser.error(f"unknown command: {args.cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
