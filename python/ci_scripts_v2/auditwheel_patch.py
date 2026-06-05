#!/usr/bin/env python3
"""auditwheel_patch.py — patched auditwheel entrypoint for manylinux repair.

When PYCBC builds against a dynamically-linked OpenSSL (rather than the vendored
BoringSSL), the default auditwheel repair would BUNDLE the OpenSSL .so files into
the wheel, fighting the SDK's intentional dynamic-link design. This monkeypatches
auditwheel's policy whitelist so the OpenSSL libs are treated as allowed system
libraries (not bundled), then defers to the normal auditwheel CLI.

Used as the repair hook under cibuildwheel:
    CIBW_REPAIR_WHEEL_COMMAND="python auditwheel_patch.py repair -w {dest_dir} {wheel} ..."

Ported from the proven prototype (scripts/auditwheel-pycbc). The accompanying
strip + separate-debug-wheel split (objcopy --only-keep-debug / --strip-unneeded /
--add-gnu-debuglink) is orchestrated by tasks.sh as the rest of the repair command;
see PLAN.md §6 "Debug-wheel split under cibuildwheel".

No-op when OpenSSL is not in use (boringssl builds) — safe to wire unconditionally.
"""

from __future__ import annotations

import json
import os
import sys


def _openssl_libs_for(version: str) -> list[str]:
    """Map an OpenSSL version to its soname pair (mirrors gha.sh build_openssl)."""
    if "1.1" in version:
        return ["libssl.so.1.1", "libcrypto.so.1.1"]
    if "3.1" in version:
        return ["libssl.so.3.1", "libcrypto.so.3.1"]
    if "3" in version:
        return ["libssl.so.3", "libcrypto.so.3"]
    # default to 1.1 sonames to match the prototype's fallback
    return ["libssl.so.1.1", "libcrypto.so.1.1"]


def _whitelist_openssl() -> None:
    """Extend every auditwheel policy's lib_whitelist with the OpenSSL sonames.

    Reads PYCBC_USE_OPENSSL / PYCBC_OPENSSL_VERSION (re-exported into the build by
    cibuildwheel's CIBW_ENVIRONMENT — BEFORE_ALL env does not carry into the build).
    """
    use_openssl = os.getenv("PYCBC_USE_OPENSSL", "").lower()
    if use_openssl not in ("true", "1", "y", "yes", "on"):
        return

    version = os.getenv("PYCBC_OPENSSL_VERSION", "")
    openssl_libs = _openssl_libs_for(version)

    from auditwheel.policy import _POLICY_JSON_MAP as POLICY_JSON_MAP

    for key in POLICY_JSON_MAP:
        policy_list = json.loads(POLICY_JSON_MAP[key].read_text())
        save_updates = False
        for policy in policy_list:
            missing = [lib for lib in openssl_libs if lib not in policy["lib_whitelist"]]
            if missing:
                policy["lib_whitelist"].extend(missing)
                save_updates = True
        if policy_list and save_updates:
            POLICY_JSON_MAP[key].write_text(json.dumps(policy_list))


def main() -> int:
    _whitelist_openssl()
    from auditwheel.main import main as auditwheel_main

    return auditwheel_main()


if __name__ == "__main__":
    sys.exit(main())
