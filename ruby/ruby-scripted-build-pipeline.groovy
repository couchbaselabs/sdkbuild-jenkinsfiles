// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('check') {
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
                agent { label "macos" }
                stages {
                    stage("src") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("ruby-sdk-${CB_RUBY_VERSION}") {
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
                                dir("ruby-sdk-${CB_RUBY_VERSION}") {
                                    sh("./bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("build") {
                        steps {
                            timestamps {
                                dir("ruby-sdk-${CB_RUBY_VERSION}") {
                                    sh("./bin/jenkins/build-extension")
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
                                junit("ruby-sdk-${CB_RUBY_VERSION}/test/reports/*.xml")
                            }
                        }
                        steps {
                            dir("ruby-sdk-${CB_RUBY_VERSION}") {
                                sh("./bin/jenkins/test-with-cbdyncluster")
                            }
                        }
                    }
                }
            }
        }
    }
}
