import pathlib
from typing import List
import socket
from subprocess import Popen
from urllib.request import urlopen
import select

from couchbase.cluster import Cluster, ClusterOptions
from couchbase.auth import ClassicAuthenticator
from couchbase.exceptions import DocumentExistsException, DocumentNotFoundException


class MockCouchbaseServerBucketSpec():
    def __init__(self,  # type: "MockCouchbaseServerBucketSpec"
                 name='default',  # type: str
                 bucket_type='couchbase',  # type: str
                 password='',  # type: str
                 ):
        self._name = name
        self._bucket_type = bucket_type
        self._password = password

    def __str__(self):
        return ':'.join([self._name, self._password, self._bucket_type])


class CouchbaseMockServerException(Exception):
    pass


class MockCouchbaseServer():

    _BASEDIR = pathlib.Path(__file__).parent

    def __init__(self,  # type: "MockCouchbaseServer"
                 buckets,  # type: List[MockCouchbaseServerBucketSpec]
                 replicas=None,  # type: int
                 vbuckets=None,  # type: int
                 nodes=4  # type: int
                 ):
        """
        Creates a new instance of the mock server. You must actually call
        'start()' for it to be invoked.
        :param list buckets: A list of BucketSpec items
        :param string runpath: a string pointing to the location of the mock
        :param string url: The URL to use to download the mock. This is only
          used if runpath does not exist
        :param int replicas: How many replicas should each bucket have
        :param int vbuckets: How many vbuckets should each bucket have
        :param int nodes: How many total nodes in the cluster

        Note that you must have ``java`` in your `PATH`
        """

        self._runpath = str(self._BASEDIR.joinpath("CouchbaseMock-LATEST.jar"))
        self._url = "http://packages.couchbase.com/clients/c/mock/CouchbaseMock-LATEST.jar"
        self._validate_jar()
        self._buckets = buckets
        self._nodes = nodes
        self._vbuckets = vbuckets
        self._replicas = replicas

    @property
    def rest_port(self):
        return self._rest_port

    def _validate_jar(self):
        if not self._url:
            raise CouchbaseMockServerException("No mock server URL specified.")
        fp = open(self._runpath, "wb")
        ulp = urlopen(self._url)
        jarblob = ulp.read()
        fp.write(jarblob)
        fp.close()

    def _setup_listener(self):
        sock = socket.socket()
        sock.bind(('', 0))
        sock.listen(5)

        _, port = sock.getsockname()
        self._listen = sock
        self._port = port

    def _invoke(self):
        self._setup_listener()
        args = [
            "java", "-client", "-jar", self._runpath,
            "--port", "0", "--with-beer-sample",
            "--harakiri-monitor", "127.0.0.1:" + str(self._port),
            "--nodes", str(self._nodes)
        ]

        if self._vbuckets is not None:
            args += ["--vbuckets", str(self._vbuckets)]

        if self._replicas is not None:
            args += ["--replicas", str(self._replicas)]

        bspec = ",".join([str(x) for x in self._buckets])
        args += ["--buckets", bspec]

        self._po = Popen(args)

        # Sometimes we get an invalid JAR file. Unfortunately there is no
        # way to determine or "wait for completion". The next best thing
        # is to set a maximum of 15 seconds for the process to start (and
        # connect to the listening socket);

        rlist, _, _ = select.select([self._listen], [], [], 15)
        if not rlist:
            raise CouchbaseMockServerException(
                'Mock server was not ready in time')

        self._harakiri_sock, _ = self._listen.accept()
        self._ctlfp = self._harakiri_sock.makefile()

        sbuf = ""
        while True:
            c = self._ctlfp.read(1)
            if c == '\0':
                break
            sbuf += c
        self._rest_port = int(sbuf)

    def _attempt_shutdown(self):
        try:
            self._listen.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        finally:
            self._listen.close()

        try:
            self._harakiri_sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        finally:
            self._harakiri_sock.close()

        try:
            self._po.terminate()
            self._po.kill()
            self._po.communicate()
        except OSError:
            pass

    def start(self):
        self._invoke()

    def stop(self):
        self._attempt_shutdown()


def create_mock_server():
    bspec_dfl = MockCouchbaseServerBucketSpec('default', 'couchbase')
    mock = MockCouchbaseServer([bspec_dfl],
                               replicas=2,
                               nodes=3)

    try:
        mock.start()
    except Exception as ex:
        raise CouchbaseMockServerException(
            f"Problem trying to start mock server:\n{ex}")

    return mock


def run_quick_test():
    mock_server = create_mock_server()
    bucket_name = "default"
    port = mock_server.rest_port
    host = "127.0.0.1"
    username = "Administrator"
    pw = "password"

    conn_string = "http://{}:{}".format(host, port)
    opts = ClusterOptions(ClassicAuthenticator(username, pw))
    kwargs = {"bucket": bucket_name}
    cluster = Cluster.connect(connection_string=conn_string,
                              options=opts, **kwargs)
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

    # TODO: simple subdoc operations


if __name__ == "__main__":
    run_quick_test()
