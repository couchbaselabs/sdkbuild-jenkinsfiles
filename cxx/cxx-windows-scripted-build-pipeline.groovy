def PLATFORMS = [ "windows" ]
def CB_VERSIONS = [
    "71release": [tag: "7.1-release"],
    "72stable": [tag: "7.2-stable"],
    "76stable": [tag: "7.6-stable"],
    "80stable": [tag: "8.0-stable"]
]
// no 7.0.4 release for community
if (USE_CE.toBoolean()) {
    CB_VERSIONS["70release"] = [tag: "7.0.2", label: "7.0-release"]
} else {
    CB_VERSIONS["70release"] = [tag: "7.0-release"]
    // 7.5 only supported on EE
    CB_VERSIONS["75stable"] = [tag: "7.5-stable"]
    CB_VERSIONS["75serverless"] = [tag: "7.5-stable", serverless: true, label: "7.5-serverless"]
}
def COMBINATION_PLATFORM = "rockylinux9"

def checkout() {
    dir("couchbase-cxx-client") {
        checkout([
            $class: "GitSCM",
            branches: [[name: "$SHA"]],
            userRemoteConfigs: [[url: "$REPO", refspec: "$REFSPEC"]],
            extensions: [[
                $class: "SubmoduleOption",
                disableSubmodules: false,
                parentCredentials: false,
                recursiveSubmodules: true,
                reference: "",
                trackingSubmodules: false
            ]]
        ])
    }
}

stage("prepare and validate") {
    node("sdkqe-$COMBINATION_PLATFORM") {
        script {
            buildName([
                    BUILD_NUMBER,
                    PR_ID == "" ? null : "pr${PR_ID}",
                    // STORAGE_BACKEND,
                    USE_TLS ? "tls" : null,
                    USE_CERT_AUTH ? "cert" : null,
            ].findAll { it != null }.join("-"))
        }
        cleanWs()
        checkout()

        stash includes: "couchbase-cxx-client/", name: "couchbase-cxx-client", useDefaultExcludes: false
    }
}

stage("build") {
    def builds = [:]
    for (p in PLATFORMS) {
        def platform = p
        builds[platform]= {
            node(platform) {
                stage("prep") {
                    dir("ws_${platform}") {
                        deleteDir()
                        if (platform == "windows") {
                            checkout()
                        } else {
                            unstash "couchbase-cxx-client"
                        }
                    }
                }
                stage("build") {
                    def envs = ["CB_NUMBER_OF_JOBS=4"]
                    if (platform == "macos") {
                        envs.push("OPENSSL_ROOT_DIR=/usr/local/opt/openssl")
                    } else if (platform == "m1") {
                        envs.push("OPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl")
                    } else if (platform == "qe-grav2-amzn2") {
                        envs.push("OPENSSL_ROOT_DIR=/usr/local/openssl")
                        envs.push("CB_CC=/usr/bin/gcc10-cc")
                        envs.push("CB_CXX=/usr/bin/gcc10-c++")
                    } else if (platform == "amzn2") {
                        envs.push("CB_CC=/opt/gcc-10.2.0/bin/cc")
                        envs.push("CB_CXX=/opt/gcc-10.2.0/bin/c++")
                    } else if (platform == "rockylinux9") {
                        envs.push("CB_CC=gcc")
                        envs.push("CB_CXX=g++")
                    }
                    if (platform == "windows") {
                        bat("cbdep install -d deps openssl 1.1.1g-sdk2")
                        path = PATH
                        path += ";$WORKSPACE/deps/openssl-1.1.1g-sdk2"
                        envs.push("PATH=$path")
                    }
                    withEnv(envs) {
                        dir("ws_${platform}/couchbase-cxx-client") {
                            if (platform == "windows") {
                                dir("build") {
                                    bat("cmake ..")
                                    bat("cmake --build . --parallel $CB_NUMBER_OF_JOBS")
                                }
                            } else {
                                sh("./bin/build-tests")
                            }
                        }
                    }
                    if (platform == COMBINATION_PLATFORM || platform == "windows") {
                        stash(includes: "ws_${platform}/", name: "${platform}_build", useDefaultExcludes: false)
                    }
                }
            }
        }
    }
    parallel(builds)
}

class DynamicCluster {
    String id_ = null;
    String ips_ = null;
    String version_ = null;
    boolean useTLS = false;
    boolean useCertAuth = false;
    String certsDir = null;
    String connstr = null;

    DynamicCluster(String version) {
        this.version_ = version
    }

    String clusterId() {
        return id_
    }

    String connectionString() {
        if (connstr != null) {
            return connstr
        }
        def prefix = "couchbase://"
        if (useTLS) {
            prefix = "couchbases://"
        }
        def connstr = prefix + ips_
        if (useTLS) {
            connstr += "?trust_certificate=$certsDir/ca.pem"
        }
        return connstr
    }

    String firstIP() {
        return ips_.tokenize(",")[0]
    }

    String version() {
        return version_.tokenize("_")[0]
    }

    int major() {
        return version().tokenize(".")[0] as Integer
    }

    int minor() {
        // e.g. 7.1-stable or 7.1.0 becomes 1
        return version().tokenize("-")[0].tokenize(".")[1] as Integer
    }

    int numRootCAs() {
        if (major() > 7 || (major() == 7 && minor() >= 1)) {
            return 2
        } else {
            return 1
        }
    }

    String certPath() {
        if (useCertAuth) {
            return "$certsDir/client.pem"
        } else {
            return ""
        }
    }

    String keyPath() {
        if (useCertAuth) {
            return "$certsDir/client.key"
        } else {
            return ""
        }
    }

    boolean supportsStorageBackend() {
        return major() > 7 || (major() == 7 && minor() >= 1)
    }
}

if (!SKIP_TESTS.toBoolean()) {
    stage("tls=${USE_TLS}, cert_auth=${USE_CERT_AUTH}") {
        def cbverStages = [:]
        cbverStages["windows-capella"] = {
            node("windows") {
                def CLUSTER = new DynamicCluster("capella")
                try {
                    stage("capella") {
                        withEnv([
                            "AUTH=cxx-sdk-${BUILD_NUMBER}@couchbase.com"
                        ]){
                            deleteDir()
                            CLUSTER.id_ = bat(script: "cbdyncluster create-cloud --node kv,index,n1ql,eventing,fts,cbas --node kv,index,n1ql,eventing,fts,cbas --node kv,index,n1ql,eventing,fts,cbas", returnStdout: true).trim()
                            CLUSTER.ips_ = bat(script: "cbdyncluster ips ${CLUSTER.clusterId()}", returnStdout: true).trim()
                            bat("cbdyncluster add-bucket ${CLUSTER.clusterId()} --name default --ram-quota 256")
                            bat("cbdyncluster add-sample-bucket ${CLUSTER.clusterId()} --name travel-sample")
                            bat("curl -k -sS -uAdministrator:P@ssword1 https://${CLUSTER.firstIP()}:18093/query/service -d'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                            CLUSTER.connstr = bat(script: "cbdyncluster connstr ${CLUSTER.clusterId()} --ssl", returnStdout: true).trim()
                        }
                    }
                    timeout(unit: 'MINUTES', time: 40) {
                        stage("test") {
                            unstash("${COMBINATION_PLATFORM}_build")
                            withEnv([
                                "TEST_CONNECTION_STRING=${CLUSTER.connectionString()}",
                                "CTEST_OUTPUT_ON_FAILURE=1",
                                "TEST_LOG_LEVEL=trace",
                                "TEST_PASSWORD=P@ssword1",
                                "TEST_DEPLOYMENT_TYPE=capella"
                            ]) {
                                dir("ws_${COMBINATION_PLATFORM}/couchbase-cxx-client") {
                                    bat("if [ -f ./bin/create-search-index ] ; then ./bin/create-search-index ${CLUSTER.firstIP()} ${USE_TLS} Administrator P@ssword1; fi")
                                    try {
                                        bat("./bin/run-unit-tests")
                                    } finally {
                                        junit("cmake-build-tests/results.xml")
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    stage("cleanup") {
                        withEnv([
                            "AUTH=cxx-sdk-${BUILD_NUMBER}@couchbase.com"
                        ]) {
                            bat("cbdyncluster rm ${CLUSTER.clusterId()}")
                        }
                    }
                }
            }
        }
        parallel(cbverStages)
    }
}
