pipeline {
    agent none
    options {
        timeout(time: 1, unit: 'HOURS')
    }
    stages {
        stage("Prepare") {
            agent { label 'centos7' }
            steps {
                dir('couchbase-transactions-cxx') {
                    checkoutSource('couchbase-transactions-cxx')
                }
                stash includes: 'couchbase-transactions-cxx/', name: 'couchbase-transactions-cxx', useDefaultExcludes: false
            }
        }
        stage("Build") {
            parallel {
                stage("Build-macosx") {
                    agent {label 'macos'}
                    steps {
                        cleanWs()
                        unstash 'couchbase-transactions-cxx'
                        shWithEcho('ls -lth')
                        dir('couchbase-transactions-cxx') {
                            shWithEcho('ls -lth')
                            buildLibrary("macos", "-DOPENSSL_ROOT_DIR=/usr/local/opt/openssl")
                        }
                    }
                }
                stage("Build-macosx-m1") {
                    agent {label 'm1'}
                    steps {
                        cleanWs()
                        unstash 'couchbase-transactions-cxx'
                        shWithEcho('ls -lth')
                        dir('couchbase-transactions-cxx') {
                            shWithEcho('ls -lth')
                            buildLibrary("macos-m1", "-DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl")
                        }
                    }
                }
                stage("Build-centos8") {
                    agent { label 'centos8' }
                    steps {
                        cleanWs()
                        unstash 'couchbase-transactions-cxx'
                        shWithEcho('ls -lth')
                        dir('couchbase-transactions-cxx') {
                            shWithEcho('ls -lth')
                            buildLibrary("centos8", '')
                        }
                        stash includes: 'couchbase-transactions-cxx/', name: 'couchbase-transactions-cxx', useDefaultExcludes: false
                    }
                }
                stage("Build-ubuntu-20") {
                    agent { label 'ubuntu20' }
                    steps {
                        cleanWs()
                        unstash 'couchbase-transactions-cxx'
                        shWithEcho('ls -lth')
                        dir('couchbase-transactions-cxx') {
                            shWithEcho('ls -lth')
                            buildLibrary("ubuntu20", '')
                        }
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
        stage("Test_7_1") {
            agent { label 'sdkqe-centos8' }
            steps {
                cleanWs()
                script {
                    unstash 'couchbase-transactions-cxx'
                    dir('couchbase-transactions-cxx') {
                        dir('build-centos8') {
                            testAgainstServer("7.1-stable")
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

void checkoutSource(srcdir) {
    cleanWs()
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
}

void buildLibrary(agent, extras) {
    def builddir="build-${agent}"
    shWithEcho('pwd')
    dir(builddir) {
        // For now lets make a debug build so we get asserts
        shWithEcho("""cmake ${extras} -DCMAKE_BUILD_TYPE=Debug ..""")
        shWithEcho('make -j8')
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
        shWithEcho("cbdyncluster --node kv --node kv,n1ql --node kv --bucket default setup $clusterId")

        // Make the bucket flushable
        shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://" + ip + ":8091/pools/default/buckets/default")
        shWithEcho("curl -v -X POST -u Administrator:password -d name=secBucket -d ramQuotaMB=100 http://"+ ip + ":8091/pools/default/buckets")
        // The transactions tests check for this environment property
        def envStr = ["TXN_CONNECTION_STRING=couchbase://" + ip ]
        withEnv(envStr) {
            def results_file = serverVersion.replaceAll(".", "_") + "_results.xml"
            def exclusions = ""
            if (!serverVersion.startsWith("7")) {
                exclusions = "--gtest_filter=-*Query*"
            }
            try {
                // for now, there is just one executable, lets invoke it directly.  Later, perhaps we can add a cmake task
                // but I ran into some issues with gtest cmake and so on.
                echo("sleeping for 30 sec before starting tests...")
                sleep(30);
                echo("sleep done, beginning tests");
                shWithEcho("LD_PRELOAD=/lib64/libSegFault.so LD_LIBRARY_PATH=. ./client_tests ${exclusions} --gtest_output=xml:${results_file}")
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


