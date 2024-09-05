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

import json
import sys
from typing import Any, Dict


def parse_abi3audit_report(audit_report: str, project_abbr: str) -> None:  # noqa: C901
    with open(audit_report, 'r') as input_file:
        audit_data: Dict[str, Any] = json.load(input_file)

    if audit_data is None:
        raise SystemExit('Unable to parse audit report.')

    if 'specs' not in audit_data:
        raise SystemExit('Not specs object provided in audit report.')

    if len(audit_data.keys()) != 1:
        raise SystemExit('Expected only a single wheel in the audit report.')

    wheel_key = list(audit_data['specs'].keys())[0]
    if 'wheel' not in audit_data['specs'][wheel_key]:
        raise SystemExit(f'Could not find wheel in with key={wheel_key}.')

    if len(audit_data['specs'][wheel_key]['wheel']) != 1:
        raise SystemExit('Expected only a single wheel in the audit report.')

    wheel_data: Dict[str, Any] = audit_data['specs'][wheel_key]['wheel'][0]

    so_name = wheel_data.get('name', None)
    if sys.platform.startswith('win32'):
        expected_name = f'{project_abbr}_core.pyd'
    else:
        expected_name = f'{project_abbr}_core.so'
    if so_name != expected_name:
        raise SystemExit(f'Invalid shared object name. {so_name} != {expected_name}')

    if 'result' not in wheel_data:
        raise SystemExit('No wheel result object in the audit report.')

    if 'non_abi3_symbols' not in wheel_data['result']:
        raise SystemExit('No non_abi3 symbols listed in the audit report.')

    report_abi3_symbols = set(wheel_data['result']['non_abi3_symbols'])
    non_abi3_symbols = set(['_Py_IsFinalizing', 'PyUnicode_AsUTF8'])
    if non_abi3_symbols != report_abi3_symbols:
        raise SystemExit(('Mismatch in expected non-abi3 symbols.'
                          f' {report_abi3_symbols} != {non_abi3_symbols}'))

    print('All good!')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Expected only abi3audit report and project abbr (pycbc or pycbcc) as input.')

    parse_abi3audit_report(sys.argv[1], sys.argv[2])
