// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('prep') {
            agent any
            steps {
                script {
                    def name = IS_PULL_REQUEST.toBoolean() ? "cv-${BUILD_NUMBER}" : "full-${BUILD_NUMBER}"
                    if (SKIP_TESTS.toBoolean()) {
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
                        values 'macos', 'm1', 'windows', 'rockylinux9', 'alpine', 'qe-grav2-amzn2'
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
                                    script {
                                        if (PLATFORM == "rockylinux9") {
                                            stash(name: "scripts", includes: "bin/jenkins/*")
                                            sh("tar Jcvf scripts-and-tests.tar.xz Gemfile bin/jenkins test test_data")
                                            archiveArtifacts(artifacts: "scripts-and-tests.tar.xz")
                                        }
                                    }
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
                                        script {
                                            if (PLATFORM == "rockylinux9") {
                                                archiveArtifacts(artifacts: "*.gem")
                                            }
                                        }
                                        dir("fat") {
                                            archiveArtifacts(artifacts: "*.gem")
                                            stash(name: "gem-${PLATFORM}-bin", includes: "*.gem")
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
                        name 'PLATFORM'
                        values 'rockylinux9', 'ubuntu20', 'alpine', 'amzn2', 'qe-grav2-amzn2', 'qe-ubuntu20-arm64', 'macos', 'm1'
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
                                    unstash(name: "scripts")
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
                                            unstash(name: "gem-rockylinux9-bin")
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
            when {
                expression {
                    return !SKIP_TESTS.toBoolean()
                }
            }
            agent none
            steps {
                build(job: 'ruby-test-pipeline', wait: false)
            }
        }
    }
}
