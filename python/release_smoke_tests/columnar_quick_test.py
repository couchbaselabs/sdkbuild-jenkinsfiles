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

import os
import pathlib

from configparser import ConfigParser
from dataclasses import dataclass

from couchbase_columnar.cluster import Cluster
from couchbase_columnar.credential import Credential
from couchbase_columnar.options import ClusterOptions, SecurityOptions


CONFIG_FILE = os.path.join(pathlib.Path(__file__).parent, "test_config.ini")
ENV_TRUE = ['true', '1', 'y', 'yes', 'on']


@dataclass
class TestConfig:
    scheme: str
    host: str
    port: str
    username: str
    password: str
    nonprod: bool
    database: str
    scope: str
    collection: str
    disable_server_certificate_verification: bool

    def get_connstr(self) -> str:
        connstr = f'{self.scheme}://{self.host}'
        if self.port != '':
            connstr += f':{self.port}'
        if self.disable_server_certificate_verification is True:
            connstr += '?security.disable_server_certificate_verification=true'
        return connstr


def get_config() -> TestConfig:
    test_config = ConfigParser()
    test_config.read(CONFIG_FILE)
    test_config_columnar = test_config['columnar']
    scheme = test_config_columnar.get('scheme', fallback='couchbases')
    host = test_config_columnar.get('host', fallback='')
    port = test_config_columnar.get('port', fallback='')
    username = test_config_columnar.get('username', fallback='Administrator')
    password = test_config_columnar.get('password', fallback='password')
    use_nonprod = test_config_columnar.get('nonprod', fallback='OFF')
    if use_nonprod.lower() in ENV_TRUE:
        nonprod = True
    else:
        nonprod = False
    disable_cert_verification = test_config_columnar.get('disable_server_certificate_verification', fallback='OFF')
    disable_server_certificate_verification = False
    if disable_cert_verification.lower() in ENV_TRUE:
        disable_server_certificate_verification = True
    fqdn = test_config_columnar.get('fqdn', fallback=None)
    if fqdn is None:
        raise ValueError('Must provide a FQDN.')

    fqdn_tokens = fqdn.split('.')
    if len(fqdn_tokens) != 3:
        raise ValueError(f'Invalid FQDN provided. Expected database.scope.collection. FQDN provided={fqdn}')

    database_name = f'{fqdn_tokens[0]}'
    scope_name = f'{fqdn_tokens[1]}'
    collection_name = f'{fqdn_tokens[2]}'

    return TestConfig(scheme,
                      host,
                      port,
                      username,
                      password,
                      nonprod,
                      database_name,
                      scope_name,
                      collection_name,
                      disable_server_certificate_verification)


def cluster_test(config: TestConfig) -> None:
    connstr = config.get_connstr()
    if config.nonprod is True:
        from couchbase_columnar.common.core._certificates import _Certificates
        sec_opts = SecurityOptions.trust_only_certificates(_Certificates.get_nonprod_certificates())
        opts = ClusterOptions(security_options=sec_opts)
    else:
        opts = ClusterOptions()

    cred = Credential.from_username_and_password(config.username, config.password)
    cluster = Cluster.create_instance(connstr, cred, opts)

    # Execute a query and buffer all result rows in client memory.
    statement = f'SELECT * FROM `{config.database}`.`{config.scope}`.`{config.collection}` LIMIT 2;'
    res = cluster.execute_query(statement)
    all_rows = res.get_all_rows()
    for row in all_rows:
        print(f'Found row: {row}')
    print(f'metadata={res.metadata()}')

    # Execute a query and process rows as they arrive from server.
    res = cluster.execute_query(statement)
    for row in res.rows():
        print(f'Found row: {row}')
    print(f'metadata={res.metadata()}')


def scope_test(config: TestConfig) -> None:
    connstr = config.get_connstr()
    if config.nonprod is True:
        from couchbase_columnar.common.core._certificates import _Certificates
        sec_opts = SecurityOptions.trust_only_certificates(_Certificates.get_nonprod_certificates())
        opts = ClusterOptions(security_options=sec_opts)
    else:
        opts = ClusterOptions()

    cred = Credential.from_username_and_password(config.username, config.password)
    scope = Cluster.create_instance(connstr, cred, opts).database(config.database).scope(config.scope)

    # Execute a scope-level query and buffer all result rows in client memory.
    statement = f'SELECT * FROM {config.collection} LIMIT 2;'
    res = scope.execute_query(statement)
    all_rows = res.get_all_rows()
    for row in all_rows:
        print(f'Found row: {row}')
    print(f'metadata={res.metadata()}')

    # Execute a scope-level query and process rows as they arrive from server.
    res = scope.execute_query(statement)
    for row in res.rows():
        print(f'Found row: {row}')
    print(f'metadata={res.metadata()}')


def main() -> None:
    config = get_config()
    cluster_test(config)
    scope_test(config)


if __name__ == '__main__':
    main()
