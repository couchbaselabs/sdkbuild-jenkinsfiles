#!/usr/bin/env python3
"""engine.py - CI-core brain for the Couchbase Python SDK.

Responsibilities (single file by design; growth = new subcommands, not new files):
  * load + merge + validate config (ci-config.yaml < CBCI_CONFIG_OVERRIDE < promoted vars)
  * emit a vendor-NEUTRAL build plan (ABSTRACT platforms only, no runner labels/images)
  * test-setup generation (conftest / pytest.ini / dev-requirements)

Vendor-NEUTRAL: this module knows only abstract platforms (linux/alpine/macos/windows).
Runner labels, container images, and the distro/agent vocabulary live in the per-CI
adapter modules that `import engine` (jenkins.py, gha.py). The core must NEVER import an
adapter.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Union

CONFIG_FILENAME = "ci-config.yaml"

# Promoted override vars (empty = use file). Map 1:1 to Jenkins params / GHA inputs.
PROMOTED_VARS = ("PLATFORMS", "ARCHES", "PYTHON_VERSIONS", "USE_OPENSSL", "OPENSSL_VERSION", "ABI3", "INSTALL_TYPES")


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
    """Load ci-config.yaml. PyYAML is this core's only non-stdlib dependency."""
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:
        print("ERROR: PyYAML is required to load ci-config.yaml", file=sys.stderr)
        sys.exit(1)
    with open(path, "r") as f:
        return yaml.safe_load(f) or {}


def _deep_merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge `over` onto `base`. Dicts merge key-wise; everything else
    (scalars AND lists) overwrites: a list override replaces, never concatenates."""
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def _parse_list(value: str) -> List[str]:
    """Split a promoted-var list: comma- or space-separated."""
    return [tok.strip() for tok in value.replace(",", " ").split() if tok.strip()]


def _apply_config_override(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Deep-merge CBCI_CONFIG_OVERRIDE (one JSON object string) over the file config.

    Tolerates a stray wrapping quote, which a JSON string can pick up passing through a
    container/CLI layer. Invalid JSON warns and is ignored rather than failing the run.
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
    """Apply promoted override vars (HIGHEST precedence). Empty = leave as-is.

    Values are comma/space lists validated against the support matrix; an unsupported
    entry warns and is dropped rather than failing the run.
    """
    support = cfg.setdefault("support", {})
    build = cfg.setdefault("build", {})

    # PYTHON_VERSIONS: filter to supported; keep the file default if nothing valid.
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

    # ARCHES: normalize aarch64->arm64, filter to supported.
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

    # PLATFORMS: narrow each selected arch's platform list to the request. The engine speaks
    # ONLY abstract platforms (linux/alpine/macos/windows). Mapping vendor/distro tokens
    # (amzn2, m1, ubuntu-22.04) to abstract is the ADAPTER's job: it pops PLATFORMS and calls
    # narrow_to_platforms() itself. A non-abstract token here warns and is dropped, so a
    # stray distro token cannot silently keep a platform.
    pf = (os.environ.get("PLATFORMS") or "").strip()
    if pf:
        requested = _parse_list(pf)
        plats = support.get("platforms", {})
        arches = support.get("architectures", [])
        valid_anywhere = {p for a in arches for p in plats.get(a, [])}
        for p in requested:
            if p not in valid_anywhere:
                print(f"WARNING: platform '{p}' is not a supported abstract platform "
                      f"{sorted(valid_anywhere)}; ignoring (distro/label tokens belong to "
                      f"the CI adapter, not engine.py)", file=sys.stderr)
        _narrow_platforms(support, {p for p in requested if p in valid_anywhere})

    # USE_OPENSSL / OPENSSL_VERSION: flip the SSL backend + pin.
    use_ssl = (os.environ.get("USE_OPENSSL") or "").strip()
    if use_ssl:
        build["ssl"] = "openssl" if use_ssl.lower() in ("1", "true", "y", "yes", "on") else "boringssl"
    ossl_ver = (os.environ.get("OPENSSL_VERSION") or "").strip()
    if ossl_ver:
        build["openssl_version"] = ossl_ver

    # ABI3: tri-state override. Anything absent/empty (and the literal "auto") leaves the
    # commit gate's verdict standing; only an explicit true/false overrides it. A CI adapter
    # MUST NOT emit a bare boolean unconditionally: that silently outranks the gate on every
    # run, and `build.abi3.min_commit` can then never take effect.
    abi3 = (os.environ.get("ABI3") or "").strip().lower()
    if abi3 and abi3 != "auto":
        requested = abi3 in ("1", "true", "y", "yes", "on")
        build["abi3"] = requested
        cfg.setdefault(_GATE_KEY, {})["abi3_override"] = requested

    # INSTALL_TYPES: list override.
    itypes = (os.environ.get("INSTALL_TYPES") or "").strip()
    if itypes:
        test = cfg.setdefault("test", {})
        test["install_types"] = _parse_list(itypes)

    return cfg


def _narrow_platforms(support: Dict[str, Any], platforms: set) -> None:
    """Filter `support.platforms` per arch to exactly `platforms` (a set of ABSTRACT
    platform names). Mutates in place. An empty set narrows to NO platforms; callers that
    mean "no narrowing" must simply not call this."""
    plats = support.get("platforms", {})
    for a in support.get("architectures", []):
        plats[a] = [p for p in plats.get(a, []) if p in platforms]


def narrow_to_platforms(cfg: Config, platforms: Any) -> None:
    """Narrow the support matrix to a set of ABSTRACT platforms. The public hook for
    per-CI adapters: after translating their vendor/distro tokens to abstract platforms,
    an adapter calls this to scope `build_plan` before emitting jobs. Empty/falsey =
    no-op (the adapter keeps the full matrix)."""
    platset = {str(p).lower() for p in (platforms or [])}
    if platset:
        _narrow_platforms(cfg.raw.setdefault("support", {}), platset)


# Reserved top-level config key recording how each commit gate resolved. validate_config
# reads it; no other consumer (build_env / wheel_env / build_plan) looks at the config root,
# so this never leaks into emitted env or the plan.
_GATE_KEY = "_gates"

# Which gated domains each CLI command actually reads. Only report a gate decision where
# the value it produces is consumed: `validate-env`/`test-cmds` run on a node whose python
# the plan already fixed, so matrix chatter there describes a matrix nobody reads. Commands
# absent from this map report nothing. Resolution and its `indeterminate` bookkeeping stay
# unconditional, so scoping the narration never loosens validate-config.
GATE_REPORT_DOMAINS: Dict[str, tuple] = {
    "plan": ("python_versions", "abi3"),
    "validate-config": ("python_versions", "abi3"),
    "wheel-env": ("python_versions", "abi3"),
    "build-env": ("abi3",),
}


def _is_commit_ancestor(commit_sha: str, project_root: Optional[str] = None) -> Optional[bool]:
    """Returns True if commit_sha is an ancestor of HEAD in the SDK git repo,
    False if not an ancestor, or None if commit_sha does not exist in the local git repository.
    """
    cwd = project_root or os.environ.get("CBCI_PROJECT_ROOT") or os.getcwd()
    try:
        has_commit = subprocess.run(
            ["git", "cat-file", "-e", f"{commit_sha}^{{commit}}"],
            cwd=cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if not has_commit:
            return None

        res = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit_sha, "HEAD"],
            cwd=cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return res.returncode == 0
    except Exception:
        return None


def _eval_version_entry(entry: Union[str, Dict[str, Any]], key_name: str, project_root: Optional[str] = None,
                        gates: Optional[Dict[str, Any]] = None, report: bool = True) -> Optional[str]:
    """Evaluate a version entry (a string, or a dict with min_commit/drop_commit).
    Returns the version if active, or None if a commit constraint filtered it out.

    A gate that cannot be evaluated (no git repo at project_root, or the sha is absent from
    a shallow clone) is recorded in `gates['indeterminate']`, which validate_config turns
    into a hard error. Quietly keeping a version that should have been dropped would build
    the wrong matrix with no sign anything went wrong.

    `report` silences only the narration; the verdict and the bookkeeping are unchanged.
    """
    if isinstance(entry, str):
        return entry.strip()
    if not isinstance(entry, dict):
        return None
    version = str(entry.get("version", "")).strip()
    if not version:
        return None

    def _record_indeterminate(kind: str, sha: str) -> None:
        msg = (f"{key_name} '{version}': {kind} '{sha[:7]}' could not be evaluated "
               f"(no git repo, or sha absent, at {project_root or os.getcwd()})")
        if report:
            print(f"[engine] WARNING: {msg}", file=sys.stderr)
        if gates is not None:
            gates.setdefault("indeterminate", []).append({"domain": key_name, "msg": msg})

    min_commit = entry.get("min_commit")
    if min_commit:
        min_commit = str(min_commit).strip()
        is_anc = _is_commit_ancestor(min_commit, project_root)
        if is_anc is None:
            _record_indeterminate("min_commit", min_commit)
        elif is_anc is False:
            if report:
                print(f"[engine] {key_name}: omitting '{version}' (min_commit '{min_commit[:7]}' is not in HEAD history)", file=sys.stderr)
            return None

    drop_commit = entry.get("drop_commit")
    if drop_commit:
        drop_commit = str(drop_commit).strip()
        is_anc = _is_commit_ancestor(drop_commit, project_root)
        if is_anc is None:
            _record_indeterminate("drop_commit", drop_commit)
        elif is_anc is True:
            if report:
                print(f"[engine] {key_name}: omitting '{version}' (drop_commit '{drop_commit[:7]}' is in HEAD history)", file=sys.stderr)
            return None

    return version


def _resolve_commit_gated_versions(cfg: Dict[str, Any], project_root: Optional[str] = None,
                                   report_domains: Optional[Sequence[str]] = None) -> Dict[str, Any]:
    """Resolve commit-gated versions and build options (dict with min_commit/drop_commit) to clean values.

    `report_domains` limits which domains narrate their decisions (None = all of them).
    """
    gates: Dict[str, Any] = cfg.setdefault(_GATE_KEY, {})

    def _reports(domain: str) -> bool:
        return report_domains is None or domain in report_domains

    support = cfg.get("support", {})
    if isinstance(support, dict) and isinstance(support.get("python_versions"), list):
        resolved: List[str] = []
        for item in support["python_versions"]:
            v = _eval_version_entry(item, "python_versions", project_root, gates,
                                    report=_reports("python_versions"))
            if v and v not in resolved:
                resolved.append(v)
        support["python_versions"] = resolved

    build = cfg.get("build", {})
    if isinstance(build, dict) and "abi3" in build:
        abi3_val = build["abi3"]
        if isinstance(abi3_val, dict):
            enabled = bool(abi3_val.get("enabled", True))
            min_commit = abi3_val.get("min_commit")
            drop_commit = abi3_val.get("drop_commit")
            verdict = "enabled" if enabled else "disabled"

            def _gate(kind: str, sha: str, disable_when: bool) -> Optional[bool]:
                """Returns the new `enabled` value, or None to leave it unchanged."""
                is_anc = _is_commit_ancestor(sha, project_root)
                if is_anc is None:
                    msg = (f"build.abi3: {kind} '{sha[:7]}' could not be evaluated "
                           f"(no git repo, or sha absent, at {project_root or os.getcwd()})")
                    if _reports("abi3"):
                        print(f"[engine] WARNING: {msg}", file=sys.stderr)
                    gates.setdefault("indeterminate", []).append({"domain": "abi3", "msg": msg})
                    return None
                if is_anc is disable_when:
                    if _reports("abi3"):
                        print(f"[engine] build.abi3: disabling abi3 ({kind} '{sha[:7]}' "
                              f"{'is' if disable_when else 'is not'} in HEAD history)", file=sys.stderr)
                    return False
                return None

            if min_commit:
                if _gate("min_commit", str(min_commit).strip(), False) is False:
                    enabled, verdict = False, "disabled"
            if drop_commit:
                if _gate("drop_commit", str(drop_commit).strip(), True) is False:
                    enabled, verdict = False, "disabled"

            build["abi3"] = enabled
            gates["abi3"] = verdict
        else:
            gates["abi3"] = "ungated"

    return cfg


def load_config(config_path: Optional[str] = None,
                report_domains: Optional[Sequence[str]] = None) -> Config:
    """Load, merge, and validate ci-config.yaml.

    `report_domains` scopes commit-gate narration to the domains the caller consumes
    (None = narrate everything; the CLI passes GATE_REPORT_DOMAINS[cmd]).
    """
    path = (
        config_path
        or os.environ.get("CBCI_CONFIG_FILE")
        or os.path.join(os.path.dirname(os.path.abspath(__file__)), CONFIG_FILENAME)
    )
    cfg = _load_yaml(path)
    # Order is load-bearing. The override merges FIRST so a gating dict supplied through
    # CBCI_CONFIG_OVERRIDE is actually resolved (an unresolved dict is truthy, which reads as
    # abi3=on). Gating runs SECOND so promoted vars, which validate against the support
    # matrix, see plain version strings. Promoted vars run LAST: they outrank both.
    cfg = _apply_config_override(cfg)
    cfg = _resolve_commit_gated_versions(cfg, report_domains=report_domains)
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

# Per-project package facts for validate/test:
#   import   top-level import package the smoke imports
#   dist     pip distribution name (find-links / index install target)
#   metadata exposes `get_metadata(detailed=True)`; PYCBC + columnar do, analytics does not
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
    """CBCI_VERBOSE_MAKEFILE (env) wins over ci-config build.verbose_makefile, so a single
    debug run can turn on CMake/compiler echo without editing the committed config."""
    env = os.environ.get("CBCI_VERBOSE_MAKEFILE")
    if env is not None:
        return _as_bool(env)
    return bool(cfg.raw.get("build", {}).get("verbose_makefile", False))


# SDK log levels (PYCBC_LOG_LEVEL / the couchbase C++ core, which owns 'trace').
_VALID_TEST_LOG_LEVELS = ("trace", "debug", "info", "warning", "error", "critical")


def _resolve_test_log_level(cfg: Config) -> str:
    """SDK log level for the test stage. CBCI_TEST_LOG_LEVEL (env) wins over ci-config
    test.pytest.log_level; empty/unset = off. Validated here so a typo fails the plan fast
    rather than surfacing ~40 min later as a mid-suite crash."""
    env = os.environ.get("CBCI_TEST_LOG_LEVEL")
    raw = env if env is not None else cfg.raw.get("test", {}).get("pytest", {}).get("log_level", "")
    level = (raw or "").strip().lower()
    if level and level not in _VALID_TEST_LOG_LEVELS:
        print(f"ERROR: invalid test log level: {raw!r} "
              f"(expected one of: {', '.join(_VALID_TEST_LOG_LEVELS)})", file=sys.stderr)
        sys.exit(1)
    return level


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
    """Facts tasks.sh needs to drive `validate`. release-verify reuses the stage unchanged,
    pointed at CBCI_PACKAGING_INDEX instead of a local artifact.

    Resolved in the ORCHESTRATOR venv (which has yaml); the smoke itself runs in a CLEAN
    venv holding only the SDK, so tasks.sh passes these through as env to a dependency-free
    Python snippet. Values are space-free.
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


def _resolve_publish_dry_run(cfg: Config) -> bool:
    """CBCI_PUBLISH_DRY_RUN (env) wins over ci-config publish.publish_dry_run, so a single
    run can twine-check without uploading and without editing the committed config."""
    env = os.environ.get("CBCI_PUBLISH_DRY_RUN")
    if env is not None:
        return _as_bool(env)
    return bool(cfg.raw.get("publish", {}).get("publish_dry_run", False))


def publish_env(cfg: Config) -> Dict[str, str]:
    """Facts tasks.sh needs to drive `publish` (twine check/upload to PyPI/Test PyPI).

    CBCI_PACKAGING_INDEX (PYPI|TEST_PYPI) and CBCI_VERSION are supplied by the adapter
    per-call, the same way validate_env gets its index, so they are NOT emitted here.
    """
    prefix = resolve_project(cfg)
    pkg = PROJECT_PACKAGES[prefix]
    return {
        "CBCI_PUBLISH_PACKAGE": pkg["dist"],
        "CBCI_PUBLISH_DRY_RUN": "true" if _resolve_publish_dry_run(cfg) else "false",
    }


# Per-stage list of build knobs to emit. sdist only needs enough to bake the CPM cache;
# wheel needs the full set.
_STAGE_BUILD_KEYS = {
    "sdist": ("set_cpm_cache", "build_type", "verbose_makefile"),
    "wheel": ("use_openssl", "openssl_version", "build_type", "abi3", "verbose_makefile", "set_cpm_cache"),
}


def build_env(cfg: Config, stage: str) -> Dict[str, str]:
    """Emit `{PREFIX}_*` env that setup.py / CMake read for the given stage.

    Values are space-free so callers can `export $(engine.py build-env <stage>)`.
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
            # {PREFIX}_PY_LIMITED_API is what setup.py reads (PYCBC-1854), and the SDK
            # defaults it to TRUE, so the non-abi3 path REQUIRES an explicit OFF. Left
            # unset, every per-python build unit would emit the same cpXY-abi3 filename
            # and clobber the others at aggregate time. SDKs predating PYCBC-1854 ignore
            # the var, so sending OFF is safe at any commit.
            if build.get("abi3", False):
                out[f"{prefix}_PY_LIMITED_API"] = "ON"
                # Send the floor too, so the Py_LIMITED_API level and the wheel tag come from
                # the same value that chose the build interpreter in wheel_env().
                out[f"{prefix}_PY_LIMITED_API_VERSION"] = abi3_floor(cfg)
            else:
                out[f"{prefix}_PY_LIMITED_API"] = "OFF"
        elif key == "verbose_makefile":
            if _resolve_verbose_makefile(cfg):
                out[f"{prefix}_VERBOSE_MAKEFILE"] = "ON"
    return out


# ---------------------------------------------------------------------------
# cibuildwheel selector (CIBW_*). Build-unit dimensions come from the env the vendor
# adapter sets per unit (CBCI_BUILD_PLATFORM/ARCH/LIBC, CBCI_PYTHON_VERSION).
# ---------------------------------------------------------------------------


def _py_tag(version: str) -> str:
    """'3.11' -> 'cp311-*' (a cibuildwheel build selector)."""
    return "cp" + version.replace(".", "") + "-*"


def _min_python(versions: List[str]) -> str:
    return min(versions, key=lambda v: tuple(int(x) for x in v.split(".")))


# Fallback only. The real home is `build.abi3_floor` in ci-config.yaml, alongside the rest
# of the support matrix, so raising the floor is a reviewable config change and a second
# project (PYCBCC) can carry its own.
DEFAULT_ABI3_FLOOR = "3.10"


def abi3_floor(cfg: Config) -> str:
    """The (major.minor) CPython floor for abi3 builds, from `build.abi3_floor`.

    ONE value drives all three things that would otherwise drift apart: the interpreter
    cibuildwheel builds on (CIBW_BUILD), the Py_LIMITED_API level the C extension compiles
    against, and the wheel's cpXY-abi3 tag. The SDK range-checks what we send, so a value
    it cannot honor fails the build rather than producing a wheel tagged for a floor it
    was never compiled against.
    """
    return str(cfg.raw.get("build", {}).get("abi3_floor") or DEFAULT_ABI3_FLOOR)


def _ver_tuple(v: str) -> tuple:
    return tuple(int(x) for x in str(v).split("."))


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

    # CIBW_BUILD: abi3 builds once, ON THE FLOOR, not on min(pyvers). The wheel's tag is the
    # floor, so any other interpreter emits a wheel claiming a floor it was never compiled
    # against, and min(pyvers) can sit below the floor entirely.
    # Non-abi3 builds a single python (per-unit fan-out) or all of them.
    if abi3 and pyvers:
        out["CIBW_BUILD"] = _py_tag(abi3_floor(cfg))
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
# Neutral build plan (no runner labels; see CONVENTIONS.md)
# ---------------------------------------------------------------------------


def build_plan(cfg: Config) -> Dict[str, Any]:
    """Emit the vendor-NEUTRAL plan: ABSTRACT dimensions only, no runner labels or
    container images (the adapter attaches those). See CONVENTIONS.md.

      * build units: abi3=true  -> one unit per (platform, arch, libc, ssl), pythons[]
                     abi3=false -> additionally keyed by python (one per python)
      * validate / test:         per (platform, arch, libc?, python, install_type),
                                 a wide fan-out for parallelism and fast feedback.
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
                # `build_python` is the interpreter the unit is COMPILED with. For abi3 that
                # is the floor, not any member of `pythons`: the wheel claims the floor's
                # stable ABI, and on Windows the host interpreter also picks the import
                # library. Non-abi3 units answer the same question with `python`.
                unit.update({"ssl": ssl, "abi3": True, "pythons": pyvers,
                             "build_python": abi3_floor(cfg), "build_type": build_type})
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
            warnings.append(f"no platforms selected for arch '{arch}'; it will produce no units")

    ssl = str(build.get("ssl", "boringssl")).lower()
    if ssl not in ("boringssl", "openssl"):
        errors.append(f"build.ssl must be boringssl|openssl (got '{ssl}')")
    if ssl == "openssl" and not build.get("openssl_version"):
        warnings.append("build.ssl=openssl but build.openssl_version is unset")

    # --- commit gates ---------------------------------------------------------
    # An unevaluatable gate is fatal, not advisory: it fails by leaving the entry in place,
    # so the run gets a plausible-looking plan built from the wrong matrix. It nearly always
    # means the node resolving the plan has no SDK checkout, so point CBCI_PROJECT_ROOT (or
    # cwd) at a real git tree.
    #
    # The one exemption is an EXPLICIT override, which supersedes its gate and makes the
    # indeterminacy moot. That keeps a pipeline with no SDK checkout legitimate (release-verify
    # installs a PUBLISHED artifact and pins its own matrix) without a bypass flag that a
    # source-building pipeline could inherit by accident.
    gates = cfg.raw.get(_GATE_KEY, {})
    for rec in gates.get("indeterminate", []):
        domain, msg = rec["domain"], rec["msg"]
        if domain == "abi3":
            pinned = gates.get("abi3_override") is not None
        else:  # python_versions
            pinned = bool((os.environ.get("PYTHON_VERSIONS") or "").strip())
        target = warnings if pinned else errors
        suffix = " (superseded by an explicit override)" if pinned else ""
        target.append(f"commit gate could not be evaluated: {msg}{suffix}")

    # ABI3=true against a checkout the gate says predates abi3 support would build the coarse
    # abi3 plan on an SDK that cannot honor it: one wheel per platform, built only on the
    # floor, leaving every other interpreter with nothing.
    if gates.get("abi3_override") is True and gates.get("abi3") == "disabled":
        errors.append(
            "ABI3=true was requested, but build.abi3's commit gate reports this checkout "
            "predates abi3 support in the SDK. Drop the override (or use ABI3=auto) to let "
            "the gate decide.")

    # --- abi3 floor coherence -------------------------------------------------
    if build.get("abi3", False):
        floor = abi3_floor(cfg)
        pyvers = [str(v) for v in support.get("python_versions", [])]
        try:
            floor_t = _ver_tuple(floor)
        except ValueError:
            errors.append(f"build.abi3_floor must be MAJOR.MINOR (got '{floor}')")
        else:
            below = [v for v in pyvers if _ver_tuple(v) < floor_t]
            if below:
                errors.append(
                    f"build.abi3 is on with abi3_floor={floor}, but support.python_versions "
                    f"still carries {below}, which cannot install a cp{floor.replace('.', '')}-abi3 "
                    f"wheel. Raise the floor or drop those versions.")
            elif pyvers and _ver_tuple(_min_python(pyvers)) > floor_t:
                warnings.append(
                    f"build.abi3_floor={floor} is below the lowest supported python "
                    f"({_min_python(pyvers)}), so the wheel advertises a version never tested; "
                    f"consider setting abi3_floor to {_min_python(pyvers)}")
    return errors, warnings


# ---------------------------------------------------------------------------
# Test-setup generation
# ---------------------------------------------------------------------------


# Per-project artifact-isolation test layout. `rename` maps each repo API package to the
# short test-tree dir (couchbase->cb) so that, running from the test tree, there is NO
# `couchbase/` source dir to shadow the INSTALLED package: `import couchbase` resolves to
# the wheel/sdist under test.
PROJECT_TEST_LAYOUT = {
    "PYCBC": {
        "tree": "pycbc_test",
        "rename": {"acouchbase": "acb", "couchbase": "cb", "txcouchbase": "txcb"},
        # Package-init bodies for the renamed test-tree dirs (default: empty). The txcouchbase
        # package installs the Twisted reactor UNCONDITIONALLY at import time (unguarded
        # asyncioreactor.install in txcouchbase/__init__.py), so it must be imported exactly
        # ONCE, at package-init, before any txcb test module loads. Otherwise the first
        # in-test `import txcouchbase` collides with pytest-asyncio's loop mid-collection and
        # every txcb file fails with ReactorAlreadyInstalledError. Keyed by original API name.
        "package_init": {"txcouchbase": "import txcouchbase\n"},
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
    """Remap API package names to the renamed test-tree dirs.

    Only path refs and EQUALITY-comparison string literals are rewritten, NOT every
    `'couchbase'`, so this never clobbers e.g. `import_module('couchbase')`. Longest API
    name first so `couchbase` cannot partial-match inside `acouchbase`.
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

    Missing optional keys are skipped, not KeyError'd.
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
    from PYCBC_* / CBCI_* env with sensible defaults.
    """
    if prefix != "PYCBC":
        raise NotImplementedError(f"test_config.ini for {prefix} is not implemented")

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
    each matched line's version pin."""
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
    """Build the artifact-isolation test tree + generated config. Prints the resolved
    test-tree path as the LAST stdout line so tasks.sh can cd into it.

    Layout (PYCBC): <output>/pycbc_test/{cb,acb,txcb}/tests + /tests + conftest.py +
    pytest.ini, and tests/test_config.ini + requirements-test.txt.

    Built into a TEMP sibling dir and renamed into place only once every step has
    succeeded. `open(path, "w")` truncates its file BEFORE the content argument is
    evaluated, so a crash mid-build (say _load_tomllib's sys.exit in step 4) would leave
    an EMPTY pytest.ini behind. tasks.sh/tasks.ps1 detect a pre-built tree by pytest.ini's
    mere EXISTENCE, so that empty file would be "reused" as valid on every later retry.
    """
    prefix = resolve_project(cfg)
    if prefix not in PROJECT_TEST_LAYOUT:
        print(f"ERROR: test-setup unsupported for project {prefix}", file=sys.stderr)
        sys.exit(1)
    layout = PROJECT_TEST_LAYOUT[prefix]
    root = os.environ.get("CBCI_PROJECT_ROOT") or os.getcwd()
    output_path_abs = os.path.abspath(output_path)
    final_root = os.path.join(output_path_abs, layout["tree"])
    rename = layout["rename"]
    package_init = layout.get("package_init", {})

    test_root = tempfile.mkdtemp(prefix=layout["tree"] + ".tmp-", dir=output_path_abs)
    try:
        # 1. Renamed API test dirs (couchbase/tests -> cb/tests) + package __init__. The init
        # is empty unless the layout specifies a body (see package_init: e.g. txcb must
        # `import txcouchbase` at package-init to install the Twisted reactor exactly once).
        for api, short in rename.items():
            _copy_py_tree(os.path.join(root, api, "tests"),
                          os.path.join(test_root, short, "tests"), only_py=True)
            with open(os.path.join(test_root, short, "__init__.py"), "w") as f:
                f.write(package_init.get(api, ""))

        # 2. Top-level tests/ (shared fixtures/helpers) copied verbatim.
        _copy_py_tree(os.path.join(root, "tests"), os.path.join(test_root, "tests"), only_py=False)

        # 3. conftest.py, with the API package names remapped.
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

        os.rename(test_root, final_root)
    except BaseException:
        # BaseException, not Exception: _load_tomllib()'s failure path is sys.exit(1), which
        # raises SystemExit -- an Exception-only except would miss it and leak the temp dir.
        shutil.rmtree(test_root, ignore_errors=True)
        raise

    print(final_root)


def test_cmds(cfg: Config) -> List[str]:
    """Pytest invocations for the test stage, one per API, from ci-config test.pytest.
    Each line is `<cmd> <opts>` ready to run (cmd carries the `-m '<markers>'`).

    When test logging is on (TEST_LOGGING -> CBCI_TEST_LOG_LEVEL, or ci-config
    test.pytest.log_level), each command is prefixed inline with `{PREFIX}_LOG_LEVEL=<level>`
    (the SDK auto-configures a console logger at that level on import) and given `-s`, so
    pytest doesn't swallow the SDK's own console output on a passing run. The inline env prefix
    survives tasks.sh's `eval` + junit-xml append."""
    level = _resolve_test_log_level(cfg)
    prefix = resolve_project(cfg)

    def _decorate(cmd: str) -> str:
        return f"{prefix}_LOG_LEVEL={level} {cmd} -s" if level else cmd

    override_cmd = os.environ.get("CBCI_TEST_COMMAND")
    override_args = os.environ.get("CBCI_TEST_ARGS") or ""

    if override_cmd:
        opts = override_args
        return [_decorate(f"{override_cmd} {opts}".strip())]

    pytest_cfg = cfg.raw.get("test", {}).get("pytest", {})
    cmds: List[str] = []
    for api in ("acouchbase", "couchbase", "txcouchbase"):
        cmd = pytest_cfg.get(f"{api}_cmd")
        if cmd:
            opts = pytest_cfg.get(f"{api}_opts", "")
            if override_args:
                opts = f"{opts} {override_args}"
            cmds.append(_decorate(f"{cmd} {opts}".strip()))
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
    sub.add_parser("validate-config", help="load + merge + validate config, exit non-zero on error")
    sub.add_parser("project-env", help="emit CBCI_* project facts as KEY=VALUE pairs")
    sub.add_parser("validate-env", help="emit CBCI_VALIDATE_* facts for the validate stage")
    sub.add_parser("publish-env", help="emit CBCI_PUBLISH_* facts for the publish stage")

    p_build_env = sub.add_parser("build-env", help="emit {PREFIX}_* build knobs as KEY=VALUE pairs")
    p_build_env.add_argument("stage", choices=("sdist", "wheel"), help="build stage")

    sub.add_parser("wheel-env", help="emit CIBW_* selector knobs (one KEY=VALUE per line)")

    p_setup = sub.add_parser("test-setup", help="generate the artifact-isolation test tree + config")
    p_setup.add_argument("output_path", help="directory to write the test tree into")

    sub.add_parser("test-cmds", help="emit pytest invocations (one per line)")

    args = parser.parse_args(argv)
    cfg = load_config(args.config, report_domains=GATE_REPORT_DOMAINS.get(args.cmd, ()))

    if args.cmd == "plan":
        _emit(build_plan(cfg))
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
    elif args.cmd == "publish-env":
        _emit_pairs(publish_env(cfg))
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
