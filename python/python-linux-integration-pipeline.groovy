String UPDATE_TESTS_URL="https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/master/python/update_tests.py"
String NOSE_COMMAND = "python -m nose couchbase/tests_v3/cases/*_t.py --with-flaky --with-xunit --xunit-file=nosetests.xml -v"

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
}
def CLUSTER = new DynamicCluster()

pipeline {
    agent none
    options {
        timeout(time: 90, unit: 'MINUTES')
    }
    stages {
        stage("build_${PYTHON_VERSION}") {
            agent { label 'sdk-integration-test-linux' }
            steps {
                cleanWs()
                dir('couchbase-python-client-${PYTHON_VERSION') {
                    checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])
                    shWithEcho("curl -o update_tests.py ${UPDATE_TESTS_URL}")
                    shWithEcho("cat update_tests.py")
                    shWithEcho("cbdep install python ${PYTHON_VERSION} -d deps")
                    withEnv(getEnvStr("${PYTHON_VERSION}", "${SERVER_VERSION}")) {
                        // source the venv activate script
                        shWithEcho(". ./deps/python${PYTHON_VERSION}/bin/activate")
                        shWithEcho("python --version")
                        shWithEcho("pip --version")
                        shWithEcho("pip install -r dev_requirements.txt")
                        shWithEcho("pip install cython")
                        shWithEcho("pip install nose")
                        // everything installed, lets build in place
                        shWithEcho("python setup.py build_ext --inplace")
                    }
                }
                stash includes: "couchbase-python-client-${PYTHON_VERSION}/", name: 'python-client', useDefaultExcludes: false
            }
            stage('prepare cluster') {
                agent { label 'sdk-integration-test-linux' }
                steps {
                    sh("cbdyncluster ps -a")
                    script {
                        CLUSTER.id = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version=${SERVER_VERSION}", returnStdout: true).trim()
                        CLUSTER.connstr = sh(script: "cbdyncluster ips ${CLUSTER.id}", returnStdout: true).trim()
                        echo "Allocated ${CLUSTER.inspect()}"

                        sh("cbdyncluster setup ${CLUSTER.id} --node=kv,index,n1ql,fts,cbas --node=kv --node=kv --bucket=default")
                        // setup buckets, users
                        shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://${CLUSTER.getFirstIp()}:8091/pools/default/buckets/default")
                        shWithEcho("""curl -v -X POST -u Administrator:password -d '["beer-sample"]' http://${CLUSTER.getFirstIp()}:8091/sampleBuckets/install""")
                        sleep(30)
                        shWithEcho("""curl -X PUT --data "name=default&roles=admin&password=password" \
                            -H "Content-Type: application/x-www-form-urlencoded" \
                            http://Administrator:password@${CLUSTER.getFirstIp()}:8091/settings/rbac/users/local/default
                        """)
                        shWithEcho("curl -X GET http://Administrator:password@${CLUSTER.getFirstIp()}:8091/settings/rbac/users")
                        shWithEcho("curl http://Administrator:password@${CLUSTER.getFirstIp()}:8091/pools/default/buckets/default")
                        shWithEcho("curl -vv -XPOST http://Administrator:password@${CLUSTER.getFirstIp()}:8091/settings/developerPreview -d 'enabled=true'")
                    }
                }
            }
            stage("test-$PYTHON_VERSION}") {
                post {
                    always {
                        junit "couchbase-python-client-${PYTHON_VERSION}/nosetests.xml"
                        script {
                            if (CLUSTER.isAllocated()) {
                                sh("cbdyncluster rm ${CLUSTER.id}")
                                echo("removed cluster")
                            }
                        }
                    }
                }
                agent { label 'sdk-integration-test-linux' }
                steps {
                    unstash "python-client-${PYTHON_VERSION}"
                    dir("couchbase-python-client-${PYTHON_VERSION}"){
                        withEnv(getEnvStr("${PYTHON_VERSION}", "${SERVER_VERSION}")) {
                            shWithEcho(". ./deps/python${PYTHON_VERSION}/bin/activate")
                            shWithEcho("python --version")
                            shWithEcho("python update_tests.py ${CLUSTER.getFirstIp()}")
                            shWithEcho("pip install -r requirements.txt")
                            shWithEcho("${NOSE_COMMAND}")
                        }
                    }
                }
            }
        }
    }
}

// TODO: take a hard look at whether or not this is necessary
def getEnvStr(pyversion, server_version) {
    return ["PATH=${WORKSPACE}/couchbase-python-client/deps/python${pyversion}-amd64:${WORKSPACE}/couchbase-python-client/deps/python${pyversion}-amd64/bin:${WORKSPACE}/couchbase-python-client/deps/python${pyversion}:${WORKSPACE}/couchbase-python-client/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase"]
 }

void shWithEcho(String command) {
    echo sh (script: command, returnStdout: true)
}
