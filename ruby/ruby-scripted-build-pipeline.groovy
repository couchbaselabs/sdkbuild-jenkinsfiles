// vim:et ts=4 sts=4 sw=4

pipeline {
    agent { label "sdkqe-centos8" }
    stages {
        stage("deps") {
            steps {
                timestamps {
                    cleanWs()
                    dir("ruby-sdk") {
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

                        sh("./bin/jenkins/install-dependencies")
                    }
                }
            }
        }
        stage("build") {
            steps {
                timestamps {
                    dir("ruby-sdk") {
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
                    junit("ruby-sdk/test/reports/*.xml")
                }
            }
            steps {
                dir("ruby-sdk") {
                    sh("./bin/jenkins/test-with-cbdyncluster")
                }
            }
        }
    }
}
