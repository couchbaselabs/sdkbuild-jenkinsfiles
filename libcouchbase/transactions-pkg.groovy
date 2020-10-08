// vim:et ts=4 sts=4 sw=4

pipeline {
    agent none
    stages {
        stage('tar') {
            agent { label 'centos8' }
            environment {
                BOOST_LOCATION = "cbdep"
            }
            steps {
                timestamps {
                    cleanWs()
                    dir("tarball-${BUILD_NUMBER}") {
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
                                url: "$REPO",
                                poll: false
                            ]]])
                        stash(name: "scripts", includes: "scripts/**/*")
                        sh("cbdep install boost 1.67.0-cb8 -d deps")
                        sh("scripts/jenkins/build-tarball")
                        stash(name: "tarball", includes: "pkgbuild/sources/*")
                    }
                }
            }
        }
        stage('srpm') {
            agent { label 'mock' }
            steps {
                timestamps {
                    cleanWs()
                    dir("srpm-${BUILD_NUMBER}") {
                        unstash("scripts")
                        unstash("tarball")
                        sh("scripts/jenkins/build-srpm")
                        stash(name: "srpm", includes: "pkgbuild/sources/*")
                    }
                }
            }
        }
        stage('bin') {
            matrix {
                axes {
                    axis {
                        name 'CENTOS_REL'
                        values '8', '7'
                    }
                    axis {
                        name 'CENTOS_ARCH'
                        values 'x86_64'
                    }
                }
                agent { label 'mock' }
                stages {
                    stage('rpm') {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("rpm-${BUILD_NUMBER}") {
                                    unstash("scripts")
                                    unstash("srpm")
                                    sh("scripts/jenkins/build-rpm")
                                    dir("pkgbuild/results") {
                                        archiveArtifacts(artifacts: "couchbase-transactions-*.tar", fingerprint: true)
                                        script {
                                            withAWS(credentials: 'aws-sdk', region: "us-east-1") {
                                                s3Upload(
                                                    bucket: "sdk-snapshots.couchbase.com",
                                                    acl: 'PublicRead',
                                                    includePathPattern: "couchbase-transactions-*.tar",
                                                    path: "clients/transactions-cxx/",
                                                    verbose: true
                                                )
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
    }
}
