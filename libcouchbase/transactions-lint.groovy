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
                                    refspec: "$GERRIT_REFSPEC",
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
                stage("format") {
                    agent { label "centos7" }
                    steps {
                        dir("format-${BUILD_NUMBER}") {
                            unstash("src")
                            sh("find .")
                            dir("library") {
                                sh("scripts/jenkins/check-clang-format")
                            }
                        }
                    }
                }
                stage("static") {
                    agent { label "centos7" }
                    environment {
                        BOOST_LOCATION = "cbdep"
                    }
                    post {
                        failure {
                            dir("static-${BUILD_NUMBER}/library") {
                                archiveArtifacts(artifacts: "cmake-build-report.tar.gz", allowEmptyArchive: true)
                            }
                        }
                    }
                    steps {
                        dir("static-${BUILD_NUMBER}") {
                            unstash("src")
                            sh("find .")
                            dir("library") {
                                sh("cbdep install boost 1.67.0-cb8 -d deps")
                                sh("scripts/jenkins/check-clang-static-analyzer")
                            }
                        }
                    }
                }
            }
        }
    }
}
