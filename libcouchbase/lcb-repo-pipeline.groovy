
// DO NOT EDIT: this file was generated from Jenkinsfile.repo.erb

pipeline {
    agent none
    stages {
        stage('repos') {
            parallel {


                stage('centos7 x86_64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_centos7_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*x86_64.tar")
                        sh('mkdir -p repo/el7/x86_64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-centos7-x86_64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for centos7 x86_64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/el7/x86_64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*x86_64/*rpm repo/el7/x86_64')
                        sh('for p in repo/el7/x86_64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/el7/x86_64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/el7/x86_64/repodata/repomd.xml")
                        sh("rm -rf repo/el7/x86_64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-centos7-x86_64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-centos7-x86_64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('rhel8 x86_64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_rhel8_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*x86_64.tar")
                        sh('mkdir -p repo/el8/x86_64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-rhel8-x86_64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for rhel8 x86_64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/el8/x86_64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*x86_64/*rpm repo/el8/x86_64')
                        sh('for p in repo/el8/x86_64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/el8/x86_64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/el8/x86_64/repodata/repomd.xml")
                        sh("rm -rf repo/el8/x86_64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-rhel8-x86_64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-rhel8-x86_64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('rhel9 x86_64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_rhel9_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*x86_64.tar")
                        sh('mkdir -p repo/el9/x86_64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-rhel9-x86_64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for rhel9 x86_64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/el9/x86_64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*x86_64/*rpm repo/el9/x86_64')
                        sh('for p in repo/el9/x86_64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/el9/x86_64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/el9/x86_64/repodata/repomd.xml")
                        sh("rm -rf repo/el9/x86_64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-rhel9-x86_64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-rhel9-x86_64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('amzn2 x86_64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_amzn2_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*x86_64.tar")
                        sh('mkdir -p repo/amzn2/x86_64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-amzn2-x86_64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for amzn2 x86_64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/amzn2/x86_64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*x86_64/*rpm repo/amzn2/x86_64')
                        sh('for p in repo/amzn2/x86_64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/amzn2/x86_64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/amzn2/x86_64/repodata/repomd.xml")
                        sh("rm -rf repo/amzn2/x86_64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-amzn2-x86_64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-amzn2-x86_64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('amzn2 aarch64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_amzn2_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*aarch64.tar")
                        sh('mkdir -p repo/amzn2/aarch64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-amzn2-aarch64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for amzn2 aarch64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/amzn2/aarch64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*aarch64/*rpm repo/amzn2/aarch64')
                        sh('for p in repo/amzn2/aarch64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/amzn2/aarch64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/amzn2/aarch64/repodata/repomd.xml")
                        sh("rm -rf repo/amzn2/aarch64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-amzn2-aarch64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-amzn2-aarch64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('amzn2023 x86_64') {
                    agent { label 'centos7-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*_amzn2023_*.tar')
                        writeFile(file: "rpmsign-wrapper.expect", text: """
set pkgName [lrange \$argv 0 0]
spawn rpm --addsign -D "_signature gpg" -D "_gpg_name ${GPG_NAME}" \$pkgName
expect -exact "Enter pass phrase: "
send -- "\\r"
expect eof
wait
""")
                        sh("tar xf libcouchbase-*x86_64.tar")
                        sh('mkdir -p repo/amzn2023/x86_64')
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-amzn2023-x86_64.repo', text: """
[couchbase]
enabled = 1
name = libcouchbase package for amzn2023 x86_64
baseurl = https://sdk-snapshots.couchbase.com/libcouchbase/amzn2023/x86_64
gpgcheck = 1
gpgkey = https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key
""")
                        }
                        sh('cp -a libcouchbase-*x86_64/*rpm repo/amzn2023/x86_64')
                        sh('for p in repo/amzn2023/x86_64/*.rpm; do expect rpmsign-wrapper.expect \$p; done')
                        sh('createrepo --checksum sha repo/amzn2023/x86_64')
                        sh("gpg --batch --yes --local-user ${GPG_NAME} --detach-sign --armor repo/amzn2023/x86_64/repodata/repomd.xml")
                        sh("rm -rf repo/amzn2023/x86_64@tmp")
                        sh("tar cf repo-${BUILD_NUMBER}-amzn2023-x86_64.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-amzn2023-x86_64.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/',
                            )
                        }
                    }
                }

                stage('ubuntu2204') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*jammy*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/ubuntu2204/conf')
                        writeFile(file: "repo/ubuntu2204/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: jammy
Codename: jammy
Version: ubuntu2204
Components: jammy/main
Architectures: amd64
Description: libcouchbase package repository for jammy ubuntu2204
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-ubuntu2204.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/ubuntu2204 jammy jammy/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/ubuntu2204 include jammy \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-ubuntu2204.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-ubuntu2204.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('debian12') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*bookworm*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/debian12/conf')
                        writeFile(file: "repo/debian12/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: bookworm
Codename: bookworm
Version: debian12
Components: bookworm/main
Architectures: amd64
Description: libcouchbase package repository for bookworm debian12
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-debian12.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/debian12 bookworm bookworm/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/debian12 include bookworm \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-debian12.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-debian12.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('debian11') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*bullseye*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/debian11/conf')
                        writeFile(file: "repo/debian11/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: bullseye
Codename: bullseye
Version: debian11
Components: bullseye/main
Architectures: amd64
Description: libcouchbase package repository for bullseye debian11
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-debian11.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/debian11 bullseye bullseye/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/debian11 include bullseye \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-debian11.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-debian11.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('ubuntu2004') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*focal*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/ubuntu2004/conf')
                        writeFile(file: "repo/ubuntu2004/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: focal
Codename: focal
Version: ubuntu2004
Components: focal/main
Architectures: amd64
Description: libcouchbase package repository for focal ubuntu2004
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-ubuntu2004.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/ubuntu2004 focal focal/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/ubuntu2004 include focal \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-ubuntu2004.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-ubuntu2004.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('debian10') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*buster*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/debian10/conf')
                        writeFile(file: "repo/debian10/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: buster
Codename: buster
Version: debian10
Components: buster/main
Architectures: amd64
Description: libcouchbase package repository for buster debian10
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-debian10.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/debian10 buster buster/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/debian10 include buster \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-debian10.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-debian10.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('ubuntu1804') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*bionic*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/ubuntu1804/conf')
                        writeFile(file: "repo/ubuntu1804/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: bionic
Codename: bionic
Version: ubuntu1804
Components: bionic/main
Architectures: amd64
Description: libcouchbase package repository for bionic ubuntu1804
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-ubuntu1804.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/ubuntu1804 bionic bionic/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/ubuntu1804 include bionic \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-ubuntu1804.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-ubuntu1804.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
                stage('ubuntu1604') {

                    agent { label 'debian10-signing' }
                    steps {
                        cleanWs()
                        copyArtifacts(projectName: 'lcb-lnx-scripted-build-pipeline', selector: UPSTREAM_BUILD.isEmpty() ? upstream() : specific(UPSTREAM_BUILD), filter: 'libcouchbase-*xenial*.tar')
                        sh('which reprepro; reprepro --version; mkdir -p repo/ubuntu1604/conf')
                        writeFile(file: "repo/ubuntu1604/conf/distributions", text: """
Origin: couchbase
SignWith: ${GPG_NAME}
Suite: xenial
Codename: xenial
Version: ubuntu1604
Components: xenial/main
Architectures: amd64
Description: libcouchbase package repository for xenial ubuntu1604
""")
                        sh("for p in libcouchbase-*.tar; do tar xf \$p; done")
                        dir('repo') {
                            sh("gpg --export --armor ${GPG_NAME} > couchbase.key")
                            writeFile(file: 'libcouchbase-ubuntu1604.list', text: """
# curl https://sdk-snapshots.couchbase.com/libcouchbase/couchbase.key | sudo apt-key add -
deb https://sdk-snapshots.couchbase.com/libcouchbase/ubuntu1604 xenial xenial/main
""")
                        }
                        sh("for p in \$(find . -name '*amd64.changes'); do reprepro -T deb --ignore=wrongdistribution -b repo/ubuntu1604 include xenial \$p; done")
                        sh("tar cf repo-${BUILD_NUMBER}-ubuntu1604.tar repo")
                        archiveArtifacts(artifacts: "repo-${BUILD_NUMBER}-ubuntu1604.tar", fingerprint: true)
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: 'repo/',
                                path: 'libcouchbase/'
                            )
                        }
                    }
                }
            }
        }
    }
}
