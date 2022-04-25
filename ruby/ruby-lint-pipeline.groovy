// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage("src") {
            agent { label "centos7" }
            steps {
                timestamps {
                    cleanWs()
                    dir("checkout-${BUILD_NUMBER}") {
                        dir("library") {
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
                            ]]])
                        }
                        stash(name: "src", includes: "library/**", useDefaultExcludes: false)
                    }
                }
            }
        }
        stage("lint") {
            parallel {
                stage("rbocop") {
                    agent { label "centos7" }
                    steps {
                        dir("rubocop-${BUILD_NUMBER}") {
                            unstash("src")
                            dir("library") {
                                sh("bin/jenkins/install-dependencies")
                                sh("bin/jenkins/check-rubocop")
                            }
                        }
                    }
                }
                stage("format") {
                    agent { label "ubuntu20" }
                    steps {
                        dir("format-${BUILD_NUMBER}") {
                            unstash("src")
                            dir("library") {
                                sh("bin/jenkins/check-clang-format")
                            }
                        }
                    }
                }
                stage("static") {
                    agent { label "ubuntu20" }
                    post {
                        failure {
                            dir("static-${BUILD_NUMBER}/library") {
                                archiveArtifacts(artifacts: "ext/cmake-build-report.tar.gz", allowEmptyArchive: true)
                            }
                        }
                    }
                    steps {
                        dir("static-${BUILD_NUMBER}") {
                            unstash("src")
                            dir("library") {
                                sh("bin/jenkins/install-dependencies")
                                sh("bin/jenkins/check-clang-static-analyzer")
                            }
                        }
                    }
                }
            }
        }
    }
}
