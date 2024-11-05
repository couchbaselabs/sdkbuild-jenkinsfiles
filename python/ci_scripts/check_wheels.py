#!/usr/bin/env python

#  Copyright 2016-2024. Couchbase, Inc.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

import sys
from dataclasses import dataclass
from os import path
from pathlib import Path
from typing import List, Tuple

# 3.8 EOL 2024.10.07
SUPPORTED_PYTHON_VERSIONS = ['3.9', '3.10', '3.11', '3.12', '3.13']
SUPPORTED_PLATFORMS = {
    'manylinux2014': ['x86_64', 'arm64'],
    'musllinux_1_1': ['x86_64'],
    'macosx': ['x86_64', 'arm64'],
    'win': ['x86_64'],
}


@dataclass
class WheelMetadata:
    platform: str
    arch: str
    python_version: str
    cpython_version: str
    found_wheel: bool

    def wheel_match(self, wheel: str) -> bool:
        return (self.platform in wheel
                and self.arch in wheel
                and self.cpython_version in wheel)


def cpython_version_from_python_version(version: str) -> str:
    if version.startswith('3.9'):
        return 'cp39'
    elif version.startswith('3.10'):
        return 'cp310'
    elif version.startswith('3.11'):
        return 'cp311'
    elif version.startswith('3.12'):
        return 'cp312'
    elif version.startswith('3.13'):
        return 'cp313'

    raise SystemExit(f'Unsupported Python version: {version}.')

def parse_python_versions(versions: str) -> List[str]:

    version_list = []
    for ver in versions.split(','):
        if ver not in SUPPORTED_PYTHON_VERSIONS:
            raise SystemExit(f'Unsupported Python version: {ver}.')

        version_list.append(f'{ver}')

    return version_list


def parse_platforms(arch: str, platforms: str) -> List[str]:
    platform_list = []
    for plat in platforms.split(','):
        if plat not in SUPPORTED_PLATFORMS.keys():
            raise SystemExit(f'Unsupported platform: {plat}.')
        if arch not in SUPPORTED_PLATFORMS[plat]:
            raise SystemExit(f'Unsupported platform ({plat}) architecture: {arch}.')

        platform_list.append(plat)

    return platform_list


def validate_wheels(wheel_dir: Path, expected_wheels: List[WheelMetadata]) -> None:
    for child in wheel_dir.iterdir():
        if child.is_file() and child.suffix == '.whl':
            match = next((whl for whl in expected_wheels if whl.wheel_match(child.name)), None)
            if match is not None:
                match.found_wheel = True

    missing_wheels = [w for w in expected_wheels if w.found_wheel is False]
    if len(missing_wheels) > 0:
        wheels = '\n    '.join(map(lambda w: f"{w.platform}-{w.arch}-{w.cpython_version}", missing_wheels))
        print(f'Missing {len(missing_wheels)} wheels!\nExpected wheels that are missing:\n    {wheels}')
        raise SystemExit('Failed due to missing wheels')


def get_expected_wheels(python_versions: List[str],
                        x86_64_platforms: List[str],
                        arm64_platforms: List[str]) -> List[WheelMetadata]:
    expected_wheels = []
    for pv in python_versions:
        cpython = cpython_version_from_python_version(pv)
        for plat in x86_64_platforms:
            if plat == 'macosx':
                expected_wheels.append(WheelMetadata(f'{plat}_10_15', 'x86_64', pv, f'{cpython}-{cpython}', False))
            elif plat == 'win':
                expected_wheels.append(WheelMetadata(plat, 'amd64', pv, f'{cpython}-{cpython}', False))
            elif 'manylinux' in plat:
                expected_wheels.append(WheelMetadata(f'{plat}_x86_64', 'x86_64', pv, f'{cpython}-{cpython}', False))
            else:
                expected_wheels.append(WheelMetadata(plat, 'x86_64', pv, f'{cpython}-{cpython}', False))
        for plat in arm64_platforms:
            if plat == 'macosx':
                expected_wheels.append(WheelMetadata(f'{plat}_11_0', 'arm64', pv, f'{cpython}-{cpython}', False))
            elif 'manylinux' in plat:
                expected_wheels.append(WheelMetadata(f'{plat}_aarch64', 'aarch64', pv, f'{cpython}-{cpython}', False))
            else:
                expected_wheels.append(WheelMetadata(plat, 'arm64', pv, f'{cpython}-{cpython}', False))

    return expected_wheels


def validate_input() -> Tuple[List[str], List[str], List[str], Path]:
    if len(sys.argv) < 4:
        raise SystemExit('Expected at least -versions=<>, -x86_64=<> and -arm=<> options.')
    if len(sys.argv) > 5:
        raise SystemExit('Expected only -versions=<>, -x86_64=<>, arm=<> and -d=<> options.')

    opt_mapping = {}
    for idx, arg in enumerate(sys.argv[1:]):
        if arg.startswith('-version'):
            opt_mapping['version'] = idx + 1
        elif arg.startswith('-x86_64'):
            opt_mapping['x86_64'] = idx + 1
        elif arg.startswith('-arm64'):
            opt_mapping['arm64'] = idx + 1
        elif arg.startswith('-d') or arg.startswith('-dir') or arg.startswith('-directory'):
            opt_mapping['dir'] = idx + 1

    if 'version' not in opt_mapping:
        raise SystemExit('Missing version option.')

    if 'x86_64' not in opt_mapping:
        raise SystemExit('Missing x86_64 option.')

    if 'arm64' not in opt_mapping:
        raise SystemExit('Missing arm64 option.')

    version_opt_tokens = sys.argv[opt_mapping['version']].split('=')
    if len(version_opt_tokens) != 2:
        raise SystemExit('Version option has invalid format. Expected -versions=<>')
    versions = parse_python_versions(version_opt_tokens[1])

    x86_64_opt_tokens = sys.argv[opt_mapping['x86_64']].split('=')
    if len(x86_64_opt_tokens) != 2:
        raise SystemExit('x86_64 option has invalid format. Expected -x86-64=<>')
    x86_64_platforms = parse_platforms('x86_64', x86_64_opt_tokens[1])

    arm64_opt_tokens = sys.argv[opt_mapping['arm64']].split('=')
    if len(arm64_opt_tokens) != 2:
        raise SystemExit('arm64 option has invalid format. Expected -arm64=<>')
    arm64_platforms = parse_platforms('arm64', arm64_opt_tokens[1])

    if 'dir' not in opt_mapping:
        wheel_dir = Path.cwd()
    else:
        dir_opt_tokens = sys.argv[opt_mapping['dir']].split('=')
        if len(dir_opt_tokens) != 2:
            raise SystemExit('dir option has invalid format. Expected -dir=<>')
        if dir_opt_tokens[1].startswith('~'):
            wheel_dir = Path(path.expanduser(dir_opt_tokens[1]))
        else:
            wheel_dir = Path(dir_opt_tokens[1])
        if not wheel_dir.exists():
            raise SystemExit(f'Provided directory {wheel_dir}, does not exist.')

    return versions, x86_64_platforms, arm64_platforms, wheel_dir


if __name__ == '__main__':
    versions, x86_64_platforms, arm64_platforms, wheel_dir = validate_input()
    expected_wheels = get_expected_wheels(versions, x86_64_platforms, arm64_platforms)
    validate_wheels(wheel_dir, expected_wheels)
