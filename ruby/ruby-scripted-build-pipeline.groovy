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
            matrix {
                axes {
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.5', '2.6', '2.7'
                    }
                    axis {
                        name 'PLATFORM'
                        values 'sdkqe-centos8', 'macos-10.13', 'macos-10.15'
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
                    stage("gem") {
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
                                    script {
                                        if (PLATFORM == "sdkqe-centos8") {
                                            stash(name: "scripts-ubuntu20-${CB_RUBY_VERSION}", includes: "bin/jenkins/*")
                                            stash(name: "tests-ubuntu20-${CB_RUBY_VERSION}", includes: "test/*,test_data/*")
                                            dir("pkg/binary") {
                                                stash(name: "gem-ubuntu20-${CB_RUBY_VERSION}-bin", includes: "*.gem")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        stage('inst') {
            matrix {
                axes {
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.5', '2.6', '2.7'
                    }
                    axis {
                        name 'PLATFORM'
                        values 'sdkqe-centos8', 'macos-10.15', 'ubuntu20'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("deps") {
                        steps {
                            timestamps {
                                dir("inst-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "scripts-${PLATFORM}-${CB_RUBY_VERSION}")
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("inst-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}-bin")
                                    sh("bin/jenkins/install-gem ./couchbase-*.gem")
                                }
                            }
                        }
                    }
                }
            }
        }
        stage('test') {
            environment {
                PLATFORM = 'sdkqe-centos8'
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                      //values '6.0.4', '6.5.1', '6.6.0', '7.0.0-2969'
                        values '6.0.4', '6.5.1', '7.0.0-3154'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.5', '2.6', '2.7'
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
                    stage("test") {
                        options {
                            timeout(time: 15, unit: 'MINUTES')
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
                }
            }
        }
        stage('pub') {
            agent { label 'sdkqe-centos8' }
            stages {
                stage("pkg") {
                    steps {
                        dir("repo-${BUILD_NUMBER}") {
                            unstash(name: "scripts-sdkqe-centos8-2.7")
                            dir("gem-bin") {
                                unstash(name: "gem-macos-10.13-2.5-bin")
                                unstash(name: "gem-macos-10.13-2.6-bin")
                                unstash(name: "gem-macos-10.13-2.7-bin")
                                unstash(name: "gem-macos-10.15-2.5-bin")
                                unstash(name: "gem-macos-10.15-2.6-bin")
                                unstash(name: "gem-macos-10.15-2.7-bin")
                                unstash(name: "gem-sdkqe-centos8-2.5-bin")
                                unstash(name: "gem-sdkqe-centos8-2.6-bin")
                                unstash(name: "gem-sdkqe-centos8-2.7-bin")
                                archiveArtifacts(artifacts: "*.gem")
                            }
                            dir("gem-src") {
                                unstash(name: "gem-sdkqe-centos8-2.7-src")
                                archiveArtifacts(artifacts: "*.gem")
                            }
                        }
                    }
                }
                stage("repo") {
                    when {
                        expression {
                            return IS_GERRIT_TRIGGER.toBoolean() == false
                        }
                    }
                    steps {
                        dir("repo-${BUILD_NUMBER}") {
                            sh("bin/jenkins/build-repos")
                            script {
                                def docs_bucket = "sdk-snapshots.couchbase.com"
                                def docs_region = "us-east-1"
                                if (IS_RELEASE.toBoolean()) {
                                    docs_bucket = "docs.couchbase.com"
                                    docs_region = "us-west-1"
                                }

                                withAWS(credentials: 'aws-sdk', region: docs_region) {
                                    s3Upload(
                                        bucket: docs_bucket,
                                        acl: 'PublicRead',
                                        file: "gem-doc/",
                                        path: "sdk-api/",
                                        verbose: true
                                    )
                                }
                            }
                            sh("tar cf docs-${BUILD_NUMBER}.tar gem-doc")
                            archiveArtifacts(artifacts: "docs-${BUILD_NUMBER}.tar", fingerprint: true)
                            script {
                                def pkg_bucket = "sdk-snapshots.couchbase.com"
                                def pkg_region = "us-east-1"
                                def prefix = ""
                                if (IS_RELEASE.toBoolean()) {
                                    pkg_bucket = "packages.couchbase.com"
                                    prefix = "clients/"
                                }

                                withAWS(credentials: 'aws-sdk', region: pkg_region) {
                                    s3Upload(
                                        bucket: pkg_bucket,
                                        acl: 'PublicRead',
                                        file: "repos/",
                                        path: "${prefix}ruby/",
                                        verbose: true
                                    )
                                    cfInvalidate(
                                        distribution: "$AWS_CF_DISTRIBUTION",
                                        paths: [
                                            "/${prefix}ruby/2.5.0/latest_specs.*",
                                            "/${prefix}ruby/2.5.0/prerelease_specs.*",
                                            "/${prefix}ruby/2.5.0/specs.*",
                                            "/${prefix}ruby/2.6.0/latest_specs.*",
                                            "/${prefix}ruby/2.6.0/prerelease_specs.*",
                                            "/${prefix}ruby/2.6.0/specs.*",
                                            "/${prefix}ruby/2.7.0/latest_specs.*",
                                            "/${prefix}ruby/2.7.0/prerelease_specs.*",
                                            "/${prefix}ruby/2.7.0/specs.*",
                                        ]
                                        //, waitForCompletion: true
                                    )
                                }
                            }
                            sh("tar cf repos-${BUILD_NUMBER}.tar repos")
                            archiveArtifacts(artifacts: "repos-${BUILD_NUMBER}.tar", fingerprint: true)
                            script {
                                def description = sh(script: "cat description.txt", returnStdout: true).trim()
                                buildDescription(description)
                            }
                        }
                    }
                }
            }
        }
    }
}
