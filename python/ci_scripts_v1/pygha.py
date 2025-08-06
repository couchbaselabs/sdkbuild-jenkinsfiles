from __future__ import annotations

import json
import os
import re
import sys
from copy import deepcopy
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, List, Literal, Optional, Tuple, TypedDict, Union, cast, overload
from urllib.parse import urlparse


class ConfigStage(Enum):
    BUILD_SDIST = 1
    BUILD_WHEEL = 2
    VALIDATE_WHEEL = 3
    TEST_INTEGRATION = 4
    TEST_UNIT = 5

    def get_stage_name(self) -> str:
        if self == ConfigStage.BUILD_SDIST:
            return 'build_sdist'
        elif self == ConfigStage.BUILD_WHEEL:
            return 'build_wheels'
        elif self == ConfigStage.VALIDATE_WHEEL:
            return 'validate_wheels'
        elif self == ConfigStage.TEST_INTEGRATION:
            return 'test_integration'
        elif self == ConfigStage.TEST_UNIT:
            return 'test_unit'
        else:
            raise ValueError(f'Invalid config stage: {self}')


class SdkProject(Enum):
    Analytics = 'PYCBAC'
    Columnar = 'PYCBCC'
    Operational = 'PYCBC'

    @classmethod
    def from_env(cls, env_key: Optional[str] = None) -> SdkProject:
        if env_key is None:
            env_key = 'CBCI_PROJECT_TYPE'
        env = get_env_variable(env_key)
        if env.upper() in ['ANALYTICS', 'PYCBAC']:
            return SdkProject.Analytics
        if env.upper() in ['COLUMNAR', 'PYCBCC']:
            return SdkProject.Columnar
        if env.upper() in ['OPERATIONAL', 'PYCBC']:
            return SdkProject.Operational
        else:
            print(f'Invalid SDK project: {env}')
            sys.exit(1)

    @staticmethod
    def get_default_cbdino_config(sdk_project: SdkProject) -> CbdinoConfig:
        if sdk_project == SdkProject.Analytics:
            return CbdinoConfig(
                num_nodes=3,
                version='2.0.0-1061',
                # if using >= v0.0.80 should not need the image portion of the config
                # image='ghcr.io/cb-vanilla/columnar:2.0.0-1061',
                use_load_balancer=True,
                use_dns=False,
                use_dino_certs=True,
            )
        elif sdk_project == SdkProject.Columnar:
            return CbdinoConfig(
                num_nodes=3,
                version='1.2.0-1055',
                image='ghcr.io/cb-vanilla/columnar:1.2.0-1055',
                use_load_balancer=False,
                use_dns=False,
                use_dino_certs=False,
            )
        elif sdk_project == SdkProject.Operational:
            return CbdinoConfig(
                num_nodes=3, version='7.6.6', use_load_balancer=False, use_dns=False, use_dino_certs=False
            )
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)

    @staticmethod
    def get_test_config_keys(sdk_project: SdkProject) -> List[str]:
        if sdk_project == SdkProject.Analytics:
            return ['scheme', 'host', 'port', 'username', 'password', 'fqdn', 'nonprod', 'tls_verify']
        elif sdk_project == SdkProject.Columnar:
            return ['scheme', 'host', 'port', 'username', 'password', 'fqdn', 'nonprod', 'tls_verify']
        elif sdk_project == SdkProject.Operational:
            return ['scheme', 'host', 'port', 'username', 'password']
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)

    @staticmethod
    def get_default_apis(sdk_project: SdkProject) -> List[str]:
        if sdk_project == SdkProject.Analytics:
            return ['acouchbase', 'couchbase']
        elif sdk_project == SdkProject.Columnar:
            return ['acouchbase', 'couchbase']
        elif sdk_project == SdkProject.Operational:
            return ['acouchbase', 'couchbase', 'txcouchbase']
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)


@dataclass
class CbdinoConfig:
    num_nodes: int
    version: str
    image: Optional[str] = None
    use_load_balancer: Optional[bool] = None
    use_dns: Optional[bool] = None
    use_dino_certs: Optional[bool] = None

    def to_dict(self) -> Dict[str, Any]:
        output = {'num_nodes': self.num_nodes, 'version': self.version}
        if self.image is not None:
            output['image'] = self.image
        if self.use_load_balancer is not None:
            output['use_load_balancer'] = self.use_load_balancer
        if self.use_dns is not None:
            output['use_dns'] = self.use_dns
        if self.use_dino_certs is not None:
            output['use_dino_certs'] = self.use_dino_certs
        return output

    def to_yaml_config(self, sdk_project: SdkProject) -> str:
        output = []
        if sdk_project == SdkProject.Analytics:
            output.append('columnar: true')
        output.append('nodes:')
        output.append(f'  - count: {self.num_nodes}')
        output.append(f'    version: {self.version}')
        if self.image is not None:
            output.append('    docker:')
            output.append(f'      image: {self.image}')
        if sdk_project == SdkProject.Analytics:
            output.append('docker:')
            if self.use_load_balancer is not None:
                use_load_balancer = 'true' if self.use_load_balancer else 'false'
                output.append(f'  load-balancer: {use_load_balancer}')
            if self.use_dns is not None:
                use_dns = 'true' if self.use_dns else 'false'
                output.append(f'  use-dns: {use_dns}')
            if self.use_dino_certs is not None:
                use_dino_certs = 'true' if self.use_dino_certs else 'false'
                output.append(f'  use-dino-certs: {use_dino_certs}')
        output.append('')
        return '\n'.join(output)


@dataclass
class PublishConfig:
    publish_pypi: bool
    publish_test_pypi: bool
    publish_api_docs: bool
    publish_dry_run: bool
    set_git_tag: Optional[str] = None
    tests_run_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Union[bool, str]]:
        output: Dict[str, Union[bool, str]] = {
            'publish_pypi': self.publish_pypi,
            'publish_test_pypi': self.publish_test_pypi,
            'publish_api_docs': self.publish_api_docs,
            'publish_dry_run': self.publish_dry_run,
        }
        if self.set_git_tag is not None:
            output['set_git_tag'] = self.set_git_tag
        else:
            output['set_git_tag'] = ''
        if self.tests_run_id is not None:
            output['tests_run_id'] = self.tests_run_id
        else:
            output['tests_run_id'] = ''
        return output

    @classmethod
    def get_default_publish_config(cls) -> PublishConfig:
        return PublishConfig(
            publish_pypi=True,
            publish_test_pypi=True,
            publish_api_docs=True,
            publish_dry_run=False,
        )


@dataclass
class PytestConfig:
    integration_config: PytestIntegrationConfig
    unit_config: PytestUnitConfig

    def to_dict(self, is_unit: bool) -> Dict[str, Union[bool, str]]:
        if is_unit:
            if self.unit_config.debug_logging is True:
                if '--log-cli-level' not in self.unit_config.acouchbase_opts:
                    self.unit_config.acouchbase_opts += ' --log-cli-level=DEBUG'
                if '--log-cli-level' not in self.unit_config.couchbase_opts:
                    self.unit_config.couchbase_opts += ' --log-cli-level=DEBUG'
            return {
                'acouchbase_cmd': self.unit_config.acouchbase_cmd,
                'acouchbase_opts': self.unit_config.acouchbase_opts,
                'couchbase_cmd': self.unit_config.couchbase_cmd,
                'couchbase_opts': self.unit_config.couchbase_opts,
            }
        else:
            if self.integration_config.debug_logging is True:
                if '--log-cli-level' not in self.integration_config.acouchbase_opts:
                    self.integration_config.acouchbase_opts += ' --log-cli-level=DEBUG'
                if '--log-cli-level' not in self.integration_config.couchbase_opts:
                    self.integration_config.couchbase_opts += ' --log-cli-level=DEBUG'
            return {
                'acouchbase_cmd': self.integration_config.acouchbase_cmd,
                'acouchbase_opts': self.integration_config.acouchbase_opts,
                'couchbase_cmd': self.integration_config.couchbase_cmd,
                'couchbase_opts': self.integration_config.couchbase_opts,
            }

    @classmethod
    def get_default_pytest_config(cls, sdk_project: SdkProject) -> PytestConfig:
        return cls(
            integration_config=PytestIntegrationConfig.get_default_config(sdk_project),
            unit_config=PytestUnitConfig.get_default_config(sdk_project),
        )

    @staticmethod
    def get_config_keys() -> List[str]:
        return [
            'debug_logging',
            'acouchbase_cmd',
            'acouchbase_opts',
            'couchbase_cmd',
            'couchbase_opts',
        ]

    @staticmethod
    def get_config_options(cfg: Dict[str, Any], sdk_project: SdkProject) -> Dict[str, str]:
        if sdk_project == SdkProject.Analytics:
            debug_logging = cfg.get('debug_logging', cfg.get('debug-logging', None))
            acb_cmd = cfg.get('acouchbase_analytics_cmd', cfg.get('acouchbase-analytics-cmd', None))
            acb_opts = cfg.get('acouchbase_analytics_opts', cfg.get('acouchbase-analytics-opts', None))
            cb_cmd = cfg.get('couchbase_analytics_cmd', cfg.get('couchbase-analytics-cmd', None))
            cb_opts = cfg.get('couchbase_analytics_opts', cfg.get('couchbase-analytics-opts', None))
        elif sdk_project == SdkProject.Columnar:
            debug_logging = cfg.get('debug_logging', cfg.get('debug-logging', None))
            acb_cmd = cfg.get('acouchbase_columnar_cmd', cfg.get('acouchbase-columnar-cmd', None))
            acb_opts = cfg.get('acouchbase_columnar_opts', cfg.get('acouchbase-columnar-opts', None))
            cb_cmd = cfg.get('couchbase_columnar_cmd', cfg.get('couchbase-columnar-cmd', None))
            cb_opts = cfg.get('couchbase_columnar_opts', cfg.get('couchbase-columnar-opts', None))
        elif sdk_project == SdkProject.Operational:
            debug_logging = cfg.get('debug_logging', cfg.get('debug-logging', None))
            acb_cmd = cfg.get('acouchbase_cmd', cfg.get('acouchbase-cmd', None))
            acb_opts = cfg.get('acouchbase_opts', cfg.get('acouchbase-opts', None))
            cb_cmd = cfg.get('couchbase_cmd', cfg.get('couchbase-cmd', None))
            cb_opts = cfg.get('couchbase_opts', cfg.get('couchbase-opts', None))
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)

        output: Dict[str, str] = {}
        if debug_logging is not None:
            output['debug_logging'] = debug_logging
        if acb_cmd is not None:
            output['acouchbase_cmd'] = acb_cmd
        if acb_opts is not None:
            output['acouchbase_opts'] = acb_opts
        if cb_cmd is not None:
            output['couchbase_cmd'] = cb_cmd
        if cb_opts is not None:
            output['couchbase_opts'] = cb_opts

        return output


@dataclass
class PytestIntegrationConfig:
    debug_logging: bool
    acouchbase_cmd: str
    acouchbase_opts: str
    couchbase_cmd: str
    couchbase_opts: str

    @classmethod
    def get_default_config(cls, sdk_project: SdkProject) -> PytestIntegrationConfig:
        if sdk_project == SdkProject.Analytics:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbac_acouchbase and pycbac_integration'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbac_couchbase and pycbac_integration'",
                couchbase_opts='-rA -vv',
            )
        elif sdk_project == SdkProject.Columnar:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbcc_acouchbase and pycbac_integration'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbcc_couchbase and pycbac_integration'",
                couchbase_opts='-rA -vv',
            )
        elif sdk_project == SdkProject.Operational:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbc_acouchbase and pycbac_integration'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbc_couchbase and pycbac_integration'",
                couchbase_opts='-rA -vv',
            )
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)


@dataclass
class PytestUnitConfig:
    debug_logging: bool
    acouchbase_cmd: str
    acouchbase_opts: str
    couchbase_cmd: str
    couchbase_opts: str

    @classmethod
    def get_default_config(cls, sdk_project: SdkProject) -> PytestUnitConfig:
        if sdk_project == SdkProject.Analytics:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbac_acouchbase and pycbac_unit'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbac_couchbase and pycbac_unit'",
                couchbase_opts='-rA -vv',
            )
        elif sdk_project == SdkProject.Columnar:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbcc_acouchbase and pycbcc_unit'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbcc_couchbase and pycbcc_unit'",
                couchbase_opts='-rA -vv',
            )
        elif sdk_project == SdkProject.Operational:
            return cls(
                debug_logging=False,
                acouchbase_cmd="pytest -m 'pycbc_acouchbase and pycbc_unit'",
                acouchbase_opts='-rA -vv',
                couchbase_cmd="pytest -m 'pycbc_couchbase and pycbc_unit'",
                couchbase_opts='-rA -vv',
            )
        else:
            print(f'Invalid SDK project: {sdk_project.value}')
            sys.exit(1)


@dataclass
class TestConfig:
    skip_integration: bool
    skip_cbdino: bool
    apis: List[str]
    install_types: List[str]
    scheme: Optional[str] = None
    host: Optional[str] = None
    port: Optional[str] = None
    username: Optional[str] = None
    password: Optional[str] = None
    fqdn: Optional[str] = None
    nonprod: Optional[bool] = None
    tls_verify: Optional[bool] = None
    cbdino_config: Optional[CbdinoConfig] = None

    def can_do_integration(self) -> bool:
        return (
            not self.skip_integration
            and self.scheme is not None
            and self.host is not None
            and self.username is not None
            and self.password is not None
        )

    def to_dict(self, sdk_project: SdkProject) -> Dict[str, Any]:
        if not self.can_do_integration():
            return {}
        output = {
            f'{sdk_project.value}_SCHEME': self.scheme,
            f'{sdk_project.value}_HOST': self.host,
            f'{sdk_project.value}_PORT': self.port,
            f'{sdk_project.value}_USERNAME': self.username,
            f'{sdk_project.value}_PASSWORD': self.password,
        }
        if self.fqdn is not None:
            output[f'{sdk_project.value}_FQDN'] = self.fqdn
        if self.nonprod is not None:
            output[f'{sdk_project.value}_NONPROD'] = 'ON' if self.nonprod else 'OFF'
        if self.tls_verify is not None:
            output[f'{sdk_project.value}_TLS_VERIFY'] = 'ON' if self.tls_verify else 'OFF'
        return output

    @classmethod
    def create_from_config(
        cls,
        skip_integration: bool,
        skip_cbdino: bool,
        apis: List[str],
        install_types: List[str],
        cbdino_config: Optional[CbdinoConfig] = None,
        **kwargs: str,
    ) -> TestConfig:
        nonprod = None
        if 'nonprod' in kwargs:
            nonprod = bool(kwargs['nonprod'])
        tls_verify = None
        if 'tls_verify' in kwargs:
            tls_verify = bool(kwargs['tls_verify'])
        return cls(
            skip_integration,
            skip_cbdino,
            apis,
            install_types,
            scheme=kwargs.get('scheme'),
            host=kwargs.get('host'),
            port=kwargs.get('port'),
            username=kwargs.get('username', 'Administrator'),
            password=kwargs.get('password', 'password'),
            fqdn=kwargs.get('fqdn'),
            nonprod=nonprod,
            tls_verify=tls_verify,
            cbdino_config=cbdino_config,
        )


@dataclass
class ConfigOption:
    name: str
    description: str
    required: bool = False
    default: Optional[str] = None
    sdk_alias: Optional[str] = None

    def __post_init__(self) -> None:
        if self.sdk_alias is None:
            self.sdk_alias = f'SDKPROJECT_{self.name.upper()}'


class MacosStageMatrix(TypedDict, total=False):
    os: Optional[List[str]]
    arch: List[str]
    python_version: List[str]
    exclude: Optional[List[Dict[str, str]]]


class WindowsStageMatrix(TypedDict, total=False):
    os: Optional[List[str]]
    arch: List[str]
    python_version: List[str]
    exclude: Optional[List[Dict[str, str]]]


class LinuxStageMatrix(TypedDict, total=False):
    linux_type: List[str]
    arch: List[str]
    python_version: List[str]
    container: Optional[List[str]]
    os: Optional[List[str]]
    exclude: Optional[List[Dict[str, str]]]


class StageMatrix(TypedDict, total=False):
    has_alpine: bool
    has_linux: bool
    has_macos: bool
    has_windows: bool
    alpine: Optional[LinuxStageMatrix]
    linux: Optional[LinuxStageMatrix]
    macos: Optional[MacosStageMatrix]
    windows: Optional[WindowsStageMatrix]


class TestStageMatrix(StageMatrix, total=False):
    skip_cbdino: bool
    has_linux_cbdino: bool
    skip_integration: bool
    api: List[str]
    install_type: List[str]
    test_config: Optional[TestConfig]
    cbdino_config: Optional[CbdinoConfig]
    linux_cbdino: Optional[LinuxStageMatrix]
    pytest_config: Optional[PytestConfig]


DEFAULT_CONFIG: Dict[str, ConfigOption] = {
    'USE_OPENSSL': ConfigOption(
        'use_openssl',
        'Use OpenSSL instead of boringssl',
        required=True,
        default='OFF',
        sdk_alias='SDKPROJECT_USE_OPENSSL',
    ),
    'OPENSSL_VERSION': ConfigOption(
        'openssl_version',
        'The version of OpenSSL to use instead of boringssl',
        required=False,
        default=None,
        sdk_alias='SDKPROJECT_OPENSSL_VERSION',
    ),
    'SET_CPM_CACHE': ConfigOption(
        'set_cpm_cache',
        'Initialize the C++ core CPM cache',
        required=False,
        default='ON',
        sdk_alias='SDKPROJECT_SET_CPM_CACHE',
    ),
    'USE_LIMITED_API': ConfigOption(
        'use_limited_api',
        'Set to enable use of Py_LIMITED_API',
        required=False,
        default=None,
        sdk_alias='SDKPROJECT_LIMITED_API',
    ),
    'VERBOSE_MAKEFILE': ConfigOption(
        'verbose_makefile',
        'Use verbose logging when configuring/building',
        required=False,
        default=None,
        sdk_alias='SDKPROJECT_VERBOSE_MAKEFILE',
    ),
    'BUILD_TYPE': ConfigOption(
        'build_type',
        'Sets the build type when configuring/building',
        required=False,
        default='RelWithDebInfo',
        sdk_alias='SDKPROJECT_BUILD_TYPE',
    ),
}

STAGE_MATRIX_KEYS = [
    'python-versions',
    'python_versions',
    'arches',
    'platforms',
    'skip_integration',
    'skip-integration',
    'test_config',
    'test-config',
    'skip_cbdino',
    'skip-cbdino',
    'cbdino_config',
    'cbdino-config',
]


@overload
def get_env_variable(key: str) -> str: ...


@overload
def get_env_variable(key: str, quiet: Literal[False]) -> str: ...


@overload
def get_env_variable(key: str, quiet: Literal[True]) -> Optional[str]: ...


def get_env_variable(key: str, quiet: Optional[bool] = False) -> Optional[str]:
    try:
        return os.environ[key]
    except KeyError:
        if not quiet:
            print(f'Environment variable {key} not set.')
            sys.exit(1)
    except Exception as e:
        if not quiet:
            print(f'Error getting environment variable {key}: {e}')
            sys.exit(1)
    return None


def get_config_boolean(config_value: Union[bool, str]) -> bool:
    if isinstance(config_value, bool):
        return config_value
    if config_value.lower() in ['true', '1', 'y', 'yes', 'on']:
        return True
    else:
        return False


def get_config_boolean_as_str(config_value: str) -> str:
    if config_value.lower() in ['true', '1', 'y', 'yes', 'on']:
        return 'True'
    else:
        return 'False'


def parse_wheel_name(wheelname: str, project_name: str) -> None:
    tokens = wheelname.split('-')
    if len(tokens) < 5:
        print(f'Expected at least 5 tokens, found {len(tokens)}.')
        sys.exit(1)
    if tokens[0] != project_name:
        print(f'Expected at project name to be {project_name}, found {tokens[0]}.')
        sys.exit(1)

    print('-'.join(tokens[:2]))


class CbDinoConfigHandler:
    @staticmethod
    def build_cbdino_config(sdk_project: SdkProject, cbdino_cfg: Optional[Dict[str, Any]] = None) -> CbdinoConfig:
        cbdino_config: Optional[CbdinoConfig] = None
        default_cbdino_cfg = SdkProject.get_default_cbdino_config(sdk_project)
        if cbdino_cfg:
            cbdino_config = CbdinoConfig(
                num_nodes=cbdino_cfg.get('num_nodes', default_cbdino_cfg.num_nodes),
                version=cbdino_cfg.get('version', default_cbdino_cfg.version),
                image=cbdino_cfg.get('image', default_cbdino_cfg.image),
                use_load_balancer=cbdino_cfg.get('use_load_balancer', default_cbdino_cfg.use_load_balancer),
                use_dns=cbdino_cfg.get('use_dns', default_cbdino_cfg.use_dns),
                use_dino_certs=cbdino_cfg.get('use_dino_certs', default_cbdino_cfg.use_dino_certs),
            )
        else:
            cbdino_config = default_cbdino_cfg

        return cbdino_config

    @staticmethod
    def build_cbdino_config_yaml(output_path: str) -> None:
        user_config = UserConfigHandler.user_config_as_json('CBCI_CONFIG')
        test_config = UserConfigHandler.parse_user_test_config(user_config)
        if test_config.skip_cbdino or test_config.cbdino_config is None:
            return

        sdk_project = SdkProject.from_env()
        with open(os.path.join(output_path, 'cluster_def.yaml'), 'w') as outfile:
            outfile.write(test_config.cbdino_config.to_yaml_config(sdk_project))


class ConfigHandler:
    @staticmethod
    def _set_arm64_platforms(user_platforms: str, arches: List[str], quiet: Optional[bool] = True) -> List[str]:
        arm64_platforms: List[str] = []
        if 'arm64' in arches or 'aarch64' in arches:
            try:
                platforms = [p.strip().lower() for p in user_platforms.replace(',', ' ').split()]
                for platform in platforms:
                    if platform not in ConfigHandler.get_supported_platforms('arm64'):
                        if not quiet:
                            print(f'Unsupported arm64 platform: {platform}. Ignoring.')
                        continue
                    arm64_platforms.append(platform)
            except Exception as e:
                if not quiet:
                    print(f'Unable to parse user provided arches: {e}. Ignoring.')

            if not arm64_platforms:
                arm64_platforms = ConfigHandler.get_supported_platforms('arm64')
        return arm64_platforms

    @staticmethod
    def _set_x86_64_platforms(user_platforms: str, arches: List[str], quiet: Optional[bool] = True) -> List[str]:
        x86_64_platforms: List[str] = []
        if 'x86_64' in arches:
            try:
                platforms = [p.strip().lower() for p in user_platforms.replace(',', ' ').split()]
                for platform in platforms:
                    if platform not in ConfigHandler.get_supported_platforms('x86_64'):
                        if not quiet:
                            print(f'Unsupported x86_64 platform: {platform}. Ignoring.')
                        continue
                    x86_64_platforms.append(platform)
            except Exception as e:
                if not quiet:
                    print(f'Unable to parse user provided arches: {e}. Ignoring.')

            if not x86_64_platforms:
                x86_64_platforms = ConfigHandler.get_supported_platforms('x86_64')

        return x86_64_platforms

    @staticmethod
    def build_default_config(stage: ConfigStage, project: SdkProject) -> Dict[str, ConfigOption]:
        config = deepcopy(DEFAULT_CONFIG)
        if stage == ConfigStage.BUILD_SDIST:
            config['SET_CPM_CACHE'].required = True
        elif stage == ConfigStage.BUILD_WHEEL:
            config['BUILD_TYPE'].required = True
            prefer_ccache = get_env_variable('PREFER_CCACHE', quiet=True)
            if prefer_ccache:
                config['CB_CACHE_OPTION'].required = True
                config['CB_CACHE_OPTION'].default = 'ccache'
                config['CCACHE_DIR'] = ConfigOption(
                    'ccache_dir', 'Directory for the ccache', True, prefer_ccache, sdk_alias='CCACHE_DIR'
                )
            prefer_verbose = get_env_variable('PREFER_VERBOSE_MAKEFILE', quiet=True)
            if prefer_verbose:
                config['VERBOSE_MAKEFILE'].required = True
                config['VERBOSE_MAKEFILE'].default = 'ON'

        for v in config.values():
            if v.sdk_alias:
                v.sdk_alias = v.sdk_alias.replace('SDKPROJECT', project.value)

        return config

    @staticmethod
    def get_supported_python_versions() -> List[str]:
        return get_env_variable('CBCI_SUPPORTED_PYTHON_VERSIONS').split()

    @staticmethod
    def get_supported_architectures() -> List[str]:
        return ['x86_64', 'arm64', 'aarch64']

    @staticmethod
    def get_supported_platforms(arch: str) -> List[str]:
        if arch == 'x86_64':
            return get_env_variable('CBCI_SUPPORTED_X86_64_PLATFORMS').split()
        elif arch in ['arm64', 'aarch64']:
            return get_env_variable('CBCI_SUPPORTED_ARM64_PLATFORMS').split()
        else:
            print(f'Unsupported architecture: {arch}')
            return []

    @staticmethod
    def is_supported_python_version(version: str) -> bool:
        version_tokens = version.split('.')
        # shouldn't happen, but in case, we only support Python 3.x
        if len(version_tokens) == 1:
            return version_tokens[0] == '3'
        if len(version_tokens) == 2:
            return version in ConfigHandler.get_supported_python_versions()
        if len(version_tokens) == 3:
            return '.'.join(version_tokens[:2]) in ConfigHandler.get_supported_python_versions()

        return False

    @staticmethod
    def parse_config(config_stage: ConfigStage, config_key: str) -> None:
        sdk_project = SdkProject.from_env()
        default_cfg = ConfigHandler.build_default_config(config_stage, sdk_project)
        user_config = UserConfigHandler.user_config_as_json(config_key)

        cfg = {}
        for key, value in user_config.items():
            if key in STAGE_MATRIX_KEYS:
                continue
            if key not in default_cfg:
                # print(f'Invalid key: {key}. Ignoring.')
                continue
            if value in [True, False]:
                cfg[key] = 'ON' if value else 'OFF'
            else:
                cfg[key] = value

        # handle defaults
        required_defaults = [k for k, v in default_cfg.items() if v.required is True]
        for k in required_defaults:
            if k not in cfg:
                if (default := default_cfg[k].default) is not None:
                    cfg[k] = default

        print(' '.join([f'{default_cfg[k].sdk_alias}={v}' for k, v in cfg.items()]))

    @staticmethod
    def set_python_versions(user_config: str, quiet: Optional[bool] = True) -> List[str]:
        versions = []
        try:
            user_python_versions = user_config.replace(',', ' ').split()
            for version in user_python_versions:
                if not ConfigHandler.is_supported_python_version(version):
                    if not quiet:
                        print(f'Unsupported Python version: {version}. Ignoring.')
                    continue
                versions.append(version)

        except Exception as e:
            if not quiet:
                print(f'Unable to parse user provided Python versions: {e}. Ignoring.')

        return versions

    @staticmethod
    def set_os_and_arch(
        user_platforms: str, user_arches: str, quiet: Optional[bool] = True
    ) -> Tuple[List[str], List[str]]:
        arches = []
        try:
            arches = [a.strip().lower() for a in user_arches.replace(',', ' ').split()]
            for arch in arches:
                if arch not in ConfigHandler.get_supported_architectures():
                    if not quiet:
                        print(f'Unsupported architecture: {arch}. Ignoring.')
                    arches.remove(arch)
        except Exception as e:
            if not quiet:
                print(f'Unable to parse user provided arches: {e}. Ignoring.')

        if not arches:
            arches = ConfigHandler.get_supported_architectures()[:-1]

        if 'arm64' in arches and 'aarch64' in arches:
            # we don't need both arm64 and aarch64
            arches.remove('aarch64')

        x86_64_platforms = ConfigHandler._set_x86_64_platforms(user_platforms, arches, quiet=quiet)
        arm64_platforms = ConfigHandler._set_arm64_platforms(user_platforms, arches, quiet=quiet)
        return x86_64_platforms, arm64_platforms


class PublishConfigHandler:
    @staticmethod
    def build_publish_config(config_key: str, version_key: str) -> None:
        _, _, publish_config, _ = UserConfigHandler.parse_user_config(config_key, version_key=version_key)
        print(f'{json.dumps({"publish_config": publish_config.to_dict()})}')


class StageMatrixConfigHandler:
    @staticmethod
    def _build_cbdino_stage_matrix_portion(test_matrix: TestStageMatrix, test_config: TestConfig) -> None:
        if test_config.cbdino_config is not None:
            test_matrix['cbdino_config'] = test_config.cbdino_config
            linux_cfg = test_matrix.get('linux', {})
            if linux_cfg:
                linux_cbdino = deepcopy(linux_cfg)
                linux_cbdino.pop('linux_type', [])
                linux_cbdino.pop('exclude', None)
                linux_cbdino['os'] = ['ubuntu-latest']
                linux_cbdino['arch'] = ['x86_64']
                test_matrix['linux_cbdino'] = linux_cbdino
                test_matrix['has_linux_cbdino'] = True
            else:
                test_matrix['has_linux_cbdino'] = False
        else:
            test_config.skip_cbdino = True
            test_matrix['skip_cbdino'] = test_config.skip_cbdino
            test_matrix['has_linux_cbdino'] = False

    @staticmethod
    def _build_integration_test_stage_matrix(
        test_matrix: TestStageMatrix, test_config: TestConfig, pytest_config: PytestConfig
    ) -> None:
        test_matrix['skip_cbdino'] = test_config.skip_cbdino
        test_matrix['skip_integration'] = test_config.skip_integration
        test_matrix['api'] = test_config.apis
        test_matrix['install_type'] = test_config.install_types
        test_matrix['pytest_config'] = pytest_config
        if test_config.skip_cbdino is False:
            StageMatrixConfigHandler._build_cbdino_stage_matrix_portion(test_matrix, test_config)
        if test_config.skip_integration is False:
            if not test_config.can_do_integration():
                test_config.skip_integration = True
                test_matrix['skip_integration'] = test_config.skip_integration
            else:
                test_matrix['test_config'] = test_config

    @staticmethod
    def _build_linux_alpine_stage_matrix(
        python_versions: List[str], x86_64_platforms: List[str], arm64_platforms: List[str]
    ) -> LinuxStageMatrix:
        linux_alpine_matrix: LinuxStageMatrix = {}
        if 'alpine' in x86_64_platforms:
            if 'linux_type' not in linux_alpine_matrix:
                linux_alpine_matrix['linux_type'] = ['musllinux']
            else:
                linux_alpine_matrix['linux_type'].append('musllinux')
            if 'arch' not in linux_alpine_matrix:
                linux_alpine_matrix['arch'] = ['x86_64']

        if linux_alpine_matrix:
            linux_alpine_matrix['python_version'] = python_versions

        return linux_alpine_matrix

    @staticmethod
    def _build_linux_stage_matrix(
        python_versions: List[str], x86_64_platforms: List[str], arm64_platforms: List[str]
    ) -> LinuxStageMatrix:
        linux_matrix: LinuxStageMatrix = {}
        if 'linux' in x86_64_platforms:
            linux_matrix['linux_type'] = ['manylinux']
            linux_matrix['arch'] = ['x86_64']
        if 'linux' in arm64_platforms:
            if 'linux_type' not in linux_matrix:
                linux_matrix['linux_type'] = ['manylinux']
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['aarch64']
            else:
                linux_matrix['arch'].append('aarch64')

        if linux_matrix:
            linux_matrix['python_version'] = python_versions
            if 'aarch64' in linux_matrix['arch'] and 'musllinux' in linux_matrix['linux_type']:
                linux_matrix['exclude'] = [{'linux-type': 'musllinux', 'arch': 'aarch64'}]

        return linux_matrix

    @staticmethod
    def _build_linux_stage_matrix_new(
        python_versions: List[str], x86_64_platforms: List[str], arm64_platforms: List[str]
    ) -> LinuxStageMatrix:
        linux_matrix: LinuxStageMatrix = {}
        if 'linux' in x86_64_platforms:
            linux_plat = get_env_variable('CBCI_DEFAULT_LINUX_X86_64_PLATFORM')
            linux_matrix['os'] = [linux_plat]
            linux_matrix['arch'] = ['x86_64']
        if 'macos' in arm64_platforms:
            linux_plat = get_env_variable('CBCI_DEFAULT_LINUX_ARM64_PLATFORM')
            if 'os' not in linux_matrix or linux_matrix['os'] is None:
                linux_matrix['os'] = [linux_plat]
            else:
                linux_matrix['os'].append(linux_plat)
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['arm64']
            else:
                linux_matrix['arch'].append('arm64')

        if linux_matrix:
            linux_matrix['python_version'] = python_versions
            if 'arm64' in linux_matrix['arch'] and 'x86_64' in linux_matrix['arch']:
                linux_x86_64_plat = get_env_variable('CBCI_DEFAULT_LINUX_X86_64_PLATFORM')
                linux_arm64_plat = get_env_variable('CBCI_DEFAULT_LINUX_ARM64_PLATFORM')
                linux_matrix['exclude'] = [
                    {'os': linux_x86_64_plat, 'arch': 'arm64'},
                    {'os': linux_arm64_plat, 'arch': 'x86_64'},
                ]

        return linux_matrix

    @staticmethod
    def _build_linux_alpine_validate_wheel_stage_matrix(  # noqa: C901
        python_versions: List[str],
        x86_64_platforms: List[str],
        arm64_platforms: List[str],
    ) -> LinuxStageMatrix:
        alpine_matrix: LinuxStageMatrix = {}
        if 'alpine' in x86_64_platforms:
            alpine_container = get_env_variable('CBCI_DEFAULT_ALPINE_CONTAINER')
            if 'container' not in alpine_matrix or alpine_matrix['container'] is None:
                alpine_matrix['container'] = [alpine_container]
            else:
                alpine_matrix['container'].append(alpine_container)
            if 'arch' not in alpine_matrix:
                alpine_matrix['arch'] = ['x86_64']

        return alpine_matrix

    @staticmethod
    def _build_linux_validate_wheel_stage_matrix(  # noqa: C901
        python_versions: List[str],
        x86_64_platforms: List[str],
        arm64_platforms: List[str],
    ) -> LinuxStageMatrix:
        linux_matrix: LinuxStageMatrix = {}
        if 'linux' in x86_64_platforms:
            linux_container = get_env_variable('CBCI_DEFAULT_LINUX_CONTAINER')
            linux_matrix['container'] = [linux_container]
            linux_matrix['arch'] = ['x86_64']
        if 'linux' in arm64_platforms:
            linux_container = get_env_variable('CBCI_DEFAULT_LINUX_CONTAINER')
            if 'container' not in linux_matrix:
                linux_matrix['container'] = [linux_container]
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['aarch64']
            else:
                linux_matrix['arch'].append('aarch64')

        if linux_matrix:
            default_linux_plat = get_env_variable('CBCI_DEFAULT_LINUX_PLATFORM')
            linux_matrix['os'] = [default_linux_plat]
            linux_matrix['python_version'] = python_versions

        return linux_matrix

    # TODO: this is a possibility, but the matrix becomes rather large (>= 60)
    # def add_test_config_to_stage_matrix(matrix_dict: Dict[str, Any],
    #                                     test_matrix: TestStageMatrix,
    #                                     sdk_project: SdkProject) -> None:
    #     if 'has_linux' in matrix_dict and matrix_dict['has_linux'] is True:
    #         matrix_dict['linux']['api'] = test_matrix.get('api', SdkProject.get_default_apis(sdk_project))
    #         matrix_dict['linux']['install_type'] = test_matrix.get('install_type', ['sdist', 'wheel'])
    #     if 'has_macos' in matrix_dict and matrix_dict['has_macos'] is True:
    #         matrix_dict['macos']['api'] = test_matrix.get('api', SdkProject.get_default_apis(sdk_project))
    #         matrix_dict['macos']['install_type'] = test_matrix.get('install_type', ['sdist', 'wheel'])
    #     if 'has_windows' in matrix_dict and matrix_dict['has_windows'] is True:
    #         matrix_dict['windows']['api'] = test_matrix.get('api', SdkProject.get_default_apis(sdk_project))
    #         matrix_dict['windows']['install_type'] = test_matrix.get('install_type', ['sdist', 'wheel'])

    @staticmethod
    def _add_apis_and_install_type_to_stage_matrix(
        matrix_dict: Dict[str, Any], test_matrix: TestStageMatrix, sdk_project: SdkProject
    ) -> None:
        apis = test_matrix.get('api', SdkProject.get_default_apis(sdk_project))
        matrix_dict['test_acouchbase_api'] = True if 'acouchbase' in apis else False
        matrix_dict['test_couchbase_api'] = True if 'couchbase' in apis else False
        matrix_dict['test_txcouchbase_api'] = True if 'txcouchbase' in apis else False
        install_types = test_matrix.get('install_type', ['sdist', 'wheel'])
        matrix_dict['test_sdist_install'] = True if 'sdist' in install_types else False
        matrix_dict['test_wheel_install'] = True if 'wheel' in install_types else False

    @staticmethod
    def _add_install_command(matrix_dict: Dict[str, Any]) -> None:
        install_cmd = TestConfigHandler.get_install_command()
        if install_cmd is not None:
            matrix_dict['install_cmd'] = install_cmd

    @staticmethod
    def _add_cbdino_config_to_stage_matrix(
        matrix_dict: Dict[str, Any],
        test_matrix: TestStageMatrix,
    ) -> None:
        cbdino_cfg = test_matrix.get('cbdino_config', None)
        if cbdino_cfg is None:
            return
        matrix_dict['cbdino_config'] = cbdino_cfg.to_dict()
        if 'linux_cbdino' in test_matrix:
            linux_cbdino = test_matrix['linux_cbdino']
            if linux_cbdino is not None:
                matrix_dict['linux_cbdino'] = {
                    'os': linux_cbdino.get('os', []),
                    'arch': linux_cbdino.get('arch', []),
                    'python-version': linux_cbdino.get('python_version', []),
                }

    @staticmethod
    def _add_pytest_config(matrix_dict: Dict[str, Any], test_matrix: TestStageMatrix, is_unit: bool) -> None:
        if 'pytest_config' not in test_matrix or test_matrix['pytest_config'] is None:
            return

        pytest_config = test_matrix['pytest_config']
        pytest_dict = pytest_config.to_dict(is_unit)
        if 'test_acouchbase_api' in matrix_dict and matrix_dict['test_acouchbase_api'] is True:
            if 'pytest' not in matrix_dict:
                matrix_dict['pytest'] = {}
            matrix_dict['pytest'].update(
                {
                    'acouchbase_cmd': pytest_dict['acouchbase_cmd'],
                    'acouchbase_opts': pytest_dict['acouchbase_opts'],
                }
            )
        if 'test_couchbase_api' in matrix_dict and matrix_dict['test_couchbase_api'] is True:
            if 'pytest' not in matrix_dict:
                matrix_dict['pytest'] = {}
            matrix_dict['pytest'].update(
                {
                    'couchbase_cmd': pytest_dict['couchbase_cmd'],
                    'couchbase_opts': pytest_dict['couchbase_opts'],
                }
            )

    @staticmethod
    def _stage_matrix_as_dict(stage: str, stage_matrix: Union[StageMatrix, TestStageMatrix]) -> Dict[str, Any]:  # noqa: C901
        matrix_dict: Dict[str, Any] = {}
        if 'linux' in stage_matrix and stage_matrix['linux'] is not None:
            matrix_dict['linux'] = {}
            for k, v in stage_matrix['linux'].items():
                if k == 'linux_type':
                    matrix_dict['linux']['linux-type'] = v
                elif k == 'python_version':
                    matrix_dict['linux']['python-version'] = v
                else:
                    matrix_dict['linux'][k] = v
        if 'alpine' in stage_matrix and stage_matrix['alpine'] is not None:
            matrix_dict['alpine'] = {}
            for k, v in stage_matrix['alpine'].items():
                if k == 'linux_type':
                    matrix_dict['alpine']['linux-type'] = v
                elif k == 'python_version':
                    matrix_dict['alpine']['python-version'] = v
                else:
                    matrix_dict['alpine'][k] = v
        if 'macos' in stage_matrix and stage_matrix['macos'] is not None:
            matrix_dict['macos'] = {}
            for k, v in stage_matrix['macos'].items():
                if k == 'python_version':
                    matrix_dict['macos']['python-version'] = v
                else:
                    matrix_dict['macos'][k] = v
        if 'windows' in stage_matrix and stage_matrix['windows'] is not None:
            matrix_dict['windows'] = {}
            for k, v in stage_matrix['windows'].items():
                if k == 'python_version':
                    matrix_dict['windows']['python-version'] = v
                else:
                    matrix_dict['windows'][k] = v
        matrix_dict['has_linux'] = stage_matrix.get('has_linux', False)
        matrix_dict['has_alpine'] = stage_matrix.get('has_alpine', False)
        matrix_dict['has_macos'] = stage_matrix.get('has_macos', False)
        matrix_dict['has_windows'] = stage_matrix.get('has_windows', False)
        if stage == 'test_unit':
            sdk_project = SdkProject.from_env()
            test_matrix = cast(TestStageMatrix, stage_matrix)
            # TODO: this is a possibility, but the matrix becomes rather large (>= 60)
            # add_test_config_to_stage_matrix(matrix_dict, test_matrix, sdk_project)
            StageMatrixConfigHandler._add_apis_and_install_type_to_stage_matrix(matrix_dict, test_matrix, sdk_project)
            StageMatrixConfigHandler._add_install_command(matrix_dict)
            StageMatrixConfigHandler._add_pytest_config(matrix_dict, test_matrix, is_unit=True)
        elif stage == 'test_integration':
            sdk_project = SdkProject.from_env()
            test_matrix = cast(TestStageMatrix, stage_matrix)
            matrix_dict['skip_cbdino'] = test_matrix.get('skip_cbdino', False)
            matrix_dict['skip_integration'] = test_matrix.get('skip_integration', False)
            matrix_dict['has_linux_cbdino'] = test_matrix.get('has_linux_cbdino', False)
            # TODO: this is a possibility, but the matrix becomes rather large (>= 60)
            # add_test_config_to_stage_matrix(matrix_dict, test_matrix, sdk_project)
            StageMatrixConfigHandler._add_apis_and_install_type_to_stage_matrix(matrix_dict, test_matrix, sdk_project)
            StageMatrixConfigHandler._add_cbdino_config_to_stage_matrix(matrix_dict, test_matrix)
            StageMatrixConfigHandler._add_install_command(matrix_dict)
            StageMatrixConfigHandler._add_pytest_config(matrix_dict, test_matrix, is_unit=False)
            test_config = test_matrix.get('test_config', None)
            if test_config is not None:
                matrix_dict['test_config'] = test_config.to_dict(sdk_project)
        return matrix_dict

    @staticmethod
    def build_linux_stage_matrix(
        python_versions: List[str],
        x86_64_platforms: List[str],
        arm64_platforms: List[str],
        stage: ConfigStage,
        is_alpine: bool,
    ) -> LinuxStageMatrix:
        linux_matrix: LinuxStageMatrix = {}
        if stage in [ConfigStage.BUILD_WHEEL, ConfigStage.TEST_UNIT, ConfigStage.TEST_INTEGRATION]:
            if is_alpine:
                return StageMatrixConfigHandler._build_linux_alpine_stage_matrix(
                    python_versions, x86_64_platforms, arm64_platforms
                )
            return StageMatrixConfigHandler._build_linux_stage_matrix_new(
                python_versions, x86_64_platforms, arm64_platforms
            )
        elif stage == ConfigStage.VALIDATE_WHEEL:
            if is_alpine:
                return StageMatrixConfigHandler._build_linux_alpine_validate_wheel_stage_matrix(
                    python_versions, x86_64_platforms, arm64_platforms
                )
            return StageMatrixConfigHandler._build_linux_validate_wheel_stage_matrix(
                python_versions, x86_64_platforms, arm64_platforms
            )

        return linux_matrix

    @staticmethod
    def build_macos_stage_matrix(  # noqa: C901
        python_versions: List[str],
        x86_64_platforms: List[str],
        arm64_platforms: List[str],
        stage: ConfigStage,
    ) -> MacosStageMatrix:
        macos_matrix: MacosStageMatrix = {}
        if stage in [ConfigStage.BUILD_WHEEL, ConfigStage.TEST_UNIT, ConfigStage.TEST_INTEGRATION]:
            if 'macos' in x86_64_platforms:
                macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
                macos_matrix['os'] = [macos_plat]
                macos_matrix['arch'] = ['x86_64']
            if 'macos' in arm64_platforms:
                macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
                if 'os' not in macos_matrix or macos_matrix['os'] is None:
                    macos_matrix['os'] = [macos_plat]
                else:
                    macos_matrix['os'].append(macos_plat)
                if 'arch' not in macos_matrix:
                    macos_matrix['arch'] = ['arm64']
                else:
                    macos_matrix['arch'].append('arm64')

            if macos_matrix:
                macos_matrix['python_version'] = python_versions
                if 'arm64' in macos_matrix['arch'] and 'x86_64' in macos_matrix['arch']:
                    macos_x86_64_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
                    macos_arm64_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
                    macos_matrix['exclude'] = [
                        {'os': macos_x86_64_plat, 'arch': 'arm64'},
                        {'os': macos_arm64_plat, 'arch': 'x86_64'},
                    ]
        elif stage == ConfigStage.VALIDATE_WHEEL:
            if 'macos' in x86_64_platforms:
                macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
                macos_matrix['os'] = [macos_plat]
            if 'macos' in arm64_platforms:
                macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
                if 'os' not in macos_matrix or macos_matrix['os'] is None:
                    macos_matrix['os'] = [macos_plat]
                else:
                    macos_matrix['os'].append(macos_plat)
            if macos_matrix:
                macos_matrix['python_version'] = python_versions

        return macos_matrix

    @staticmethod
    def build_windows_stage_matrix(
        python_versions: List[str], x86_64_platforms: List[str], arm64_platforms: List[str], stage: ConfigStage
    ) -> WindowsStageMatrix:
        windows_matrix: WindowsStageMatrix = {}
        if stage in [
            ConfigStage.BUILD_WHEEL,
            ConfigStage.VALIDATE_WHEEL,
            ConfigStage.TEST_UNIT,
            ConfigStage.TEST_INTEGRATION,
        ]:
            if 'windows' in x86_64_platforms:
                windows_plat = get_env_variable('CBCI_DEFAULT_WINDOWS_PLATFORM')
                windows_matrix['os'] = [windows_plat]
                windows_matrix['arch'] = ['AMD64']

            if windows_matrix:
                windows_matrix['python_version'] = python_versions

        return windows_matrix

    @staticmethod
    def build_stage_matrices(
        python_versions: List[str],
        x86_64_platforms: List[str],
        arm64_platforms: List[str],
        test_config: TestConfig,
        pytest_config: PytestConfig,
    ) -> Dict[str, Union[StageMatrix, TestStageMatrix]]:
        matrices: Dict[str, StageMatrix] = {}
        sdk_project = SdkProject.from_env()
        if sdk_project == SdkProject.Analytics:
            stages = [ConfigStage.TEST_UNIT, ConfigStage.TEST_INTEGRATION]
        else:
            stages = [
                ConfigStage.BUILD_WHEEL,
                ConfigStage.VALIDATE_WHEEL,
                ConfigStage.TEST_UNIT,
                ConfigStage.TEST_INTEGRATION,
            ]
        for stage in stages:
            stage_matrix: StageMatrix = {}

            linux_matrix = StageMatrixConfigHandler.build_linux_stage_matrix(
                python_versions, x86_64_platforms, arm64_platforms, stage, False
            )
            if linux_matrix:
                stage_matrix['linux'] = linux_matrix
                stage_matrix['has_linux'] = True
            else:
                stage_matrix['has_linux'] = False
            alpine_matrix = StageMatrixConfigHandler.build_linux_stage_matrix(
                python_versions, x86_64_platforms, arm64_platforms, stage, True
            )
            if alpine_matrix:
                stage_matrix['alpine'] = alpine_matrix
                stage_matrix['has_alpine'] = True
            else:
                stage_matrix['has_alpine'] = False
            macos_matrix = StageMatrixConfigHandler.build_macos_stage_matrix(
                python_versions, x86_64_platforms, arm64_platforms, stage
            )
            if macos_matrix:
                stage_matrix['macos'] = macos_matrix
                stage_matrix['has_macos'] = True
            else:
                stage_matrix['has_macos'] = False
            windows_matrix = StageMatrixConfigHandler.build_windows_stage_matrix(
                python_versions, x86_64_platforms, arm64_platforms, stage
            )
            if windows_matrix:
                stage_matrix['windows'] = windows_matrix
                stage_matrix['has_windows'] = True
            else:
                stage_matrix['has_windows'] = False

            stage_name = stage.get_stage_name()
            if stage == ConfigStage.TEST_UNIT:
                unit_test_matrix: TestStageMatrix = cast(TestStageMatrix, deepcopy(stage_matrix))
                unit_test_matrix['api'] = test_config.apis
                unit_test_matrix['install_type'] = test_config.install_types
                unit_test_matrix['pytest_config'] = pytest_config
                matrices[stage_name] = unit_test_matrix
            elif stage == ConfigStage.TEST_INTEGRATION:
                int_test_matrix: TestStageMatrix = cast(TestStageMatrix, deepcopy(stage_matrix))
                StageMatrixConfigHandler._build_integration_test_stage_matrix(
                    int_test_matrix, test_config, pytest_config
                )
                matrices[stage_name] = int_test_matrix
            else:
                matrices[stage_name] = stage_matrix

        return matrices

    @staticmethod
    def get_stage_matrices(config_key: str, quiet: Optional[bool] = True) -> None:
        config, test_config, _, pytest_config = UserConfigHandler.parse_user_config(config_key, quiet=quiet)
        matrices = StageMatrixConfigHandler.build_stage_matrices(
            config['python_versions'], config['x86_64_platforms'], config['arm64_platforms'], test_config, pytest_config
        )
        gha_matrices = {k: StageMatrixConfigHandler._stage_matrix_as_dict(k, v) for k, v in matrices.items()}
        print(f'{json.dumps(gha_matrices)}')


class TestConfigHandler:
    @staticmethod
    def _get_analytics_test_ini_output(test_config: TestConfig) -> str:
        cbdino_connstr = get_env_variable('CBDC_CONNSTR', quiet=True)
        if cbdino_connstr is not None:
            parsed_endpoint = urlparse(cbdino_connstr)
            scheme = parsed_endpoint.scheme
            env_host = os.environ.get('PYCBAC_HOST', test_config.host or '127.0.0.1')
            host = parsed_endpoint.hostname if parsed_endpoint.hostname is not None else env_host
            env_port = os.environ.get('PYCBAC_PORT', test_config.port or '18095')
            port = str(parsed_endpoint.port) if parsed_endpoint.port is not None else env_port
        else:
            scheme = os.environ.get('PYCBAC_SCHEME', test_config.scheme or 'https')
            host = os.environ.get('PYCBAC_HOST', test_config.host or '127.0.0.1')
            port = os.environ.get('PYCBAC_PORT', test_config.port or '18095')

        username = os.environ.get('PYCBAC_USERNAME', test_config.username or 'Administrator')
        password = os.environ.get('PYCBAC_PASSWORD', test_config.password or 'password')
        fqdn = os.environ.get('PYCBAC_FQDN', test_config.fqdn)
        if test_config.nonprod is not None:
            nonprod = 'ON' if test_config.nonprod else 'OFF'
        else:
            nonprod = os.environ.get('PYCBAC_NONPROD', 'OFF')
        if test_config.tls_verify is not None:
            tls_verify = 'ON' if test_config.tls_verify else 'OFF'
        else:
            tls_verify = os.environ.get('PYCBAC_TLS_VERIFY', 'ON')

        output = [
            '[analytics]',
            f'scheme = {scheme}',
            f'host = {host}',
            f'port = {port}',
            f'username = {username}',
            f'password = {password}',
            f'nonprod = {get_config_boolean_as_str(nonprod)}',
            f'tls_verify = {get_config_boolean_as_str(tls_verify)}',
        ]
        if fqdn is not None:
            output.append(f'fqdn = {fqdn}')
        output.append('')

        return '\n'.join(output)

    @staticmethod
    def _get_columnar_test_ini_output() -> str:
        scheme = os.environ.get('PYCBCC_SCHEME', 'couchbases')
        host = os.environ.get('PYCBCC_HOST', 'localhost')
        port = os.environ.get('PYCBCC_PORT', '8091')
        username = os.environ.get('PYCBCC_USERNAME', 'Administrator')
        password = os.environ.get('PYCBCC_PASSWORD', 'password')
        fqdn = os.environ.get('PYCBCC_FQDN', None)
        nonprod = os.environ.get('PYCBCC_NONPROD', 'on')
        tls_verify = os.environ.get('PYCBCC_TLS_VERIFY', 'on')

        output = [
            '[columnar]',
            f'scheme = {scheme}',
            f'host = {host}',
            f'port = {port}',
            f'username = {username}',
            f'password = {password}',
            f'nonprod = {get_config_boolean_as_str(nonprod)}',
            f'tls_verify = {get_config_boolean_as_str(tls_verify)}',
        ]
        if fqdn is not None:
            output.append(f'fqdn = {fqdn}')
        output.append('')

        return '\n'.join(output)

    @staticmethod
    def _get_operational_test_ini_output() -> str:
        host = os.environ.get('PYCBC_HOST', '127.0.0.1')
        port = os.environ.get('PYCBC_PORT', '8091')
        username = os.environ.get('PYCBC_USERNAME', 'Administrator')
        password = os.environ.get('PYCBC_PASSWORD', 'password')
        bucket_name = os.environ.get('PYCBC_BUCKET_NAME', 'default')

        output = [
            '[realserver]',
            f'enabled = Truehost = {host}',
            f'port = {port}',
            f'username = {username}',
            f'password = {password}',
            f'bucket_name = {bucket_name}',
            '',
            '[gocaves]',
            'enabled = False',
        ]
        output.append('')

        return '\n'.join(output)

    @staticmethod
    def build_pytest_ini(pyproject_path: str, output_path: str) -> None:  # noqa: C901
        import tomli  # type: ignore[import-not-found]

        pyproject_data = None
        try:
            with open(pyproject_path, 'rb') as f:
                pyproject_data = tomli.load(f)
        except tomli.TOMLDecodeError as e:
            print(f"Error: Failed to parse pyproject.toml at '{pyproject_path}'. Invalid TOML format: {e}")
            return

        if pyproject_data is None:
            print(f"Error: Failed to read pyproject.toml at '{pyproject_path}'.")
            return

        valid_pytest_config = (
            'tool' in pyproject_data
            and 'pytest' in pyproject_data['tool']
            and 'ini_options' in pyproject_data['tool']['pytest']
            and isinstance(pyproject_data['tool']['pytest']['ini_options'], dict)
        )

        if not valid_pytest_config:
            print("No pytest configuration found in pyproject.toml under 'tool.pytest.ini_options'.")
            return

        sdk_project = SdkProject.from_env()
        pytest_data = pyproject_data['tool']['pytest']['ini_options']

        output = [
            '[pytest]',
            f'minversion = {pytest_data.get("minversion")}',
            'testpaths =',
        ]

        for test in pytest_data.get('testpaths'):
            if sdk_project == SdkProject.Analytics:
                if test.startswith('acouchbase_analytics'):
                    output.append(f'    {test.replace("acouchbase_analytics", "acb")}')
                elif test.startswith('couchbase_analytics'):
                    output.append(f'    {test.replace("couchbase_analytics", "cb")}')
                else:
                    output.append(f'    {test}')
            elif sdk_project == SdkProject.Columnar:
                if test.startswith('acouchbase_columnar'):
                    output.append(f'    {test.replace("acouchbase_columnar", "acb")}')
                elif test.startswith('couchbase_columnar'):
                    output.append(f'    {test.replace("couchbase_columnar", "cb")}')
                else:
                    output.append(f'    {test}')
            elif sdk_project == SdkProject.Operational:
                if test.startswith('acouchbase'):
                    output.append(f'    {test.replace("acouchbase", "acb")}')
                elif test.startswith('couchbase'):
                    output.append(f'    {test.replace("couchbase", "cb")}')
                elif test.startswith('txcouchbase'):
                    output.append(f'    {test.replace("txcouchbase", "txcb")}')
                else:
                    output.append(f'    {test}')

        keys = ['python_classes', 'python_files', 'markers']
        for k in keys:
            if isinstance(pytest_data[k], list):
                if len(pytest_data[k]) > 1:
                    output.append(f'{k} =')
                    output.append('\n'.join(f'    {p}' for p in pytest_data[k]))
                else:
                    output.append(f'{k} = {pytest_data[k][0]}')
            else:
                output.append(f'{k} = {pytest_data[k]}')
        output.append('')

        with open(os.path.join(output_path, 'pytest.ini'), 'w') as outfile:
            outfile.write('\n'.join(output))

    @staticmethod
    def build_test_ini(output_path: str) -> None:
        sdk_project = SdkProject.from_env()
        user_config = UserConfigHandler.user_config_as_json('CBCI_CONFIG')
        test_config = UserConfigHandler.parse_user_test_config(user_config)
        output = None
        if sdk_project == SdkProject.Analytics:
            output = TestConfigHandler._get_analytics_test_ini_output(test_config)
        if sdk_project == SdkProject.Columnar:
            output = TestConfigHandler._get_columnar_test_ini_output()
        elif sdk_project == SdkProject.Operational:
            output = TestConfigHandler._get_operational_test_ini_output()

        if output is None:
            print('Unable to build test config.')
            sys.exit(1)

        with open(os.path.join(output_path, 'test_config.ini'), 'w') as outfile:
            outfile.write(output)

    @staticmethod
    def build_test_requirements_file(output_path: str) -> None:  # noqa: C901
        sdk_project = SdkProject.from_env()
        req_file = None
        reqs = []
        if sdk_project == SdkProject.Analytics:
            req_file = 'requirements-dev.in'
            reqs = ['aiohttp', 'pytest']
        if sdk_project == SdkProject.Columnar:
            req_file = 'dev_requirements.txt'
            reqs = ['pytest', 'pytest-asyncio', 'pytest-rerunfailures', 'requests']
        elif sdk_project == SdkProject.Operational:
            req_file = 'dev_requirements.txt'
            reqs = ['pytest', 'pytest-asyncio', 'pytest-rerunfailures', 'requests', 'Faker', 'faker-vehicle', 'Twisted']

        if req_file is None:
            print('Unable to find dev requirements file.')
            sys.exit(1)

        if not os.path.exists(req_file):
            print(f'Requirements file {req_file} does not exist.')
            sys.exit(1)

        final_reqs = []
        lines = []
        with open(req_file, 'r') as infile:
            for line in infile.readlines():
                if line and not line.startswith('#'):
                    lines.append(line.strip())

        separators = ['=', '~', '>', '<', '!=']
        pattern = '|'.join(map(re.escape, separators))

        for req in reqs:
            for line in lines:
                tokens = re.split(pattern, line)
                # handle "nested" cases like pytest and pytest-asyncio
                match = not ('-' not in req and '-' in tokens[0]) and tokens[0].startswith(req)
                if match:
                    final_reqs.append(line)

        if not reqs:
            final_reqs = lines
        final_reqs.append('')

        with open(os.path.join(output_path, 'requirements-test.txt'), 'w') as outfile:
            outfile.write('\n'.join(final_reqs))

    @staticmethod
    def get_install_command() -> Optional[str]:
        install_cmd = None
        packaging_index = get_env_variable('CBCI_PACKAGING_INDEX', quiet=True)
        if packaging_index is None:
            return install_cmd
        if packaging_index.upper() == 'TEST_PYPI':
            install_cmd = 'install -i https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple'
        elif packaging_index.upper() == 'PYPI':
            install_cmd = 'install'

        return install_cmd


class UserConfigHandler:
    @staticmethod
    def _process_apis(cfg: Dict[str, Any], sdk_project: SdkProject) -> List[str]:
        user_apis: Optional[Union[str, List[str]]] = cfg.get('apis', None)
        if user_apis is not None:
            if isinstance(user_apis, str):
                return user_apis.split()
            return user_apis

        env_apis = get_env_variable('CBCI_APIS', quiet=True)
        if env_apis is not None:
            return env_apis.split()

        return SdkProject.get_default_apis(sdk_project)

    @staticmethod
    def _process_install_types(cfg: Dict[str, Any]) -> List[str]:
        user_install_types: Optional[Union[str, List[str]]] = cfg.get('install_types', None)
        if user_install_types is not None:
            if isinstance(user_install_types, str):
                return user_install_types.split()
            return user_install_types

        env_install_types = get_env_variable('CBCI_INSTALL_TYPES', quiet=True)
        if env_install_types is not None:
            return env_install_types.split()

        return ['sdist', 'wheel']

    @staticmethod
    def _process_skip_cbdino(cfg: Dict[str, Any]) -> bool:
        skip_cbdino = False
        # check if set via CBCI_SKIP_CBDINO
        skip_cbdino_env = get_env_variable('CBCI_SKIP_CBDINO', quiet=True)
        if skip_cbdino_env is not None:
            skip_cbdino = bool(get_config_boolean_as_str(skip_cbdino_env))
        # user config has final say
        if 'skip_cbdino' in cfg:
            skip_cbdino = bool(cfg['skip_cbdino'])
        elif 'skip-cbdino' in cfg:
            skip_cbdino = bool(cfg['skip-cbdino'])

        return skip_cbdino

    @staticmethod
    def _process_skip_integration(cfg: Dict[str, Any]) -> bool:
        skip_integration = False
        # check if set via CBCI_SKIP_INTEGRATION
        skip_integration_env = get_env_variable('CBCI_SKIP_INTEGRATION', quiet=True)
        if skip_integration_env is not None:
            skip_integration = bool(get_config_boolean_as_str(skip_integration_env))
        # user config has final say
        if 'skip_integration' in cfg:
            skip_integration = bool(cfg['skip_integration'])
        elif 'skip-integration' in cfg:
            skip_integration = bool(cfg['skip-integration'])

        return skip_integration

    @staticmethod
    def _process_test_config(cfg: Dict[str, Any], sdk_project: SdkProject) -> Dict[str, str]:
        config_keys = SdkProject.get_test_config_keys(sdk_project)
        test_config: Dict[str, str] = {}
        for k, v in cfg.items():
            if k not in config_keys:
                continue
            if k in ['nonprod', 'tls_verify']:
                test_config[k] = get_config_boolean_as_str(v)
            else:
                test_config[k] = v

        return test_config

    @staticmethod
    def parse_user_config(
        config_key: str, quiet: Optional[bool] = True, version_key: Optional[str] = None
    ) -> Tuple[Dict[str, List[str]], TestConfig, PublishConfig, PytestConfig]:
        user_config = UserConfigHandler.user_config_as_json(config_key)
        cfg = {}
        versions = ConfigHandler.set_python_versions(
            user_config.get('python_versions', user_config.get('python-versions', '')), quiet=quiet
        )
        if versions:
            cfg['python_versions'] = versions
        else:
            cfg['python_versions'] = ConfigHandler.get_supported_python_versions()

        user_platforms = user_config.get('platforms', '')
        user_arches = user_config.get('arches', '')
        x86_64_platforms, arm64_platforms = ConfigHandler.set_os_and_arch(user_platforms, user_arches, quiet=quiet)
        cfg['x86_64_platforms'] = x86_64_platforms
        cfg['arm64_platforms'] = arm64_platforms
        test_config = UserConfigHandler.parse_user_test_config(user_config)
        publish_config = UserConfigHandler.parse_user_publish_config(user_config, version_key=version_key)
        pytest_config = UserConfigHandler.parse_user_pytest_config(user_config)
        return cfg, test_config, publish_config, pytest_config

    @staticmethod
    def parse_user_publish_config(cfg: Dict[str, Any], version_key: Optional[str] = None) -> PublishConfig:  # noqa: C901
        publish_config = PublishConfig.get_default_publish_config()
        version_key = version_key or 'CBCI_VERSION'
        config_version = get_env_variable(version_key, quiet=True)
        if config_version is not None:
            publish_config.set_git_tag = config_version
        tests_run_id = get_env_variable('CBCI_TESTS_RUN_ID', quiet=True)
        if tests_run_id is not None:
            publish_config.tests_run_id = tests_run_id
        if 'publish_config' not in cfg and 'publish-config' not in cfg:
            return publish_config

        publish_cfg = cfg.get('publish_config', cfg.get('publish-config', None))
        if not isinstance(publish_cfg, dict):
            return publish_config
        if 'publish_test_pypi' in publish_cfg or 'publish-test-pypi' in publish_cfg:
            pub_test_pypi = publish_cfg.get('publish_test_pypi', publish_cfg.get('publish-test-pypi', True))
            if isinstance(pub_test_pypi, (bool, str)):
                publish_config.publish_test_pypi = get_config_boolean(pub_test_pypi)
        if 'publish_pypi' in publish_cfg or 'publish-pypi' in publish_cfg:
            pub_pypi = publish_cfg.get('publish_pypi', publish_cfg.get('publish-pypi', True))
            if isinstance(pub_pypi, (bool, str)):
                publish_config.publish_pypi = get_config_boolean(pub_pypi)
        if 'publish_api_docs' in publish_cfg or 'publish-api-docs' in publish_cfg:
            pub_api_docs = publish_cfg.get('publish_api_docs', publish_cfg.get('publish-api-docs', True))
            if isinstance(pub_api_docs, (bool, str)):
                publish_config.publish_api_docs = get_config_boolean(pub_api_docs)
        if 'publish_dry_run' in publish_cfg or 'publish-dry-run' in publish_cfg:
            pub_dry_run = publish_cfg.get('publish_dry_run', publish_cfg.get('publish-dry-run', False))
            if isinstance(pub_dry_run, (bool, str)):
                publish_config.publish_dry_run = get_config_boolean(pub_dry_run)
        else:
            publish_dry_run = get_env_variable('CBCI_PUBLISH_DRY_RUN', quiet=True)
            if publish_dry_run is not None:
                publish_config.publish_dry_run = get_config_boolean(publish_dry_run)

        return publish_config

    @staticmethod
    def parse_user_pytest_config(cfg: Dict[str, Any]) -> PytestConfig:  # noqa: C901
        sdk_project = SdkProject.from_env()
        pytest_config = PytestConfig.get_default_pytest_config(sdk_project)
        if 'pytest_config' not in cfg and 'pytest-config' not in cfg:
            return pytest_config
        pytest_cfg = cfg.get('pytest_config', cfg.get('pytest-config', None))
        if not isinstance(pytest_cfg, dict):
            return pytest_config

        global_cfg = PytestConfig.get_config_options(pytest_cfg, sdk_project)
        if 'unit' in pytest_cfg and isinstance(pytest_cfg['unit'], dict):
            unit_cfg = PytestConfig.get_config_options(pytest_cfg['unit'], sdk_project)
        else:
            unit_cfg = {}

        for cfg_key in PytestConfig.get_config_keys():
            if cfg_key in unit_cfg:
                setattr(pytest_config.unit_config, cfg_key, unit_cfg[cfg_key])
            elif cfg_key in global_cfg:
                setattr(pytest_config.unit_config, cfg_key, global_cfg[cfg_key])

        if 'integration' in pytest_cfg and isinstance(pytest_cfg['integration'], dict):
            int_cfg = PytestConfig.get_config_options(pytest_cfg['integration'], sdk_project)
        else:
            int_cfg = {}

        for cfg_key in PytestConfig.get_config_keys():
            if cfg_key in int_cfg:
                setattr(pytest_config.integration_config, cfg_key, int_cfg[cfg_key])
            elif cfg_key in global_cfg:
                setattr(pytest_config.integration_config, cfg_key, global_cfg[cfg_key])

        return pytest_config

    @staticmethod
    def parse_user_test_config(cfg: Dict[str, Any]) -> TestConfig:
        sdk_project = SdkProject.from_env()
        cbdino_config: Optional[CbdinoConfig] = None

        skip_cbdino = UserConfigHandler._process_skip_cbdino(cfg)
        if skip_cbdino is False:
            cbd_cfg = cfg.get('cbdino_config', cfg.get('cbdino-config', None))
            cbdino_config = CbDinoConfigHandler.build_cbdino_config(sdk_project, cbd_cfg)

        skip_integration = UserConfigHandler._process_skip_integration(cfg)
        apis = UserConfigHandler._process_apis(cfg, sdk_project)
        install_types = UserConfigHandler._process_install_types(cfg)

        if skip_integration is True:
            return TestConfig(
                skip_integration, skip_cbdino, cbdino_config=cbdino_config, apis=apis, install_types=install_types
            )

        test_cfg = cfg.get('test_config', cfg.get('test-config', None))
        if not isinstance(test_cfg, dict):
            return TestConfig(True, skip_cbdino, cbdino_config=cbdino_config, apis=apis, install_types=install_types)

        test_config = UserConfigHandler._process_test_config(test_cfg, sdk_project)
        return TestConfig.create_from_config(
            skip_integration,
            skip_cbdino,
            apis=apis,
            install_types=install_types,
            cbdino_config=cbdino_config,
            **test_config,
        )

    @staticmethod
    def user_config_as_json(config_key: str) -> Dict[str, Any]:
        config_str = get_env_variable(config_key, quiet=True)
        config = {}
        if config_str:
            # for GHA linux, we pass the JSON config as a string into the docker container
            if config_str.startswith('"'):
                config_str = config_str[1:-1]
            try:
                config = json.loads(config_str)
            except Exception as e:
                print(f'Invalid JSON: {e}')
                sys.exit(1)

        return config


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Expected more input args. Got {sys.argv[1:]}.')
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'parse_sdist_config':
        ConfigHandler.parse_config(ConfigStage.BUILD_SDIST, sys.argv[2])
    elif cmd == 'get_stage_matrices':
        StageMatrixConfigHandler.get_stage_matrices(sys.argv[2])
    elif cmd == 'parse_wheel_config':
        ConfigHandler.parse_config(ConfigStage.BUILD_WHEEL, sys.argv[2])
    elif cmd == 'parse_wheel_name':
        parse_wheel_name(sys.argv[2], sys.argv[3])
    elif cmd == 'build_test_ini':
        TestConfigHandler.build_test_ini(sys.argv[2])
    elif cmd == 'build_dev_requirements':
        TestConfigHandler.build_test_requirements_file(sys.argv[2])
    elif cmd == 'build_pytest_ini':
        if len(sys.argv) < 4:
            print('Expected pyproject path and output path.')
            sys.exit(1)
        TestConfigHandler.build_pytest_ini(sys.argv[2], sys.argv[3])
    elif cmd == 'build_cbdino_config_yaml':
        CbDinoConfigHandler.build_cbdino_config_yaml(sys.argv[2])
    elif cmd == 'build_publish_config':
        if len(sys.argv) < 4:
            print('Expected config key and version key.')
            sys.exit(1)
        PublishConfigHandler.build_publish_config(sys.argv[2], sys.argv[3])
    else:
        print(f'Invalid command: {cmd}')
        sys.exit(1)
