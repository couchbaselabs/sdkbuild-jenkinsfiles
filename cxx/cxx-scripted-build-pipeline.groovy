def PLATFORMS = [ "ubuntu20", "centos7", "centos8", "macos", "m1", "amzn2", "qe-grav2-amzn2", "alpine", "windows", "qe-ubuntu20-arm64" ]
def CB_VERSIONS = [
    "66release": [tag: "6.6-release"],
    "71release": [tag: "7.1-release"],
    "71stable": [tag: "7.1-stable"],
    "72stable": [tag: "7.2-stable"]
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
def COMBINATION_PLATFORM = "centos7"

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
                    } else if (platform == "centos7") {
                        envs.push("CB_CC=/opt/rh/devtoolset-9/root/usr/bin/cc")
                        envs.push("CB_CXX=/opt/rh/devtoolset-9/root/usr/bin/c++")
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
                    if (platform == COMBINATION_PLATFORM) {
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
    stage("combination-test") {
        def cbverStages = [:]
        CB_VERSIONS.each{cb_version ->
            def v = cb_version.value
            def version = v["tag"]
            def label = version
            def serverless = false
            if (v["label"] != null) {
                label = v["label"]
            }
            if (v["serverless"] != null) {
                serverless = v["serverless"].toBoolean()
            }
            cbverStages[label] = {
                node("sdkqe-$COMBINATION_PLATFORM") {
                    def CLUSTER = new DynamicCluster(version)
                    try {
                        stage("env") {
                            withEnv([
                                "AUTH=cxx-sdk-${BUILD_NUMBER}@couchbase.com"
                            ]){
                                deleteDir()
                                def allocate_cmd = "cbdyncluster allocate --num-nodes=3 --server-version=${version} --platform ec2"
                                if (USE_CE.toBoolean()) {
                                    allocate_cmd += " --use-ce"
                                }
                                if (serverless) {
                                    allocate_cmd += " --serverless-mode"
                                }
                                CLUSTER.id_ = sh(script: allocate_cmd, returnStdout: true).trim()
                                CLUSTER.ips_ = sh(script: "cbdyncluster ips ${CLUSTER.clusterId()}", returnStdout: true).trim()
                                def secondNodeServices = "kv"
                                if (USE_CE.toBoolean()) {
                                    sh("cbdyncluster setup ${CLUSTER.clusterId()} --node=kv,index,n1ql,fts --node ${secondNodeServices} --node=kv --storage-mode=forestdb --ram-quota 2048")
                                } else {
                                    // all indexes in serverless mode must be created with 2 replicas
                                    if (serverless) {
                                        secondNodeServices = "kv,index,fts"
                                    }
                                    sh("cbdyncluster setup ${CLUSTER.clusterId()} --node=kv,index,n1ql --node ${secondNodeServices} --node=fts,cbas,eventing --storage-mode=plasma --ram-quota 2048")
                                }
                                if (USE_TLS.toBoolean()) {
                                    CLUSTER.useTLS = true
                                    CLUSTER.certsDir = WORKSPACE
                                    sh("cbdyncluster setup-cert-auth ${CLUSTER.clusterId()} --user Administrator --num-roots ${CLUSTER.numRootCAs()}")
                                }
                                CLUSTER.useCertAuth = USE_CERT_AUTH.toBoolean()
                                def add_bucket_cmd = "cbdyncluster add-bucket ${CLUSTER.clusterId()} --name default --ram-quota 256"
                                if (serverless) {
                                    // FIXME: Just add more kv nodes
                                    // because we don't create server groups the bucket only gets placed on 1 node so we can't do durable operations if we have replicas
                                    add_bucket_cmd += " --width 1 --replica-count 0 --storage-backend magma"
                                } else if (CLUSTER.supportsStorageBackend()) {
                                    add_bucket_cmd += " --storage-backend ${STORAGE_BACKEND}"
                                }
                                sh(add_bucket_cmd)
                                sh("cbdyncluster add-sample-bucket ${CLUSTER.clusterId()} --name travel-sample")
                                sh("curl -sS -uAdministrator:password http://${CLUSTER.firstIP()}:8093/query/service -d'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                            }
                        }
                        timeout(unit: 'MINUTES', time: 40) {
                            stage("test") {
                                unstash("${COMBINATION_PLATFORM}_build")
                                withEnv([
                                    "TEST_CONNECTION_STRING=${CLUSTER.connectionString()}",
                                    "CTEST_OUTPUT_ON_FAILURE=1",
                                    "TEST_LOG_LEVEL=trace",
                                    "TEST_CERTIFICATE_PATH=${CLUSTER.certPath()}",
                                    "TEST_KEY_PATH=${CLUSTER.keyPath()}",
                                    "AUTH=cxx-sdk-${BUILD_NUMBER}@couchbase.com"
                                ]) {
                                    dir("ws_${COMBINATION_PLATFORM}/couchbase-cxx-client") {
                                        sh("if [ -f ./bin/create-search-index ] ; then ./bin/create-search-index ${CLUSTER.firstIP()} ${CLUSTER.useTLS} Administrator password; fi")
                                        try {
                                            sh("./bin/run-unit-tests")
                                        } catch(e) {
                                            dir("server_logs_${label}") {
                                                sh("cbdyncluster cbcollect ${CLUSTER.clusterId()}")
                                            }
                                            archiveArtifacts(artifacts: "server_logs_${label}/*.zip", allowEmptyArchive: true)
                                            throw e
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
                                sh("cbdyncluster rm ${CLUSTER.clusterId()}")
                            }
                        }
                    }
                }
            }
        }
        cbverStages["capella"] = {
            node("sdkqe-$COMBINATION_PLATFORM") {
                def CLUSTER = new DynamicCluster("capella")
                try {
                    stage("env") {
                        withEnv([
                            "AUTH=cxx-sdk-${BUILD_NUMBER}@couchbase.com"
                        ]){
                            deleteDir()
                            CLUSTER.id_ = sh(script: "cbdyncluster create-cloud --node kv,index,n1ql,eventing,fts,cbas --node kv,index,n1ql,eventing,fts,cbas --node kv,index,n1ql,eventing,fts,cbas", returnStdout: true).trim()
                            CLUSTER.ips_ = sh(script: "cbdyncluster ips ${CLUSTER.clusterId()}", returnStdout: true).trim()
                            sh("cbdyncluster add-bucket ${CLUSTER.clusterId()} --name default --ram-quota 256")
                            sh("cbdyncluster add-sample-bucket ${CLUSTER.clusterId()} --name travel-sample")
                            sh("curl -k -sS -uAdministrator:P@ssword1 https://${CLUSTER.firstIP()}:18093/query/service -d'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                            CLUSTER.connstr = sh(script: "cbdyncluster connstr ${CLUSTER.clusterId()} --ssl", returnStdout: true).trim()
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
                                    sh("if [ -f ./bin/create-search-index ] ; then ./bin/create-search-index ${CLUSTER.firstIP()} ${CLUSTER.useTLS} Administrator P@ssword1; fi")
                                    try {
                                        sh("./bin/run-unit-tests")
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
                            sh("cbdyncluster rm ${CLUSTER.clusterId()}")
                        }
                    }
                }
            }
        }
        parallel(cbverStages)
    }
}
