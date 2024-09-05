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


def main(wheelname: str, project_name: str) -> None:
    tokens = wheelname.split('-')
    if len(tokens) < 5:
        raise SystemExit(f'Expected at least 5 tokens, found {len(tokens)}.')
    if tokens[0] != project_name:
        raise SystemExit(f'Expected at project name to be {project_name}, found {tokens[0]}.')

    print('-'.join(tokens[:2]))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Expected only wheel name and project name as input.')
    main(sys.argv[1], sys.argv[2])
