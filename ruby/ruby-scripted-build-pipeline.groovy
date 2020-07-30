// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    buildName(IS_GERRIT_TRIGGER.toBoolean() ? "cv-${BUILD_NUMBER}" : "nightly-${BUILD_NUMBER}")
                }
            }
        }
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
                    stage("build") {
                        steps {
                            timestamps {
                                dir("build-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    sh("bin/jenkins/build-extension")
                                    dir("pkg") {
                                        stash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}-src", includes: "*.gem")
                                        dir("binary") {
                                            stash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}-bin", includes: "*.gem")
                                        }
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
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "scripts-${PLATFORM}-${CB_RUBY_VERSION}")
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}-bin")
                                    sh("bin/jenkins/install-gem ./couchbase-*.gem")
                                }
                            }
                        }
                    }
/*
                    stage("test") {
                        options {
                            timeout(time: 20, unit: 'MINUTES')
                        }
                        post {
                            always {
                                junit("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}/test/reports/*.xml")
                                publishCoverage(adapters: [
                                    coberturaAdapter(path: "test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}/coverage/coverage.xml")
                                ])
                            }
                        }
                        steps {
                            dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                unstash(name: "tests-${PLATFORM}-${CB_RUBY_VERSION}")
                                sh("bin/jenkins/test-with-cbdyncluster")
                            }
                        }
                    }
*/
                }
            }
        }
        stage('pub') {
            agent { label 'sdkqe-centos8' }
            steps {
                dir("repo-${BUILD_NUMBER}") {
                    unstash(name: "scripts-sdkqe-centos8-2.7")
                    dir("gem-bin") {
                        unstash(name: "gem-macos-2.5-bin")
                        unstash(name: "gem-macos-2.6-bin")
                        unstash(name: "gem-macos-2.7-bin")
                        unstash(name: "gem-sdkqe-centos8-2.5-bin")
                        unstash(name: "gem-sdkqe-centos8-2.6-bin")
                        unstash(name: "gem-sdkqe-centos8-2.7-bin")
                        archiveArtifacts(artifacts: "*.gem")
                    }
                    dir("gem-src") {
                        unstash(name: "gem-sdkqe-centos8-2.7-src")
                        archiveArtifacts(artifacts: "*.gem")
                    }
                    sh("bin/jenkins/build-repos")
                    withAWS(credentials: 'aws-sdk', region: 'us-west-1') {
                        s3Upload(
                            bucket: "docs.couchbase.com",
                            acl: 'PublicRead',
                            file: "gem-doc/",
                            path: "sdk-api/",
                            verbose: true
                        )
                    }
                    withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                        s3Upload(
                            bucket: "sdk-snapshots.couchbase.com",
                            acl: 'PublicRead',
                            file: "repos/",
                            path: "ruby/",
                            verbose: true
                        )
                        cfInvalidate(
                            distribution: "$AWS_CF_DISTRIBUTION",
                            paths: [
                                "/ruby/2.5.0/latest_specs.*",
                                "/ruby/2.5.0/prerelease_specs.*",
                                "/ruby/2.5.0/specs.*",
                                "/ruby/2.6.0/latest_specs.*",
                                "/ruby/2.6.0/prerelease_specs.*",
                                "/ruby/2.6.0/specs.*",
                                "/ruby/2.7.0/latest_specs.*",
                                "/ruby/2.7.0/prerelease_specs.*",
                                "/ruby/2.7.0/specs.*",
                            ]
                            //, waitForCompletion: true
                        )
                    }
                    script {
                        def description = sh(script: "cat description.txt", returnStdout: true).trim()
                        buildDescription(description)
                    }
                }
            }
        }
    }
}
