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
                            "${BUILD_NUMBER}-upstream" :
                            "${BUILD_NUMBER}-build-${UPSTREAM_BUILD}"
                    )
                }
            }
        }

        stage("test") {
            environment {
                PLATFORM = 'sdkqe-rockylinux9'
            }
            matrix {
                when {
                    allOf {
                        expression { CB_VERSION_FILTER == 'all' || CB_VERSION_FILTER == CB_VERSION }
                        expression { CB_RUBY_VERSION_FILTER == 'all' || CB_RUBY_VERSION_FILTER == CB_RUBY_VERSION }
                    }
                }
                axes {
                    axis {
                        name 'CB_VERSION'
                        values '7.6-stable', '7.2-release', '7.1-release', '7.0-release', '6.6-release'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '3.1', '3.2', '3.3'
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
                                sh("bin/jenkins/install-dependencies.sh")
                                sh("bin/jenkins/test-with-cbdyncluster ./couchbase-*.gem")
                            }
                        }
                    }
                }
            }
        }
    }
}
