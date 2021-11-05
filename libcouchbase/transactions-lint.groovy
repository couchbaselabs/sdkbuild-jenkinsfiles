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
                            dir("library") {
                                sh("scripts/jenkins/check-clang-format")
                            }
                        }
                    }
                }
            }
        }
    }
}
