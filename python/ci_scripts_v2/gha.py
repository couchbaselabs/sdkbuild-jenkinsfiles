#!/usr/bin/env python3
"""gha.py - the GitHub Actions ADAPTER for the Couchbase Python SDK CI-core.

The GHA counterpart of jenkins.py. Translates the vendor-NEUTRAL facts from `engine.py`
into the shapes a workflow can consume, attaching the ONE deployment-specific thing the
core deliberately does not know: runner images and container tags (CONVENTIONS.md). The
neutral core (engine.py / tasks.sh) never carries a runner label; this file is the sole
place they live for GitHub Actions.

Why an adapter at all, when tasks.sh is already vendor-neutral and runs fine on a GHA
runner: `runs-on` and `strategy.matrix` are evaluated by GitHub BEFORE any step runs, so
the fan-out has to arrive as data. A workflow cannot call into Python from an expression.
So the `setup` job runs this once, publishes one JSON blob as a job output, and every
later job reads its own slice out of it:

    stage_matrices=$(python3 gha.py matrices)     # -> $GITHUB_OUTPUT
    ...
    matrix: ${{ fromJson(needs.setup.outputs.stage_matrices).test_unit.linux }}

Everything that is WORK rather than plan goes to `./tasks.sh <stage>` exactly as it does
from the Jenkins groovy. This file shapes jobs; it never runs a build or a test.

SCOPE: pure-Python projects (PYCBAC / Operational Insights) only, which is the whole of
what runs on GHA today. The `build_wheel` and `validate_wheel` stages the legacy pygha.py
emitted for the compiled clients are NOT ported: those clients build on Jenkins, so the
code would ship unexercised. `matrices` says so rather than emitting a half-matrix, and
the two stages are a bounded addition for whoever moves a compiled client to GHA.

CLI:
    python3 gha.py matrices                 # emit the stage_matrices JSON the workflows consume
    python3 gha.py publish-config           # emit the publish plan (JSON) the publish workflow gates on
    python3 gha.py validate-input <name>    # gate the workflow_dispatch inputs for one workflow
    python3 gha.py cbdino-config <dir>      # write <dir>/cluster_def.yaml for cbdinocluster
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine  # noqa: E402  (the neutral core; this adapter builds on it)

# ---------------------------------------------------------------------------
# Runner images: the ONE deployment-specific thing (CONVENTIONS.md)
# ---------------------------------------------------------------------------

# Abstract (platform, arch) -> GitHub-hosted runner image. The abstract keys come from the
# neutral config's `support.platforms`; the values are GitHub's own labels and exist ONLY
# here, the way _JENKINS_LABELS exists only in jenkins.py.
_GHA_RUNNERS = {
    ("linux",   "x86_64"): "ubuntu-24.04",
    ("linux",   "arm64"):  "ubuntu-24.04-arm",
    ("macos",   "x86_64"): "macos-15-intel",
    ("macos",   "arm64"):  "macos-15",
    ("windows", "x86_64"): "windows-2022",
}

# Consumer overrides. A GHA workflow needs at least ONE runner label statically in its own
# `env:` block, because the job that runs THIS script needs a runner before it can be told
# which runner to use, and `${{ env.* }}` is the only thing available that early. Rather
# than let that copy silently diverge from the table above, the env var WINS wherever it is
# set: the value in the consumer's workflow is the one that runs, and the table is the
# default for a consumer that sets nothing.
_RUNNER_ENV = {
    ("linux",   "x86_64"): "CBCI_DEFAULT_LINUX_X86_64_PLATFORM",
    ("linux",   "arm64"):  "CBCI_DEFAULT_LINUX_ARM64_PLATFORM",
    ("macos",   "x86_64"): "CBCI_DEFAULT_MACOS_X86_64_PLATFORM",
    ("macos",   "arm64"):  "CBCI_DEFAULT_MACOS_ARM64_PLATFORM",
    ("windows", "x86_64"): "CBCI_DEFAULT_WINDOWS_PLATFORM",
}

# alpine has no runner of its own: the job runs on the default linux runner and the tests
# execute inside a `python:<version>-<container>` image (docker-run-action). So the alpine
# matrix carries no `os` key, and the workflow supplies the container tag from its own env.
_GHA_CONTAINER_ENV = {"linux": "CBCI_DEFAULT_LINUX_CONTAINER", "alpine": "CBCI_DEFAULT_ALPINE_CONTAINER"}
_GHA_CONTAINERS = {"linux": "slim-bookworm", "alpine": "alpine"}

# cbdinocluster provisions containers on the runner's own docker, so the integration job is
# pinned to one linux/x86_64 cell rather than fanning out: coverage there comes from the
# server-version matrix, not from build-platform breadth (same reasoning as
# _JENKINS_INTEGRATION_LABEL). `ubuntu-latest` rather than the pinned default linux runner
# is carried over verbatim from pygha.py, so the cluster comes up on the image it always has.
_GHA_CBDINO_RUNNER = "ubuntu-latest"
_GHA_CBDINO_ARCH = "x86_64"

# Windows reports its arch the way the Python tooling on that runner does. Carried over
# from pygha.py, where `matrix.arch` is 'AMD64' and not 'x86_64', so a workflow expression
# comparing against it keeps working.
_GHA_WINDOWS_ARCH = "AMD64"

# ---------------------------------------------------------------------------
# Runner / container resolution
# ---------------------------------------------------------------------------


def _runner(platform: str, arch: str) -> str:
    """The runner image for one abstract cell: consumer env override, else the table.

    An unmapped (platform, arch) is FATAL rather than skipped. The config's support matrix
    is the statement of what this SDK claims to support, so a cell with no runner means the
    fan-out would silently omit a platform the SDK says it supports, which is the exact
    failure the neutral core's promoted-var handling also refuses to make quiet.
    """
    key = (platform, arch)
    override = os.environ.get(_RUNNER_ENV.get(key, ""))
    if override:
        return override
    label = _GHA_RUNNERS.get(key)
    if not label:
        print(f"ERROR: no GitHub runner mapped for platform={platform} arch={arch}. Either "
              f"drop it from the ci-config support matrix or add it to _GHA_RUNNERS in "
              f"gha.py (and set {_RUNNER_ENV.get(key, 'the matching CBCI_DEFAULT_* var')} "
              f"if the workflow also needs it in an expression).", file=sys.stderr)
        sys.exit(1)
    return label


def _container(platform: str) -> str:
    return os.environ.get(_GHA_CONTAINER_ENV.get(platform, "")) or _GHA_CONTAINERS.get(platform, "")


def _check_default_python(cfg: engine.Config) -> str:
    """The default interpreter, cross-checked against the workflow's own copy.

    `support.default_python` in ci-config is the v2 source of truth, but a GHA workflow also
    needs the value in an expression (`setup-python` on its single-node jobs) and so keeps
    CBCI_DEFAULT_PYTHON in its `env:` block. Two copies of one fact is exactly how the
    legacy CBCI_SUPPORTED_* vars went stale, and a mismatch here is silent: the jobs that
    read config fan out over one set of interpreters while the single-node jobs install
    another. GHA's expression syntax cannot call Python, so the duplication cannot be
    removed; making a mismatch FATAL is what makes it safe.
    """
    default = str((cfg.raw.get("support", {}) or {}).get("default_python") or "")
    declared = os.environ.get("CBCI_DEFAULT_PYTHON")
    if declared and default and declared != default:
        print(f"ERROR: CBCI_DEFAULT_PYTHON={declared} (workflow env) disagrees with "
              f"support.default_python={default} (ci-config). These must match: the "
              f"workflow uses its copy for setup-python on single-node jobs and the core "
              f"uses config everywhere else.", file=sys.stderr)
        sys.exit(1)
    return default or declared or ""


# ---------------------------------------------------------------------------
# Matrix axes
# ---------------------------------------------------------------------------


def _support(cfg: engine.Config) -> tuple:
    support = cfg.raw.get("support", {}) or {}
    return (
        [str(v) for v in support.get("python_versions", [])],
        [str(a) for a in support.get("architectures", [])],
        support.get("platforms", {}) or {},
    )


def _arches_supporting(platform: str, arches: List[str], plats_by_arch: Dict[str, Any]) -> List[str]:
    """The arches whose platform list includes `platform`, in the config's own order."""
    return [a for a in arches if platform in [str(p) for p in (plats_by_arch.get(a) or [])]]


def _os_arch_matrix(platform: str, arches: List[str], pyvers: List[str],
                    arch_label: Optional[str] = None) -> Dict[str, Any]:
    """A GHA matrix for one platform: parallel os[] / arch[] lists plus python-version[].

    GHA takes the CROSS product of every axis, so a 2-arch platform yields runner/arch pairs
    that do not exist (the arm64 runner with arch x86_64). `exclude` removes them, leaving
    exactly one job per (arch, python). This is why the axes are lists rather than an
    `include` list of whole cells: the workflow's own steps read `matrix.os`, `matrix.arch`
    and `matrix.python-version` directly, and that contract predates v2.
    """
    if not arches:
        return {}
    pairs = [(_runner(platform, a), arch_label or a) for a in arches]
    oses = list(dict.fromkeys(p[0] for p in pairs))
    arch_list = [p[1] for p in pairs]
    matrix: Dict[str, Any] = {"os": oses, "arch": arch_list, "python-version": pyvers}
    valid = set(pairs)
    exclude = [{"os": o, "arch": a} for o in oses for a in arch_list if (o, a) not in valid]
    if exclude:
        matrix["exclude"] = exclude
    return matrix


def _alpine_matrix(arches: List[str], pyvers: List[str]) -> Dict[str, Any]:
    """alpine's matrix, which carries NO `os`: the job runs on the default linux runner and
    the tests run inside a musl container, so the axes are just arch and python."""
    if not arches:
        return {}
    return {"linux-type": ["musllinux"], "arch": list(arches), "python-version": pyvers}


# ---------------------------------------------------------------------------
# Stage matrices
# ---------------------------------------------------------------------------


def _platform_group(cfg: engine.Config, platform: str) -> Dict[str, Any]:
    pyvers, arches, plats_by_arch = _support(cfg)
    supported = _arches_supporting(platform, arches, plats_by_arch)
    if platform == "alpine":
        return _alpine_matrix(supported, pyvers)
    if platform == "windows":
        return _os_arch_matrix(platform, supported, pyvers, arch_label=_GHA_WINDOWS_ARCH)
    return _os_arch_matrix(platform, supported, pyvers)


def _base_matrix(cfg: engine.Config) -> Dict[str, Any]:
    """The four platform groups plus their has_* flags.

    The flags exist because a GHA `if:` cannot ask whether a matrix is empty: an empty
    matrix is a workflow-level ERROR, not a skipped job, so each job gates itself on
    `has_<platform>` before its `strategy.matrix` is ever evaluated.
    """
    out: Dict[str, Any] = {}
    for platform in ("linux", "alpine", "macos", "windows"):
        group = _platform_group(cfg, platform)
        if group:
            out[platform] = group
        out[f"has_{platform}"] = bool(group)
    return out


def _apis_and_install_types(cfg: engine.Config) -> Dict[str, Any]:
    """Booleans, not lists: each API and install type is a separate `if:`-gated STEP inside
    one job rather than another matrix axis, which keeps the job count down (the legacy
    pygha.py carries the same note where it decided this)."""
    test = cfg.raw.get("test", {}) or {}
    apis = [str(a) for a in (test.get("apis") or [])]
    install_types = [str(t) for t in (test.get("install_types") or ["sdist", "wheel"])]
    return {
        "test_acouchbase_api": "acouchbase" in apis,
        "test_couchbase_api": "couchbase" in apis,
        "test_txcouchbase_api": "txcouchbase" in apis,
        "test_sdist_install": "sdist" in install_types,
        "test_wheel_install": "wheel" in install_types,
    }


def _pytest_block(cfg: engine.Config, stage: str, flags: Dict[str, Any]) -> Dict[str, str]:
    """The pytest cmd/opts for the APIs this run actually tests, from the neutral core's
    stage-aware resolver (engine.pytest_config), so the marker split between unit and
    integration comes from config and not from string surgery here."""
    resolved = engine.pytest_config(cfg, stage)
    block: Dict[str, str] = {}
    for api in ("acouchbase", "couchbase", "txcouchbase"):
        if not flags.get(f"test_{api}_api"):
            continue
        cmd = resolved.get(f"{api}_cmd")
        if cmd:
            block[f"{api}_cmd"] = cmd
            block[f"{api}_opts"] = resolved.get(f"{api}_opts", "")
    return block


def _install_cmd() -> Optional[str]:
    """The pip install flags for a verify-release run, which installs the PUBLISHED package
    from an index by name instead of from a local artifact. Absent outside that workflow."""
    index = (os.environ.get("CBCI_PACKAGING_INDEX") or "").upper()
    if index == "TEST_PYPI":
        return "install -i https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple"
    if index == "PYPI":
        return "install"
    return None


def _cbdino_dict(cfg: engine.Config) -> Dict[str, Any]:
    integration = (cfg.raw.get("test", {}) or {}).get("integration", {}) or {}
    cbdino = integration.get("cbdino", {}) or {}
    out: Dict[str, Any] = {
        "num_nodes": integration.get("num_nodes", 3),
        "version": str(cbdino.get("version") or ""),
    }
    for key in ("image", "use_load_balancer", "use_dns", "use_dino_certs"):
        if cbdino.get(key) is not None:
            out[key] = cbdino[key]
    return out


def _test_config_dict(cfg: engine.Config) -> Dict[str, str]:
    """The {PREFIX}_* env the integration job exports before re-rendering test_config.ini.

    Only the settings a workflow can supply from OUTSIDE the cluster; the endpoint itself
    arrives later as CBDC_CONNSTR, which engine's ini renderer reads directly. Empty when
    the run has no usable credentials, which is what `skip_integration` then reports.
    """
    prefix = engine.resolve_project(cfg)
    integration = (cfg.raw.get("test", {}) or {}).get("integration", {}) or {}
    scheme = os.environ.get(f"{prefix}_SCHEME", "https")
    username = os.environ.get(f"{prefix}_USERNAME", "Administrator")
    password = os.environ.get(f"{prefix}_PASSWORD", "password")
    host = os.environ.get(f"{prefix}_HOST")
    if not (scheme and username and password):
        return {}
    out = {
        f"{prefix}_SCHEME": scheme,
        f"{prefix}_USERNAME": username,
        f"{prefix}_PASSWORD": password,
    }
    if host:
        out[f"{prefix}_HOST"] = host
    port = os.environ.get(f"{prefix}_PORT")
    if port:
        out[f"{prefix}_PORT"] = port
    fqdn = os.environ.get(f"{prefix}_FQDN") or _sample_fqdn(integration)
    if fqdn:
        out[f"{prefix}_FQDN"] = fqdn
    return out


def _sample_fqdn(integration: Dict[str, Any]) -> Optional[str]:
    """The default collection the integration suite queries, derived from the sample bucket
    the cluster spec loads. `travel-sample` ships an `inventory.airline` collection, which is
    what the legacy workflow hard-coded as PYCBAC_FQDN."""
    samples = [str(b) for b in (integration.get("sample_buckets") or [])]
    return "travel-sample.inventory.airline" if "travel-sample" in samples else None


def _test_unit(cfg: engine.Config) -> Dict[str, Any]:
    matrix = _base_matrix(cfg)
    flags = _apis_and_install_types(cfg)
    matrix.update(flags)
    pytest_block = _pytest_block(cfg, "unit", flags)
    if pytest_block:
        matrix["pytest"] = pytest_block
    install_cmd = _install_cmd()
    if install_cmd is not None:
        matrix["install_cmd"] = install_cmd
    return matrix


def _test_integration(cfg: engine.Config) -> Dict[str, Any]:
    test = cfg.raw.get("test", {}) or {}
    matrix = _base_matrix(cfg)
    flags = _apis_and_install_types(cfg)
    matrix.update(flags)

    skip_cbdino = bool(test.get("skip_cbdino", False))
    skip_integration = bool(test.get("skip_integration", False))

    # The cbdino cell is pinned rather than derived: see _GHA_CBDINO_RUNNER. It reuses the
    # linux group's python axis so the cluster is exercised on every supported interpreter.
    linux = matrix.get("linux") or {}
    has_cbdino = bool(linux) and not skip_cbdino
    if has_cbdino:
        matrix["linux_cbdino"] = {
            "os": [_GHA_CBDINO_RUNNER],
            "arch": [_GHA_CBDINO_ARCH],
            "python-version": list(linux.get("python-version") or []),
        }
        matrix["cbdino_config"] = _cbdino_dict(cfg)
    matrix["has_linux_cbdino"] = has_cbdino
    matrix["skip_cbdino"] = skip_cbdino

    test_config = {} if skip_integration else _test_config_dict(cfg)
    if not skip_integration and not test_config:
        # Reported, not inferred later: without credentials the integration jobs would start
        # and then fail at connect time, which reads as a product failure rather than a
        # missing input.
        print("WARNING: skip_integration is false but the run has no usable cluster "
              "credentials; skipping integration.", file=sys.stderr)
        skip_integration = True
    matrix["skip_integration"] = skip_integration
    if test_config:
        matrix["test_config"] = test_config

    pytest_block = _pytest_block(cfg, "integration", flags)
    if pytest_block:
        matrix["pytest"] = pytest_block
    install_cmd = _install_cmd()
    if install_cmd is not None:
        matrix["install_cmd"] = install_cmd
    return matrix


def _reject_compiled(cfg: engine.Config) -> None:
    """Refuse a compiled project with a sentence instead of a half-matrix.

    The mirror of jenkins.py's `_reject_pure_python`. The stages this adapter emits are the
    ones a pure-Python project needs (one universal wheel, then prove it installs and passes
    everywhere); a compiled client additionally needs `build_wheel` and `validate_wheel`,
    with cibuildwheel selectors and manylinux/musllinux images. Those clients build on
    Jenkins today, so writing that path here would ship code no pipeline runs.
    """
    project = engine.resolve_project(cfg)
    if project in engine.PURE_PYTHON_PROJECTS:
        return
    raise SystemExit(
        f"gha.py: project {project} is not pure-Python. This adapter emits the test_unit and "
        "test_integration stages only; a compiled client also needs build_wheel and "
        "validate_wheel (cibuildwheel selectors, manylinux/musllinux images), which are "
        "deliberately not implemented here because the compiled clients build on Jenkins. "
        "Add them alongside a pipeline that exercises them."
    )


def matrices(config_path: Optional[str] = None) -> Dict[str, Any]:
    """The `stage_matrices` blob the workflows consume, one key per stage."""
    cfg = engine.load_config(config_path)
    _reject_compiled(cfg)
    _check_default_python(cfg)
    return {"test_unit": _test_unit(cfg), "test_integration": _test_integration(cfg)}


# ---------------------------------------------------------------------------
# Publish plan
# ---------------------------------------------------------------------------


def publish_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Which publish jobs this run should execute, as the `{"publish_config": {...}}` blob
    the publish workflow reads at `fromJson(...).publish_config.<key>`.

    Adapter work, not `tasks.sh publish`: this decides WHETHER each destination runs, and
    the decision gates GHA jobs by `if:` before any step of theirs starts. `tasks.sh publish`
    is the thing that actually uploads, and it runs later, inside the jobs this enables.

    The four booleans come from the merged ci-config `publish` block (so CBCI_CONFIG_OVERRIDE
    reaches them like anything else); dry-run additionally honours CBCI_PUBLISH_DRY_RUN,
    resolved by the core. The last two are pure GHA plumbing:

      set_git_tag   the version to tag, empty when this is not a release
      tests_run_id  a previous tests run to reuse instead of re-running the suite
    """
    cfg = engine.load_config(config_path)
    pub = cfg.raw.get("publish", {}) or {}
    # Via publish_env rather than the raw key, so dry-run has exactly one resolution path
    # (config, then CBCI_PUBLISH_DRY_RUN) shared with the stage that performs the upload.
    dry_run = engine.publish_env(cfg).get("CBCI_PUBLISH_DRY_RUN") == "true"
    return {
        "publish_config": {
            "publish_pypi": bool(pub.get("publish_pypi", True)),
            "publish_test_pypi": bool(pub.get("publish_test_pypi", True)),
            "publish_api_docs": bool(pub.get("publish_api_docs", True)),
            "publish_dry_run": dry_run,
            # Empty string, not null: the workflow compares with `!= ''` in an expression,
            # where a JSON null renders as the literal "null" and reads as set.
            "set_git_tag": os.environ.get("CBCI_VERSION") or "",
            "tests_run_id": os.environ.get("CBCI_TESTS_RUN_ID") or "",
        }
    }


# ---------------------------------------------------------------------------
# workflow_dispatch input gating
# ---------------------------------------------------------------------------

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc|dev|post)[0-9]+)?$")
_PACKAGING_INDEXES = ("PYPI", "TEST_PYPI")

# Which workflows this project's inputs are gated for, per project. Keyed by the workflow's
# `name:`, which is what `${{ github.workflow }}` expands to. Ported from the legacy
# gha.sh validate_<project>_input, and per-project because the names differ (PYCBC's build
# workflow is `build_wheels`, PYCBAC's is `tests`).
_RELEASE_WORKFLOWS = {"PYCBAC": ("tests", "publish"), "PYCBC": ("build_wheels", "publish")}
_VERIFY_WORKFLOW = "verify_release"


def _fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def _require_sha() -> None:
    sha = os.environ.get("CBCI_SHA") or ""
    if not sha:
        _fail("must provide a SHA (CBCI_SHA)")
    if not _SHA_RE.match(sha):
        _fail(f"invalid SHA: {sha} (want 40 lowercase hex characters)")


def _require_version() -> None:
    version = os.environ.get("CBCI_VERSION") or ""
    if not version:
        _fail("must provide a version (CBCI_VERSION)")
    if not _VERSION_RE.match(version):
        _fail(f"invalid version: {version}")


def validate_input(workflow: str, config_path: Optional[str] = None) -> None:
    """Gate one workflow's `workflow_dispatch` inputs before anything else runs.

    This is adapter work, not core work: the inputs are GHA's own (`github.workflow`,
    workflow_dispatch fields), and the rules are about the SHAPE of a dispatch rather than
    about the build. `engine.py validate-config` gates the config; this gates the request.
    """
    cfg = engine.load_config(config_path)
    project = engine.resolve_project(cfg)
    release_workflows = _RELEASE_WORKFLOWS.get(project)
    if release_workflows is None:
        _fail(f"no workflow-input rules for project {project}; add them to _RELEASE_WORKFLOWS "
              f"in gha.py")

    if workflow in release_workflows:
        # A non-release run takes whatever HEAD it was triggered on: nothing to check. A
        # release run publishes under an exact version from an exact commit, so both are
        # required and both are format-checked.
        if (os.environ.get("CBCI_IS_RELEASE") or "").lower() == "true":
            _require_sha()
            _require_version()
    elif workflow == _VERIFY_WORKFLOW:
        _require_version()
        _require_sha()
        index = os.environ.get("CBCI_PACKAGING_INDEX") or ""
        if not index:
            _fail("must provide a packaging index (CBCI_PACKAGING_INDEX)")
        if index not in _PACKAGING_INDEXES:
            _fail(f"packaging index must be one of {list(_PACKAGING_INDEXES)}; got: {index}")
    else:
        known = list(release_workflows) + [_VERIFY_WORKFLOW]
        _fail(f"invalid workflow for project {project}: {workflow} (known: {known})")

    print(f"input OK: project={project} workflow={workflow} "
          f"is_release={os.environ.get('CBCI_IS_RELEASE') or 'false'}")


# ---------------------------------------------------------------------------
# cbdinocluster cluster definition
# ---------------------------------------------------------------------------


def cbdino_config_yaml(cfg: engine.Config) -> str:
    """Render the cbdinocluster `--def-file` for this project's integration cluster.

    cbdinocluster is GHA's realization of the neutral `test.integration` spec (Jenkins
    realizes the same spec with cbdyncluster), so its on-disk format belongs here and not
    in the core. `columnar: true` selects the analytics/columnar server topology and is the
    server-side flag name, which the product rename does not touch.
    """
    integration = (cfg.raw.get("test", {}) or {}).get("integration", {}) or {}
    cbdino = integration.get("cbdino", {}) or {}
    is_analytics = engine.resolve_project(cfg) == "PYCBAC"

    lines: List[str] = []
    if is_analytics:
        lines.append("columnar: true")
    lines.append("nodes:")
    lines.append(f"  - count: {integration.get('num_nodes', 3)}")
    lines.append(f"    version: {cbdino.get('version', '')}")
    if cbdino.get("image") is not None:
        lines.append("    docker:")
        lines.append(f"      image: {cbdino['image']}")
    if is_analytics:
        lines.append("docker:")
        for key, name in (("use_load_balancer", "load-balancer"),
                          ("use_dns", "use-dns"),
                          ("use_dino_certs", "use-dino-certs")):
            if cbdino.get(key) is not None:
                lines.append(f"  {name}: {'true' if cbdino[key] else 'false'}")
    lines.append("")
    return "\n".join(lines)


def write_cbdino_config(output_dir: str, config_path: Optional[str] = None) -> str:
    cfg = engine.load_config(config_path)
    if not os.path.isdir(output_dir):
        _fail(f"not a directory: {output_dir}")
    target = os.path.join(os.path.abspath(output_dir), "cluster_def.yaml")
    with open(target, "w") as f:
        f.write(cbdino_config_yaml(cfg))
    return target


# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="gha.py",
                                     description="GitHub Actions adapter for the Couchbase Python SDK CI core")
    parser.add_argument("--config", help="path to ci-config.yaml (default: alongside engine.py)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("matrices", help="emit the stage_matrices JSON the workflows consume")
    sub.add_parser("publish-config", help="emit the publish plan (JSON) the publish workflow gates on")

    p_validate = sub.add_parser("validate-input", help="gate one workflow's dispatch inputs")
    p_validate.add_argument("workflow", help="the workflow name (${{ github.workflow }})")

    p_cbdino = sub.add_parser("cbdino-config", help="write cluster_def.yaml for cbdinocluster")
    p_cbdino.add_argument("output_dir", help="directory to write cluster_def.yaml into")

    args = parser.parse_args(argv)

    if args.cmd == "matrices":
        print(json.dumps(matrices(args.config)))
    elif args.cmd == "publish-config":
        print(json.dumps(publish_config(args.config)))
    elif args.cmd == "validate-input":
        validate_input(args.workflow, args.config)
    elif args.cmd == "cbdino-config":
        print(write_cbdino_config(args.output_dir, args.config))
    else:  # pragma: no cover - argparse enforces
        parser.error(f"unknown command: {args.cmd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
