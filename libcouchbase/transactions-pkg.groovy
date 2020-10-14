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
                        sh("sudo yum install -y doxygen")
                        sh("scripts/jenkins/build-tarball")
                        stash(name: "tarball", includes: "pkgbuild/sources/*")
                        dir("pkgbuild/build") {
                            stash(name: "docs", includes: "docs-couchbase-transactions-*.tar.gz")
                            archiveArtifacts(artifacts: "docs-couchbase-transactions-*.tar.gz", fingerprint: true)
                        }
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
        stage('rpm') {
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
        stage('deb') {
            matrix {
                axes {
                    axis {
                        name 'CODENAME'
                        values 'focal', 'buster'
                    }
                }
                agent { label 'cowbuilder' }
                stages {
                    stage('cow') {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("cow-${BUILD_NUMBER}") {
                                    unstash("scripts")
                                    sh("scripts/jenkins/prepare-cowbuilder")
                                }
                            }
                        }
                    }
                    stage('deb') {
                        steps {
                            timestamps {
                                cleanWs()
                                dir("deb-${BUILD_NUMBER}") {
                                    unstash("scripts")
                                    unstash("tarball")
                                    sh("scripts/jenkins/build-deb")
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
        stage('docs') {
            agent { label 'centos8' }
            steps {
                timestamps {
                    cleanWs()
                    dir("docs-${BUILD_NUMBER}") {
                        unstash("docs")
                        sh("tar xf docs-couchbase-transactions-*.tar.gz")
                        script {
                            withAWS(credentials: 'aws-sdk', region: "us-east-1") {
                                s3Upload(
                                    bucket: "sdk-snapshots.couchbase.com",
                                    acl: 'PublicRead',
                                    includePathPattern: "couchbase-transactions-*/",
                                    path: "clients/transactions-cxx/api/",
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
