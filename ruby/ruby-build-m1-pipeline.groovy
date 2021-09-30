// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    buildName(IS_GERRIT_TRIGGER.toBoolean() ? "cv-${BUILD_NUMBER}" : "full-${BUILD_NUMBER}")
                }
            }
        }
        stage('build') {
            agent { label 'm1' }
            environment {
                PLATFORM = 'm1'
                CB_RUBY_VERSION = '3.0'
            }
            stages {
                stage("src") {
                    steps {
                        timestamps {
                            cleanWs()
                            dir("build-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
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
                            dir("build-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                sh("bin/jenkins/install-dependencies")
                            }
                        }
                    }
                }
                stage("gem") {
                    steps {
                        timestamps {
                            dir("build-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                sh("bin/jenkins/build-extension")
                            }
                        }
                    }
                }
            }
        }
    }
}
