pipeline {
    agent none
    options {
        timeout(time: 1, unit: 'HOURS')
    }
    stages {
        stage("Build") {
            parallel {
                stage("Build-macosx") {
                    agent {label 'macos'}
                    steps {
                         buildLibrary(true, "macos")
                    }
                }
//                stage("Build-centos7") {
//                    agent { label 'centos7' }
//                    steps {
//                        buildLibrary(true, "centos7")
//                    }
//                }
                stage("Build-centos8") {
                    agent { label 'centos8' }
                    steps {
                        buildLibrary(true, "centos8")
                        stash includes: 'couchbase-transactions-cxx/', name: 'couchbase-transactions-cxx', useDefaultExcludes: false
                    }
                }
                stage("Build-debian9") {
                    agent { label 'debian9' }
                    steps {
                        buildLibrary(true, "debian9")
                    }
                }
                stage("Build-ubuntu-20") {
                    agent { label 'ubuntu20' }
                    steps {
                        buildLibrary(true, "ubuntu20")
                    }
                }
            }
        }
        stage("Test_6.6_stable") {
            agent { label 'sdkqe-centos8' }
            steps {
                cleanWs()
                script {
                    unstash 'couchbase-transactions-cxx'
                    dir('couchbase-transactions-cxx') {
                        dir('build-centos8') {
                            testAgainstServer("6.6-stable")
                        }
                    }
                }
            }
        }
        stage(Test_7_0_0) {
            agent { label 'sdkqe-centos8' }
            steps {
                cleanWs()
                script {
                    unstash 'couchbase-transactions-cxx'
                    dir('couchbase-transactions-cxx') {
                        dir('build-centos8') {
                            testAgainstServer("7.0-stable")
                        }
                    }
                }
            }
        }
    }
}

void shWithEcho(String command) {
    echo sh(script: command, returnStdout: true)
}

void buildLibrary(fail_ok, agent) {
    try {
        cleanWs()
        def builddir="build-${agent}"
        dir("couchbase-transactions-cxx/") {
            shWithEcho('pwd')
            checkout([
                $class: "GitSCM",
                branches: [[name: "$SHA"]],
                extensions: [[
                    $class: "SubmoduleOption",
                    disableSubmodules: false,
                    parentCredentials: true,
                    recursiveSubmodules: true,
                ]],
                userRemoteConfigs: [[
                    refspec: "$GERRIT_REFSPEC",
                    url: "$REPO",
                    poll: false
                ]]])
            dir(builddir) {
                // For now lets make a debug build so we get asserts
                shWithEcho("""cmake -DCMAKE_BUILD_TYPE=Debug ..""")
                shWithEcho('make')
            }
        }
    } catch(Exception e) {
        echo("build failed ${e}")
        if (!fail_ok) {
            throw e
        }
    }
}

void testAgainstServer(String serverVersion) {
    def clusterId = null
    try {
        shWithEcho("ls -latr")
        shWithEcho("pwd")

        // For debugging, what clusters are open
        shWithEcho("cbdyncluster ps -a")

        // Allocate the cluster.  3 KV nodes.
        clusterId = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version=" + serverVersion, returnStdout: true)
        echo "Got cluster ID $clusterId"

        // Find the cluster IP
        def ips = sh(script: "cbdyncluster ips $clusterId", returnStdout: true).trim()
        echo "Got raw cluster IPs " + ips
        def ip = ips.tokenize(',')[0]
        echo "Got cluster IP http://" + ip + ":8091"

        // Create the cluster
        shWithEcho("cbdyncluster --node kv --node kv --node kv --bucket default setup $clusterId")

        // Make the bucket flushable
        shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://" + ip + ":8091/pools/default/buckets/default")
        shWithEcho("curl -v -X POST -u Administrator:password -d name=secBucket -d ramQuotaMB=100 http://"+ ip + ":8091/pools/default/buckets")
        // The transactions tests check for this environment property
        def envStr = ["TXN_CONNECTION_STRING=couchbase://" + ip ]
        if (serverVersion.startsWith("7")) {
            envStr << "SUPPORTS_COLLECTIONS=1"
        }
        withEnv(envStr) {
            def results_file = serverVersion.replaceAll(".", "_") + "_results.xml"
            try {
                // for now, there is just one executable, lets invoke it directly.  Later, perhaps we can add a cmake task
                // but I ran into some issues with gtest cmake and so on.
                shWithEcho("LD_LIBRARY_PATH=. ./client_tests --gtest_output=xml:${results_file}")
            }
            finally {
                // Process the Junit test results
                junit '**/*_results.xml'
            }
        }
    }
    finally {
        if (clusterId != null) {
            // Easy to run out of resources during iterating, so cleanup even
            // though cluster will be auto-removed after a time
            sh(script: "cbdyncluster rm $clusterId")
        }
    }
}


