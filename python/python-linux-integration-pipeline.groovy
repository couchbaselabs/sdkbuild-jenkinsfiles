String UPDATE_TESTS_URL="https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/master/python/update_tests.py"
String NOSE_COMMAND = "python -m nose couchbase/tests_v3/cases/*_t.py couchbase/tests_v3/cases/ported/*.py --with-flaky --with-xunit --xunit-file=nosetests.xml -v"

class DynamicCluster {
    String id = null;
    String connstr = null;

    boolean isAllocated() {
        return !(id == null || id == "")
    }

    String inspect() {
        return "Cluster(id: ${id}, connstr: ${connstr})"
    }
    String getFirstIp() {
        connstr.tokenize(",")[0]
    }
    String getNthIp(n) {
        connstr.tokenize(",")[n]
    }
}

def CLUSTER = [:]

// TODO: Add the globals above, etc...
def getEnvStr(pyversion, server_version) {
    return ["PATH=${WORKSPACE}/couchbase-python-client-${pyversion}-${server_version}/deps/python${pyversion}-amd64:${WORKSPACE}/couchbase-python-client-${pyversion}-${server_version}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/couchbase-python-client-${pyversion}-${server_version}/deps/python${pyversion}:${WORKSPACE}/couchbase-python-client-${pyversion}-${server_version}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase"]
}

void shWithEcho(String command) {
    echo sh (script: command, returnStdout: true)
}


void waitUntilRebalanceComplete(String ip) {
    def cmd = "curl -u Administrator:password http://${ip}:8091/pools/default/rebalanceProgress"
    progress = true
    iterations = 0
    while(progress && iterations < 20) {
        def ret = sh(returnStdout: true, script: cmd).trim()
        echo("got '${ret}'")
        iterations += 1
        progress = !ret.contains("""{"status":"none"}""")
        if(progress) {
            echo("got '${ret}', sleeping for 20 sec")
            sleep(20)
        }
    }

}

void curl_with_retry(String url, String method, String data) {
    def command = """curl -u Administrator:password -X ${method} -s -o /dev/null -w "%{http_code}" -d '${data}' ${url} """
    echo(command)
    def return_code = 500
    retval = 1
    iterations =  0
    while(retval > 0 && iterations < 10) {
        def ret = sh(returnStdout: true, script: command).trim()
        iterations += 1
        echo "returned ${ret}"
        return_code = ret as int
        // 2XX is success, but sometimes the bucket is already there
        // (in the case of installing the sample buckets), so lets ignore
        // that and just make this "not 500"
        if (return_code > 199 && return_code < 500) {
            echo("success = ${return_code}")
            retval = 0
        } else {
            echo("got #{return_code}, sleeping for 20 sec to try again...")
            sleep(20)
        }
    }
    return retval
}

def doStages(UPDATE_TESTS_URL, CLUSTER, NOSE_COMMAND) {
    def pythons = "${PY_VERSIONS}".split()
    def servers = "${SERVER_VERSIONS}".split()
    echo "${pythons} | ${servers}"
    def mystages = [:]
    for(p in pythons) {
        def py_version = p
        for (s in servers) {
            def server_version = s
            echo "creating stages ${py_version}-${server_version}"
            mystages["${py_version}_${server_version}"] = {
                node('sdkqe-centos7') {
                    stage("build ${py_version}-${server_version}") {
                        cleanWs()
                        dir("couchbase-python-client-${py_version}-${server_version}") {
                            checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])
                            shWithEcho("curl -o update_tests.py ${UPDATE_TESTS_URL}")
                            shWithEcho("cat update_tests.py")
                            shWithEcho("cbdep install python ${py_version} -d deps")
                            withEnv(getEnvStr("${py_version}", "${server_version}")) {
                                shWithEcho("python --version")
                                shWithEcho("pip --version")
                                shWithEcho("pip install -r dev_requirements.txt")
                                shWithEcho("pip install cython")
                                shWithEcho("pip install nose")
                                // everything installed, lets build in place
                                shWithEcho("python setup.py build_ext --inplace")
                            }
                        }
                        stash includes: "couchbase-python-client-${py_version}-${server_version}/", name: "python-client-${py_version}-${server_version}", excludes: "deps/**"
                    }
                    stage("prepare-cluster-and-test ${py_version}-${server_version}") {
                        sh("cbdyncluster ps -a")
                        try {
                            def cluster = new DynamicCluster()
                            def versions = server_version.tokenize("-")
                            def version = versions[0]
                            boolean isDp = versions.size() > 1
                            echo "isDp=${isDp}"
                            CLUSTER["${py_version}-${server_version}"] = cluster
                            def alloc = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version='${server_version}'", returnStdout: true)
                            echo "allocate returned: ${alloc}"
                            cluster.id = alloc.trim()
                            def ips = sh(script: "cbdyncluster ips ${cluster.id}", returnStdout: true)
                            echo "ips returned: ${ips}"
                            cluster.connstr = ips.trim()
                            caps="kv,index,n1ql,fts"
                            if (version>="5.5"){
                                caps=caps+",cbas"
                            }
                            sh("cbdyncluster setup ${cluster.id} --node=${caps} --node=${caps} --node=${caps} --bucket=default")
                            shWithEcho("curl -v -X POST -u Administrator:password -d 'memoryQuota=2048' http://${cluster.getFirstIp()}:8091/pools/default" )
                            // setup buckets, users, storage mode
                            // TODO: one command that does all the default bucket setup (flush, replica, etc...)
                            shWithEcho("curl -vv -X DELETE -u Administrator:password http://${cluster.getFirstIp()}:8091/pools/default/buckets/beer-sample")
                            shWithEcho("curl -vv -X POST -u Administrator:password -d'storageMode=plasma' http://${cluster.getFirstIp()}:8091/settings/indexes")
                            shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://${cluster.getFirstIp()}:8091/pools/default/buckets/default")
                            shWithEcho("curl -v -X POST -u Administrator:password -d replicaNumber=2 http://${cluster.getFirstIp()}:8091/pools/default/buckets/default")
                            curl_with_retry("http://${cluster.getFirstIp()}:8091/sampleBuckets/install", "POST",  '["beer-sample"]' )
                            // give time for bucket to populate, before rebalancing
                            sleep(30)
                            shWithEcho("curl http://Administrator:password@${cluster.getFirstIp()}:8091/pools/default/buckets/beer-sample")
                            shWithEcho("curl -vv -X POST -u Administrator:password -d 'knownNodes=ns_1%40${cluster.getFirstIp()}%2Cns_1%40${cluster.getNthIp(1)}%2Cns_1%40${cluster.getNthIp(2)}' http://${cluster.getFirstIp()}:8091/controller/rebalance")
                            waitUntilRebalanceComplete("${cluster.getFirstIp()}")
                            shWithEcho("""curl -X PUT --data "name=default&roles=admin&password=password" \
                                -H "Content-Type: application/x-www-form-urlencoded" \
                                http://Administrator:password@${cluster.getFirstIp()}:8091/settings/rbac/users/local/default
                            """)
                            shWithEcho("curl -X GET http://Administrator:password@${cluster.getFirstIp()}:8091/settings/rbac/users")
                            //
                            shWithEcho("curl http://Administrator:password@${cluster.getFirstIp()}:8091/pools/default/buckets/default")
                            shWithEcho("curl http://Administrator:password@${cluster.getNthIp(1)}:8091/pools/default/buckets/default")
                            shWithEcho("curl http://Administrator:password@${cluster.getNthIp(2)}:8091/pools/default/buckets/default")
                            // put primary index on default bucket.  TODO: make tests do this perhaps?  Also remember to not do this
                            // after setting developer preview mode!!
                            shWithEcho("curl -vv -XPOST http://Administrator:password@${cluster.getFirstIp()}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON `default` USING GSI'")
                            shWithEcho("curl -vv -XPOST http://Administrator:password@${cluster.getFirstIp()}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON `beer-sample` USING GSI'")
                            // Now an FTS index as well... Again fix the tests but later
                            shWithEcho("""curl -X PUT -vv -u Administrator:password -d '{"name":"beer-search", "type":"fulltext-index", "sourceType":"couchbase", "sourceName":"beer-sample"}' -H 'Content-Type: application/json' http://${cluster.getFirstIp()}:8094/api/index/beer-search""")
                            // sleep a bit so the index should probably be ready.
                            sleep(30)
                            shWithEcho("curl -vv -u Administrator:password http://${cluster.getFirstIp()}:8094/api/index/beer-search")
                            shWithEcho("""curl -vv -u Administrator:password http://${cluster.getFirstIp()}:8093/query/service -d 'statement=SELECT * FROM system:indexes;' """)
                            shWithEcho("curl http://Administrator:password@${cluster.getFirstIp()}:8091/pools/default/buckets/beer-sample")
                            if(isDp) {
                                shWithEcho("curl -vv -XPOST http://Administrator:password@${cluster.getFirstIp()}:8091/settings/developerPreview -d 'enabled=true'")
                            }
                            unstash "python-client-${py_version}-${server_version}"
                            dir("couchbase-python-client-${py_version}-${server_version}"){
                                shWithEcho("cbdep install python ${py_version} -d deps")
                                withEnv(getEnvStr("${py_version}", "${server_version}")) {
                                    def ip = CLUSTER["${py_version}-${server_version}"].getFirstIp()
                                    echo "ip: ${ip}"
                                    shWithEcho("python --version")
                                    shWithEcho("python update_tests.py ${ip}")
                                    shWithEcho("pip install -r requirements.txt")
                                    shWithEcho("${NOSE_COMMAND}")
                                    echo "tests done"
                                }
                            }
                        } catch(all) {
                            echo "${py_version}-${server_version} tests had failures -- ${all.getMessage()}"
                        } finally {
                            if (fileExists("couchbase-python-client-${py_version}-${server_version}/nosetests.xml") ) {
                                junit "couchbase-python-client-${py_version}-${server_version}/nosetests.xml"
                            }
                            script {
                                def c = CLUSTER["${py_version}-${server_version}"]
                                if (c.isAllocated()) {
                                    sh("cbdyncluster rm ${c.id}")
                                    echo "removed cluster"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    echo "${mystages}"
    return mystages
}

pipeline {
    agent { label 'sdkqe-centos7' }
    options {
        timeout(time: 180, unit: 'MINUTES')
        timestamps()
    }
    stages {
        stage('create_builds') {
            steps {
                script {
                    parallel doStages(UPDATE_TESTS_URL, CLUSTER, NOSE_COMMAND)
                }
            }
        }
    }
}
