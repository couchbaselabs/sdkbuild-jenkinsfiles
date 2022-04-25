// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    buildName(IS_PULL_REQUEST.toBoolean() ? "cv-${BUILD_NUMBER}" : "full-${BUILD_NUMBER}")
                }
            }
        }
        stage('build') {
            matrix {
                axes {
                    axis {
                        name 'PLATFORM'
                        values 'centos7', 'macos-11.0', 'macos-10.15', 'm1', 'alpine', 'qe-grav2-amzn2'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.7', '3.0', '3.1', 'brew'
                    }
                }
                excludes {
                    exclude {
                        axis {
                            name 'PLATFORM'
                            notValues 'macos-11.0', 'macos-10.15', 'm1'
                        }
                        axis {
                            name 'CB_RUBY_VERSION'
                            values 'brew'
                        }
                    }
                    exclude {
                        axis {
                            name 'PLATFORM'
                            values 'm1'
                        }
                        axis {
                            name 'CB_RUBY_VERSION'
                            notValues 'brew'
                        }
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("src") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("build-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    deleteDir()
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
                                    stash(name: "tests-${PLATFORM}-${CB_RUBY_VERSION}", includes: "Gemfile,test/**/*,test_data/**/*")
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
                        name 'PLATFORM'
                        values 'centos7', 'macos-11.0', 'macos-10.15', 'ubuntu20', 'debian9', 'm1', 'alpine', 'amzn2', 'qe-grav2-amzn2'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.7', '3.0', '3.1', 'brew'
                    }
                }
                excludes {
                    exclude {
                        axis {
                            name 'PLATFORM'
                            notValues 'macos-11.0', 'macos-10.15', 'm1'
                        }
                        axis {
                            name 'CB_RUBY_VERSION'
                            values 'brew'
                        }
                    }
                    exclude {
                        axis {
                            name 'PLATFORM'
                            values 'm1'
                        }
                        axis {
                            name 'CB_RUBY_VERSION'
                            notValues 'brew'
                        }
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("deps") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("inst-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "scripts-centos7-2.7")
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("inst-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    script {
                                        if (PLATFORM =~ /macos|m1|alpine|grav2/) {
                                            unstash(name: "gem-${PLATFORM}-${CB_RUBY_VERSION}-bin")
                                        } else {
                                            unstash(name: "gem-centos7-${CB_RUBY_VERSION}-bin")
                                        }
                                    }
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
                        values /* '7.1-stable', */'7.0.1', '6.6.3', '6.5.2', '6.0.5'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '2.7', '3.0', '3.1'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("deps") {
                        steps {
                            timestamps {
                                sh("sudo dnf config-manager --set-disabled 'bintray-*' || true")
                                cleanWs()
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "scripts-centos7-${CB_RUBY_VERSION}")
                                    sh("bin/jenkins/install-dependencies")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "gem-centos7-${CB_RUBY_VERSION}-bin")
                                    sh("bin/jenkins/install-gem ./couchbase-*.gem")
                                }
                            }
                        }
                    }
                    stage("test") {
                        options {
                            timeout(time: 3, unit: 'HOURS')
                        }
                        post {
                            always {
                                junit("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}/test/reports/*.xml")
                                publishCoverage(adapters: [
                                    coberturaAdapter(path: "test-centos7-${CB_RUBY_VERSION}-${BUILD_NUMBER}/coverage/coverage.xml")
                                ])
                            }
                            failure {
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    archiveArtifacts(artifacts: "server_logs.tar.gz", allowEmptyArchive: true)
                                }
                            }
                        }
                        steps {
                            dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                unstash(name: "tests-centos7-${CB_RUBY_VERSION}")
                                sh("bin/jenkins/test-with-cbdyncluster")
                            }
                        }
                    }
                }
            }
        }
        stage('pub') {
            agent { label 'centos8' }
            stages {
                stage("deps") {
                    steps {
                        timestamps {
                            cleanWs()
                            dir("deps-${BUILD_NUMBER}") {
                                unstash(name: "scripts-centos7-2.7")
                                sh("bin/jenkins/install-dependencies")
                            }
                        }
                    }
                }
                stage("pkg") {
                    steps {
                        cleanWs()
                        dir("repo-${BUILD_NUMBER}") {
                            unstash(name: "scripts-centos7-2.7")
                            dir("gem-bin") {
                                unstash(name: "gem-m1-brew-bin")
                                unstash(name: "gem-macos-11.0-2.7-bin")
                                unstash(name: "gem-macos-11.0-3.0-bin")
                                unstash(name: "gem-macos-11.0-3.1-bin")
                                unstash(name: "gem-macos-10.15-2.7-bin")
                                unstash(name: "gem-macos-10.15-3.0-bin")
                                unstash(name: "gem-macos-10.15-3.1-bin")
                                unstash(name: "gem-centos7-2.7-bin")
                                unstash(name: "gem-centos7-3.0-bin")
                                unstash(name: "gem-centos7-3.1-bin")
                                unstash(name: "gem-alpine-2.7-bin")
                                unstash(name: "gem-alpine-3.0-bin")
                                unstash(name: "gem-alpine-3.1-bin")
                                archiveArtifacts(artifacts: "*.gem")
                            }
                            dir("gem-src") {
                                unstash(name: "gem-centos7-2.7-src")
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
                                            "/${prefix}ruby/2.7.0/latest_specs.*",
                                            "/${prefix}ruby/2.7.0/prerelease_specs.*",
                                            "/${prefix}ruby/2.7.0/specs.*",
                                            "/${prefix}ruby/3.0.0/latest_specs.*",
                                            "/${prefix}ruby/3.0.0/prerelease_specs.*",
                                            "/${prefix}ruby/3.0.0/specs.*",
                                            "/${prefix}ruby/3.1.0/latest_specs.*",
                                            "/${prefix}ruby/3.1.0/prerelease_specs.*",
                                            "/${prefix}ruby/3.1.0/specs.*",
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
