from __future__ import annotations

import certifi
import functools
import json
import os
import pathlib
import platform
import socket
import ssl
import sys
import time
from subprocess import (STDOUT,
                        Popen,
                        call)
from typing import (Callable,
                    Optional,
                    Tuple)
from urllib.request import urlopen
from uuid import uuid4

from couchbase.auth import PasswordAuthenticator
from couchbase.cluster import Cluster
from couchbase.exceptions import (AmbiguousTimeoutException,
                                  DocumentExistsException,
                                  DocumentNotFoundException,
                                  UnAmbiguousTimeoutException)
from couchbase.options import ClusterOptions


class CavesMockServer:
    def __init__(self,
                 caves_path=None,  # type: Optional[str]
                 caves_url=None,  # type: Optional[str]
                 caves_version=None,  # type: Optional[str]
                 log_filename=None,  # type: Optional[str]
                 ):

        if caves_url is None:
            caves_url = 'https://github.com/couchbaselabs/gocaves/releases/download'

        self._caves_version = caves_version
        if self._caves_version is None:
            self._caves_version = 'v0.0.1-74'

        self._current_dir = pathlib.Path(__file__).parent

        if log_filename is None:
            self._log_filename = os.path.join(self._current_dir, 'quick_test_logs.txt')
        else:
            self._log_filename = log_filename

        self._build_caves_url(caves_url)
        self._validate_caves_path(caves_path)

    @property
    def connstr(self):
        return self._connstr

    def _build_caves_url(self, url):
        if sys.platform.startswith('linux'):
            linux_arch = 'gocaves-linux-arm64' if platform.machine() == 'aarch64' else 'gocaves-linux-amd64'
            self._caves_url = f"{url}/{self._caves_version}/{linux_arch}"
        elif sys.platform.startswith('darwin'):
            self._caves_url = f"{url}/{self._caves_version}/gocaves-macos"
        elif sys.platform.startswith('win32'):
            self._caves_url = f"{url}/{self._caves_version}/gocaves-windows.exe"
        else:
            raise Exception("Unrecognized platform for running GoCAVES mock server.")

    def _validate_caves_path(self, caves_path=None):
        if not (caves_path and not caves_path.isspace()):
            if sys.platform.startswith('linux'):
                caves_path = 'gocaves-linux-arm64' if platform.machine() == 'aarch64' else 'gocaves-linux-amd64'
            elif sys.platform.startswith('darwin'):
                caves_path = 'gocaves-macos-arm64' if platform.machine() == 'arm64' else 'gocaves-macos'
            elif sys.platform.startswith('win32'):
                caves_path = 'gocaves-windows.exe'

        self._caves_path = os.path.join(self._current_dir, caves_path)

        if not os.path.exists(self._caves_path):
            resp = urlopen(self._caves_url, context=ssl.create_default_context(cafile=certifi.where()))
            with open(self._caves_path, 'wb') as caves_out:
                caves_out.write(resp.read())
            if not sys.platform.startswith('win32'):
                # make executable
                call(['chmod', 'a+x', self._caves_path])

    def _setup_listener(self):
        sock = socket.socket()
        sock.bind(('', 0))
        sock.listen(10)

        _, port = sock.getsockname()
        self._listen = sock
        self._port = port

    def _invoke(self):
        self._setup_listener()
        args = [self._caves_path, f"--control-port={self._port}"]
        self._output_log = open(self._log_filename, 'w')
        self._po = Popen(args, stdout=self._output_log, stderr=STDOUT)
        self._caves_sock, self._caves_addr = self._listen.accept()
        self._rest_port = self._caves_addr[1]

    def _attempt_shutdown(self):
        try:
            self._listen.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        finally:
            self._listen.close()

        try:
            self._caves_sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        finally:
            self._caves_sock.close()

        try:
            self._output_log.close()
            self._po.terminate()
            self._po.kill()
            self._po.communicate()
        except OSError:
            pass

    def start(self):
        self._invoke()
        hello = self._read_command()
        if hello['type'] != 'hello':
            raise Exception("There was a problem, CAVES didn't greet us.")

    def shutdown(self):
        self._attempt_shutdown()

    def create_cluster(self):
        self._cluster_id = str(uuid4())
        res = self._round_trip_command({
            'type': 'createcluster',
            'id': self._cluster_id
        })
        if res is not None:
            self._connstr = res['connstr']
            self._mgmt_addrs = res['mgmt_addrs']

    def _read_command(self):
        result = self._recv()
        return json.loads(result)

    def _write_command(self, cmd):
        cmd_str = json.dumps(cmd)
        cmd_array = bytearray(cmd_str, 'utf-8')
        # append null byte
        cmd_array += b'\x00'
        self._caves_sock.send(bytes(cmd_array))

    def _round_trip_command(self, cmd):
        self._write_command(cmd)
        resp = self._read_command()
        return resp

    def _recv(self, timeout=2, end=b'\x00'):
        self._caves_sock.setblocking(0)
        buf = []
        data = ''
        chunk = 4096
        start = time.time()
        while True:
            # if received data and passed timeout
            # return the received data
            if buf and time.time() - start > timeout:
                break
            # if no data received, allow a bit more time
            elif time.time() - start > timeout * 1.1:
                break

            try:
                data = self._caves_sock.recv(chunk)
                if data:
                    if end and end in data:
                        buf.append(str(data[:len(data)-1], encoding='utf-8'))
                        break

                    buf.append(str(data, encoding='utf-8'))
                    start = time.time()
                else:
                    time.sleep(0.1)
            except Exception:
                pass

        result = ''.join(buf)
        return result


def allow_retries(retry_limit=3,                # type: int
                  backoff=1.0,                  # type: float
                  exponential_backoff=False,    # type: bool
                  linear_backoff=False,         # type: bool
                  allowed_exceptions=None       # type: Optional[Tuple]
                  ) -> Callable:
    def handle_retries(func):
        @functools.wraps(func)
        def func_wrapper(*args, **kwargs):
            delay = backoff
            for retry_num in range(retry_limit):
                try:
                    return func(*args, **kwargs)
                except Exception as ex:
                    if allowed_exceptions is None or not isinstance(ex, allowed_exceptions):
                        raise

                    if retry_num == (retry_limit-1):
                        raise

                    time.sleep(delay)
                    if exponential_backoff is True:
                        delay = backoff*(2**(retry_num+1))
                    elif linear_backoff is True:
                        delay = backoff*(retry_num+1)

                    print(f"Retries left: {retry_limit - (retry_num+1)}")
                    print(f"Backing Off: {delay} seconds")
                    print(f"{retry_num=}")

        return func_wrapper
    return handle_retries


@allow_retries(retry_limit=3,
               backoff=0.5,
               allowed_exceptions=(Exception,))
def create_mock_server(mock_path,  # type: str
                       mock_download_url,  # type: Optional[str]
                       mock_version,  # type: Optional[str]
                       log_filename=None,  # type: Optional[str]
                       ) -> CavesMockServer:

    mock = CavesMockServer(caves_path=mock_path,
                           caves_url=mock_download_url,
                           caves_version=mock_version,
                           log_filename=log_filename)

    try:
        mock.start()
        mock.create_cluster()
    except Exception as ex:
        print('Problem trying to start mock server.')
        raise ex

    return mock


mock_server = create_mock_server(None,
                                 mock_download_url='https://github.com/couchbaselabs/gocaves/releases/download',
                                 mock_version='v0.0.1-78')


@allow_retries(retry_limit=10,
               backoff=0.5,
               linear_backoff=True,
               allowed_exceptions=(AmbiguousTimeoutException, UnAmbiguousTimeoutException))
def run_quick_test():

    bucket_name = 'default'
    username = 'Administrator'
    pw = 'password'

    opts = ClusterOptions(PasswordAuthenticator(username, pw))
    cluster = Cluster.connect(mock_server.connstr, opts)
    bucket = cluster.bucket(bucket_name)
    collection = bucket.default_collection()

    key = "test-key"
    doc = {
        "a": "aa",
        "b": 1,
        "c": ["Hello,", "World!"],
        "d": {"e": "fgh"},
        "what": "insert"
    }

    try:
        collection.remove(key)
    except DocumentNotFoundException:
        pass

    res = collection.insert(key, doc)
    assert res.cas is not None

    res = collection.get(key)
    assert res.content_as[dict] == doc

    raised_exception = False
    try:
        collection.insert(key, doc)
    except DocumentExistsException:
        raised_exception = True

    assert raised_exception is True

    doc["what"] = "upsert"
    res = collection.upsert(key, doc)
    assert res.cas is not None

    res = collection.get(key)
    assert res.content_as[dict] == doc

    doc["what"] = "replace"
    res = collection.replace(key, doc)
    assert res.cas is not None

    res = collection.get(key)
    assert res.content_as[dict] == doc

    res = collection.remove(key)
    assert res.cas is not None

    raised_exception = False
    try:
        collection.remove(key)
    except DocumentNotFoundException:
        raised_exception = True

    assert raised_exception is True

    cluster.close()
    mock_server.shutdown()


if __name__ == "__main__":
    run_quick_test()
