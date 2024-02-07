// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    buildName(
                        UPSTREAM_BUILD.isEmpty() ?
                            "upstream-${BUILD_NUMBER}" :
                            "build-${UPSTREAM_BUILD}-${BUILD_NUMBER}"
                    )
                }
            }
        }

        stage("test") {
            environment {
                PLATFORM = 'sdkqe-centos7'
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                        values CB_VERSION.isEmpty() ? ['7.2-stable', '7.1-release', '7.0-release', '6.6-release'] : CB_VERSION.split(',')
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values CB_RUBY_VERSION.isEmpty() ? ['3.1', '3.2', '3.3'] : CB_RUBY_VERSION.split(',')
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("test") {
                        options {
                            timeout(time: 1, unit: 'HOURS')
                        }
                        steps {
                            dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                copyArtifacts(
                                    projectName: 'ruby-build-pipeline',
                                    selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD),
                                    filter: 'couchbase-*-x86_64-linux.gem,scripts-and-tests.tar.xz'
                                )
                                sh("tar xvf scripts-and-tests.tar.xz")
                                sh("bin/jenkins/test-with-cbdyncluster ./couchbase-*.gem")
                            }
                        }
                    }
                }
            }
        }
    }
}
