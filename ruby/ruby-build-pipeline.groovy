// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    def name = IS_PULL_REQUEST.toBoolean() ? "cv-${BUILD_NUMBER}" : "full-${BUILD_NUMBER}"
                    if (SKIP_TESTS) {
                        name += "-notest"
                    }
                    buildName(name)
                }
            }
        }
        stage('build') {
            matrix {
                axes {
                    axis {
                        name 'PLATFORM'
                        values 'macos-11.0', 'm1', 'windows', 'centos7', 'alpine', 'qe-grav2-amzn2'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("src") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("build-${PLATFORM}-${BUILD_NUMBER}") {
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
                                dir("build-${PLATFORM}-${BUILD_NUMBER}") {
                                    script {
                                        if (PLATFORM == "windows") {
                                            powershell("bin/jenkins/install-dependencies.ps1")
                                        } else {
                                            sh("bin/jenkins/install-dependencies.sh")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    stage("gem") {
                        options {
                            timeout(time: 2, unit: 'HOURS')
                        }
                        steps {
                            timestamps {
                                dir("build-${PLATFORM}-${BUILD_NUMBER}") {
                                    script {
                                        if (PLATFORM == "windows") {
                                            powershell("bin/jenkins/build-gem.ps1")
                                        } else {
                                            sh("bin/jenkins/build-gem.sh")
                                        }
                                    }
                                    dir("pkg") {
                                        stash(name: "gem-${PLATFORM}-src", includes: "*.gem")
                                        script {
                                            if (PLATFORM == "centos7") {
                                                archiveArtifacts(artifacts: "*.gem")
                                            }
                                        }
                                        dir("fat") {
                                            archiveArtifacts(artifacts: "*.gem")
                                            stash(name: "gem-${PLATFORM}-bin", includes: "*.gem")
                                        }
                                    }
                                    stash(name: "scripts-${PLATFORM}", includes: "bin/jenkins/*")
                                    stash(name: "tests-${PLATFORM}", includes: "Gemfile,test/**/*,test_data/**/*")
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
                        values 'centos7', 'ubuntu20', 'alpine', 'amzn2', 'qe-grav2-amzn2', 'qe-ubuntu20-arm64', 'macos-11.0', 'm1'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '3.1', '3.2', '3.3'
                    }
                }
                agent { label PLATFORM }
                stages {
                    stage("deps") {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("inst-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "scripts-centos7")
                                    sh("bin/jenkins/install-dependencies.sh")
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
                                            unstash(name: "gem-${PLATFORM}-bin")
                                        } else if (PLATFORM =~ /arm64/) {
                                            unstash(name: "gem-qe-grav2-amzn2-bin")
                                        } else {
                                            unstash(name: "gem-centos7-bin")
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

        stage("test") {
            when {
                expression {
                    return SKIP_TESTS.toBoolean() == false
                }
            }
            environment {
                PLATFORM = 'sdkqe-centos7'
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                        values '7.2-stable', '7.1-release', '7.0-release', '6.6-release'
                    }
                    axis {
                        name 'CB_RUBY_VERSION'
                        values '3.1', '3.2', '3.3'
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
                                    unstash(name: "scripts-centos7")
                                    sh("bin/jenkins/install-dependencies.sh")
                                }
                            }
                        }
                    }
                    stage("inst") {
                        steps {
                            timestamps {
                                dir("test-${PLATFORM}-${CB_RUBY_VERSION}-${BUILD_NUMBER}") {
                                    unstash(name: "gem-centos7-bin")
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
                                unstash(name: "gem-centos7-bin")
                                unstash(name: "tests-centos7")
                                sh("bin/jenkins/test-with-cbdyncluster ./couchbase-*.gem")
                            }
                        }
                    }
                }
            }
        }
/* TODO: revisit this section after recent changes in packaging
        stage('pub') {
            agent { label 'centos8' }
            stages {
                stage("deps") {
                    steps {
                        timestamps {
                            cleanWs()
                            dir("deps-${BUILD_NUMBER}") {
                                unstash(name: "scripts-centos7")
                                sh("bin/jenkins/install-dependencies.sh")
                            }
                        }
                    }
                }
                stage("pkg") {
                    steps {
                        cleanWs()
                        dir("repo-${BUILD_NUMBER}") {
                            unstash(name: "scripts-centos7")
                            dir("gem-bin") {
                                //unstash(name: "gem-m1-bin")
                                //unstash(name: "gem-macos-11.0-bin")
                                //unstash(name: "gem-macos-10.15-bin")
                                unstash(name: "gem-centos7-bin")
                                unstash(name: "gem-alpine-bin")
                            }
                            dir("gem-src") {
                                unstash(name: "gem-centos7-src")
                                archiveArtifacts(artifacts: "*.gem")
                            }
                        }
                    }
                }
                stage("repo") {
                    when {
                        expression {
                            return IS_PULL_REQUEST.toBoolean() == false
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
                            //sh("tar cf docs-${BUILD_NUMBER}.tar gem-doc")
                            //archiveArtifacts(artifacts: "docs-${BUILD_NUMBER}.tar", fingerprint: true)
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
                                            "/${prefix}ruby/3.1.0/latest_specs.*",
                                            "/${prefix}ruby/3.1.0/prerelease_specs.*",
                                            "/${prefix}ruby/3.1.0/specs.*",
                                            "/${prefix}ruby/3.2.0/latest_specs.*",
                                            "/${prefix}ruby/3.2.0/prerelease_specs.*",
                                            "/${prefix}ruby/3.2.0/specs.*",
                                            "/${prefix}ruby/3.3.0/latest_specs.*",
                                            "/${prefix}ruby/3.3.0/prerelease_specs.*",
                                            "/${prefix}ruby/3.3.0/specs.*",
                                        ]
                                        //, waitForCompletion: true
                                    )
                                }
                            }
                            //sh("tar cf repos-${BUILD_NUMBER}.tar repos")
                            //archiveArtifacts(artifacts: "repos-${BUILD_NUMBER}.tar", fingerprint: true)
                            script {
                                def description = sh(script: "cat description.txt", returnStdout: true).trim()
                                buildDescription(description)
                            }
                        }
                    }
                }
            }
        }
    */
    }
}
