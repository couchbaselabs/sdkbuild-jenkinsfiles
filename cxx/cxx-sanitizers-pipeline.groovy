// vim:et ts=4 sts=4 sw=4

def check_clang() {
    sh("""
if [ ! -e /usr/bin/clang-16 ]
then
    curl https://apt.llvm.org/llvm-snapshot.gpg.key | sudo apt-key add -
    sudo bash -c "echo 'deb https://apt.llvm.org/focal/ llvm-toolchain-focal-16 main' >> /etc/apt/sources.list"
    sudo apt-get update -y
    sudo apt-get install -y clang-16 clang-tools-16
fi
""")
}

def check_valgrind() {
    sh("""
if [ ! -e /usr/bin/valgrind ]
then
    sudo apt-get update -y
    sudo apt-get install -y valgrind
fi
""")
}

def check_dependencies(tool) {
    if (tool == "drd" || tool == "memcheck") {
        check_valgrind()
    } else {
        check_clang()
    }
    sh("ccache -M 10G")
}

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    buildName("sanitizers-${BUILD_NUMBER}")
                }
            }
        }
        stage("src") {
            agent any
            steps {
                dir("couchbase-cxx-client") {
                    deleteDir()
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
                            refspec: "$REFSPEC",
                            url: "$REPO",
                            poll: false
                        ]]
                    ])
                }
                stash includes: "couchbase-cxx-client/", name: "couchbase-cxx-client", useDefaultExcludes: false
            }
        }
        stage('check') {
            environment {
                CB_CLANG = 'clang-16'
                CB_CLANGXX = 'clang++-16'
                CB_NUMBER_OF_JOBS = '4'
            }
            matrix {
                axes {
                    axis {
                        name 'TOOL'
                        values 'drd', 'memcheck', 'tsan', 'ubsan', 'asan', 'lsan'
                    }
                }
                environment {
                    CB_SANITIZER = "${TOOL}"
                }
                agent { label 'ubuntu20' }
                stages {
                    stage("src") {
                        steps {
                            cleanWs()
                            dir("build-${TOOL}-${BUILD_NUMBER}") {
                                deleteDir()
                                unstash("couchbase-cxx-client")
                            }
                        }
                    }
                    stage("deps") {
                        steps {
                            check_dependencies(TOOL)
                        }
                    }
                    stage("build") {
                        steps {
                            timestamps {
                                dir("build-${TOOL}-${BUILD_NUMBER}/couchbase-cxx-client") {
                                    sh("ccache -s")
                                    sh("./bin/build-tests")
                                }
                            }
                        }
                    }
                    stage("run") {
                        options {
                            timeout(time: 60, unit: 'MINUTES')
                        }
                        steps {
                            timestamps {
                                script { // use scripted pipeline for dynamic stage name
                                    stage(TOOL) {
                                        dir("build-${TOOL}/couchbase-cxx-client") {
                                            sh("echo running ${TOOL}")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
