import os

def get_config_boolean(config_value) -> str:
    if config_value.lower() in ['true', '1', 'y', 'yes', 'on']:
       return 'True'
    else:
        return 'False'

def build_config() -> None:
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
        f'nonprod = {get_config_boolean(nonprod)}',
        f'tls_verify = {get_config_boolean(tls_verify)}'
    ]
    if fqdn is not None:
        output.append(f'fqdn = {fqdn}')
    output.append('')

    with open('test_config.ini', 'w') as outfile:
        outfile.write('\n'.join(output))


if __name__ == '__main__':
    build_config()