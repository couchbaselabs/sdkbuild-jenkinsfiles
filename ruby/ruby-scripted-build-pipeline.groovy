// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('gem') {
            matrix {
                axes {
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.5', '2.6', '2.7'
                    }
                    axis {
                        name 'PLATFORM'
                        values 'sdkqe-centos8', 'macos'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("src") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
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
                            }
                        }
                    }
                    stage("deps") {
                        steps {
                            timestamps {
                                dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("build") {
                        steps {
                            timestamps {
                                dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
                                    sh("bin/jenkins/build-extension")
                                    dir("pkg/binary") {
                                        archiveArtifacts(artifacts: "*.gem")
                                        stash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}", includes: "*.gem")
                                    }
                                    stash(name: "scripts-${PLATFORM}-${CB_RUBY_VERSION}", includes: "bin/jenkins/*")
                                    stash(name: "tests-${PLATFORM}-${CB_RUBY_VERSION}", includes: "test/*,test_data/*")
                                }
                            }
                        }
                    }
                }
            }
        }

        stage('test') {
            matrix {
                axes {
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.5', '2.6', '2.7'
                    }
                    axis {
                        name 'PLATFORM'
                        values 'sdkqe-centos8', 'macos'
                    }
                    axis {
                        name 'CB_VERSION'
                        values '6.0.4', '6.5.1', '7.0.0-2588'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("deps") {
                        steps {
                            timestamps {
                                dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
                                    unstash(name: "scripts-${PLATFORM}-${CB_RUBY_VERSION}")
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
                                    sh("ls -l")
                                    unstash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}")
                                    sh("bin/jenkins/install-gem ./couchbase-*.gem")
                                }
                            }
                        }
                    }
                    stage("test") {
                        options {
                            timeout(time: 20, unit: 'MINUTES')
                        }
                        post {
                            always {
                                junit("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}/test/reports/*.xml")
                                publishCoverage(adapters: [
                                    coberturaAdapter(path: "ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}/coverage/coverage.xml")
                                ])
                            }
                        }
                        steps {
                            dir("ruby-sdk-${PLATFORM}-${CB_RUBY_VERSION}") {
                                unstash(name: "tests-${PLATFORM}-${CB_RUBY_VERSION}")
                                sh("bin/jenkins/test-with-cbdyncluster")
                            }
                        }
                    }
                }
            }
        }
    }
}
