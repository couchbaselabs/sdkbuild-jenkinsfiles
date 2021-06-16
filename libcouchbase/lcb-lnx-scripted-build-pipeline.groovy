
// DO NOT EDIT: this file was generated from Jenkinsfile.erb
class Version {
    String gitVersion;

    int major;
    int minor;
    int patch;
    int commitCount;
    String prerelease;
    String commitSha1;

    Version(String gitVersion) {
        this.gitVersion = gitVersion.trim();
        parse()
    }

    @NonCPS
    void parse() {
        def res = (gitVersion =~ /^(\d+)\.(\d+)\.(\d+)(-(beta.\d+))?(-(\d+)-g([0-9a-f]+))?$/)
        res.find()
        this.major = res.group(1) as Integer
        this.minor = res.group(2) as Integer
        this.patch = res.group(3) as Integer
        if (res.group(5)) {
            this.prerelease = res.group(5)
        }
        if (res.group(7)) {
            this.commitCount = res.group(7) as Integer
        }
        if (res.group(8)) {
            this.commitSha1 = res.group(8)
        }
    }

    String version() {
        return "${major}.${minor}.${patch}"
    }

    String tar() {
        if (commitCount == null || commitCount == 0) {
            if (prerelease != null && prerelease != "") {
                return "${version()}_${prerelease}"
            } else {
                return version()
            }
        }
        return gitVersion.replace("-", "_")
    }

    String tarName() {
        return "libcouchbase-${tar()}"
    }

    String rpmVer() {
        return version()
    }

    String rpmRel() {
        def rel = "1"
        if (prerelease) {
            rel = "0.${prerelease}"
        } else if (commitCount) {
            rel = "${commitCount + 1}.git${commitSha1}"
        }
        return rel
    }

    String srpmGlob() {
        return "libcouchbase-${version()}-${rpmRel()}*.src.rpm"
    }

    String[] rpm() {
        return [version(), rpmRel()]
    }

    String deb() {
        def ver = version()
        if (prerelease) {
            ver += "~${prerelease}"
        } else if (commitCount) {
            ver += "~r${commitCount}git${commitSha1}"
        }
        return ver
    }
}

def VERSION = new Version('0.0.0')
def CLUSTER = [:]

class DynamicCluster {
    String id_ = null;
    String ips_ = null;
    String version_ = null;

    DynamicCluster(String version) {
        this.version_ = version
    }

    boolean isAllocated() {
        return !(id_ == null || id_ == "")
    }

    String clusterId() {
        return id_
    }

    String connectionString() {
        return "couchbase://" + ips_.replaceAll(',', ';') + ",default,Administrator,password"
    }

    String firstIP() {
        return ips_.tokenize(",")[0]
    }

    String version() {
        return version_.tokenize("_")[0]
    }

    String extraOptions() {
        if (version_.tokenize("_").size() > 1) {
            return "--enable-developer-preview"
        }
        return ""
    }

    String inspect() {
        return "Cluster(id: \"${id_}\", IPs: \"${ips_}\", connstr: \"${connectionString()}\", version: \"${version_}\")"
    }
}

pipeline {
    agent none
    stages {
        stage('prepare and validate') {
            agent { label 'centos8 || centos7 || centos6' }
            steps {
                cleanWs()
                script {
                    if (IS_GERRIT_TRIGGER.toBoolean()) {
                        currentBuild.displayName = "cv-${BUILD_NUMBER}"
                    } else {
                        currentBuild.displayName = "full-${BUILD_NUMBER}"
                    }
                }

                dir('libcouchbase') {
                    checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])
                    script {
                        VERSION = new Version(sh(script: 'git describe --long --abbrev=10', returnStdout: true))
                        echo "Building ${VERSION.gitVersion}, gerrit: ${IS_GERRIT_TRIGGER}, release: ${IS_RELEASE}"
                    }
                }

                stash includes: 'libcouchbase/', name: 'libcouchbase', useDefaultExcludes: false

                dir('libcouchbase') {
                    dir('build') {
                        sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLCB_NO_PLUGINS=1 -DLCB_NO_TESTS=1 -DLCB_NO_MOCK=1 ..')
                        sh('make dist')
                        archiveArtifacts(artifacts: "${VERSION.tarName()}.tar.gz", fingerprint: true)
                        stash includes: "${VERSION.tarName()}.tar.gz", name: 'tarball', useDefaultExcludes: false
                    }
                }
            }
        }

        stage('build and test') {
            parallel {

                stage('debian9 mock') {
                    agent { label 'debian9' }
                    stages {
                        stage('deb9') {
                            steps {
                                dir('ws_debian9_x64') {
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            post {
                                failure {
                                    sh('tar cf failure-ws_debian9_x64.tar ws_debian9_x64')
                                    archiveArtifacts(artifacts: "failure-ws_debian9_x64.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_debian9_x64') {
                                    dir('build') {
                                        sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ../libcouchbase')
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''}")
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''} alltests")
                                    }
                                }
                                stash includes: 'ws_debian9_x64/', name: 'debian9_build'
                            }
                        }
                        stage('test') {
                            options {
                                timeout(time: 60, unit: 'MINUTES')
                            }
                            environment {
                                GTEST_SHUFFLE=1
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                failure {
                                    sh('tar cf failure-ws_debian9_x64.tar ws_debian9_x64')
                                    archiveArtifacts(artifacts: "failure-ws_debian9_x64.tar", fingerprint: false)
                                }
                                always {
                                    junit("ws_debian9_x64/build/*.xml")
                                }
                            }
                            steps {
                                dir('ws_debian9_x64/build') {
                                    sh("sudo apt update; sudo apt install -y gdb");
                                    sh("ulimit -c; cat /proc/sys/kernel/core_pattern || true")
                                    sh("ctest ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                    }
                }
                stage('centos7 mock') {
                    agent { label 'centos7' }
                    stages {
                        stage('cen7') {
                            steps {
                                dir('ws_centos7_x64') {
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            post {
                                failure {
                                    sh('tar cf failure-ws_centos7_x64.tar ws_centos7_x64')
                                    archiveArtifacts(artifacts: "failure-ws_centos7_x64.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_centos7_x64') {
                                    dir('build') {
                                        sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ../libcouchbase')
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''}")
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''} alltests")
                                    }
                                }
                                stash includes: 'ws_centos7_x64/', name: 'centos7_build'
                            }
                        }
                        stage('test') {
                            options {
                                timeout(time: 60, unit: 'MINUTES')
                            }
                            environment {
                                GTEST_SHUFFLE=1
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                failure {
                                    sh('tar cf failure-ws_centos7_x64.tar ws_centos7_x64')
                                    archiveArtifacts(artifacts: "failure-ws_centos7_x64.tar", fingerprint: false)
                                }
                                always {
                                    junit("ws_centos7_x64/build/*.xml")
                                }
                            }
                            steps {
                                dir('ws_centos7_x64/build') {
                                    sh("sudo yum install -y gdb");
                                    sh("ulimit -c; cat /proc/sys/kernel/core_pattern || true")
                                    sh("ctest ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                    }
                }
            }
        }
        stage('int') {
            when {
                expression {
                    return IS_GERRIT_TRIGGER.toBoolean() == false
                }
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                        values '5.5.6', '6.0.4', '6.5.1', '6.5.1_DP', '6.6-stable', '7.0-stable'
                    }
                }
                agent { label 'sdkqe-centos7' }
                stages {
                    stage("env") {
                        steps {
                            sh("cbdyncluster ps -a")
                            script {
                                def cluster = new DynamicCluster(CB_VERSION)
                                cluster.id_ = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version=${cluster.version()}", returnStdout: true).trim()
                                cluster.ips_ = sh(script: "cbdyncluster ips ${cluster.clusterId()}", returnStdout: true).trim()
                                CLUSTER[CB_VERSION] = cluster
                            }
                            echo("Allocated ${CLUSTER[CB_VERSION].inspect()}")
                            sh("cbdyncluster setup ${CLUSTER[CB_VERSION].clusterId()} --node=kv,index,n1ql,fts --node=kv --node=kv --bucket=default ${CLUSTER[CB_VERSION].extraOptions()}")
                            sh("curl --trace - --trace-time -sS -uAdministrator:password http://${CLUSTER[CB_VERSION].firstIP()}:8091/settings/indexes -d 'storageMode=plasma'")
                            sh("cbdyncluster add-sample-bucket ${CLUSTER[CB_VERSION].clusterId()} --name=beer-sample")
                            sh("curl --trace - --trace-time -sS -uAdministrator:password http://${CLUSTER[CB_VERSION].firstIP()}:8093/query/service -d'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                            sleep(20)
                            sh("curl --trace - --trace-time -sS -uAdministrator:password http://${CLUSTER[CB_VERSION].firstIP()}:8093/query/service -d'statement=SELECT * FROM system:indexes' -d 'timeout=300s'")
                        }
                    }
                    stage('test') {
                        post {
                            failure {
                                sh("tar cf integration_failure-${CB_VERSION}_x64.tar ws_centos7_x64")
                                archiveArtifacts(artifacts: "integration_failure-${CB_VERSION}_x64.tar", fingerprint: false)
                            }
                        }
                        environment {
                            LCB_LOGLEVEL=5
                            LCB_TEST_CLUSTER_CONF="${CLUSTER[CB_VERSION].connectionString()}"
                            GTEST_SHUFFLE=1
                            CTEST_PARALLEL_LEVEL=1
                            CTEST_OUTPUT_ON_FAILURE=1
                        }
                        steps {
                            unstash('centos7_build')
                            dir('ws_centos7_x64/build') {
                                sh("sed -i s:/home/couchbase/jenkins/workspace/lcb/lcb-scripted-build-pipeline/ws_centos7_x64/build:\$(realpath .):g tests/CTestTestfile.cmake")
                                sleep(20)
                                timeout(time: 60, unit: 'MINUTES') {
                                    sh("sudo yum install -y gdb");
                                    sh("ulimit -c; cat /proc/sys/kernel/core_pattern || true")
                                    sh("ctest -E BUILD ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                    }
                }
            }
        }
        stage('package') {
            when {
                expression {
                    return IS_GERRIT_TRIGGER.toBoolean() == false
                }
            }
            parallel {
                stage('centos7 x86_64') {
                    agent { label 'mock' }
                    stages {
                        stage('c64v7') {
                            steps {
                                dir('ws_centos64_v7') {
                                    sh("sudo chown couchbase:couchbase -R .")
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('srpm') {
                            post {
                                failure {
                                    sh("tar cf failure-ws_centos64_v7.tar ws_centos64_v7")
                                    archiveArtifacts(artifacts: "failure-ws_centos64_v7.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_centos64_v7/build') {
                                    unstash 'tarball'
                                    sh("""
                                        sed 's/@VERSION@/${VERSION.rpmVer()}/g;s/@RELEASE@/${VERSION.rpmRel()}/g;s/@TARREDAS@/${VERSION.tarName()}/g' \
                                        < ../libcouchbase/packaging/rpm/libcouchbase.spec.in > libcouchbase.spec
                                    """.stripIndent())
                                    sh("""
                                        sudo mock --buildsrpm -r epel-7-x86_64 --spec libcouchbase.spec --sources ${pwd()} --old-chroot \
                                        --resultdir="libcouchbase-${VERSION.tar()}_centos7_srpm"
                                    """.stripIndent())
                                }
                            }
                        }
                        stage('rpm') {
                            post {
                                failure {
                                    sh("tar cf failure-ws_centos64_v7.tar ws_centos64_v7")
                                    archiveArtifacts(artifacts: "failure-ws_centos64_v7.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_centos64_v7/build') {
                                    sh("""
                                        sudo mock --rebuild -r epel-7-x86_64 --resultdir="libcouchbase-${VERSION.tar()}_centos7_x86_64" --old-chroot \
                                        --verbose libcouchbase-${VERSION.tar()}_centos7_srpm/libcouchbase-${VERSION.version()}-${VERSION.rpmRel()}.el7.src.rpm
                                    """.stripIndent())
                                    sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.tar()}_centos7_x86_64")
                                    sh("rm -rf libcouchbase-${VERSION.tar()}_centos7_x86_64/*.log")
                                    sh("tar cf libcouchbase-${VERSION.tar()}_centos7_x86_64.tar libcouchbase-${VERSION.tar()}_centos7_x86_64")
                                    archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_centos7_x86_64.tar", fingerprint: true)
                                    stash(includes: "libcouchbase-${VERSION.tar()}_centos7_x86_64/*.src.rpm", name: 'centos7-srpm')
                                }
                            }
                        }
                    }
                }
                stage('centos8 x86_64') {
                    agent { label 'mock' }
                    stages {
                        stage('c64v8') {
                            steps {
                                dir('ws_centos64_v8') {
                                    sh("sudo chown couchbase:couchbase -R .")
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('srpm') {
                            post {
                                failure {
                                    sh("tar cf failure-ws_centos64_v8.tar ws_centos64_v8")
                                    archiveArtifacts(artifacts: "failure-ws_centos64_v8.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_centos64_v8/build') {
                                    unstash 'tarball'
                                    sh("""
                                        sed 's/@VERSION@/${VERSION.rpmVer()}/g;s/@RELEASE@/${VERSION.rpmRel()}/g;s/@TARREDAS@/${VERSION.tarName()}/g' \
                                        < ../libcouchbase/packaging/rpm/libcouchbase.spec.in > libcouchbase.spec
                                    """.stripIndent())
                                    sh("""
                                        sudo mock --buildsrpm -r epel-8-x86_64 --spec libcouchbase.spec --sources ${pwd()} --old-chroot \
                                        --resultdir="libcouchbase-${VERSION.tar()}_centos8_srpm"
                                    """.stripIndent())
                                }
                            }
                        }
                        stage('rpm') {
                            post {
                                failure {
                                    sh("tar cf failure-ws_centos64_v8.tar ws_centos64_v8")
                                    archiveArtifacts(artifacts: "failure-ws_centos64_v8.tar", fingerprint: false)
                                }
                            }
                            steps {
                                dir('ws_centos64_v8/build') {
                                    sh("""
                                        sudo mock --rebuild -r epel-8-x86_64 --resultdir="libcouchbase-${VERSION.tar()}_centos8_x86_64" --old-chroot \
                                        --verbose libcouchbase-${VERSION.tar()}_centos8_srpm/libcouchbase-${VERSION.version()}-${VERSION.rpmRel()}.el8.src.rpm
                                    """.stripIndent())
                                    sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.tar()}_centos8_x86_64")
                                    sh("rm -rf libcouchbase-${VERSION.tar()}_centos8_x86_64/*.log")
                                    sh("tar cf libcouchbase-${VERSION.tar()}_centos8_x86_64.tar libcouchbase-${VERSION.tar()}_centos8_x86_64")
                                    archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_centos8_x86_64.tar", fingerprint: true)
                                }
                            }
                        }
                    }
                }
                    stage('ubuntu2004 amd64') {
                        agent { label 'cowbuilder' }
                        stages {
                            stage('u64v20') {
                                steps {
                                    dir('ws_ubuntu2004_amd64') {
                                        sh("sudo chown couchbase:couchbase -R .")
                                        deleteDir()
                                        unstash 'libcouchbase'
                                    }
                                }
                            }
                            stage('cow1') {
                                when {
                                    expression {
                                        !fileExists("/var/cache/pbuilder/focal-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh("""
                                        sudo apt-get install cowbuilder && \
                                        sudo cowbuilder --create \
                                        --basepath /var/cache/pbuilder/focal-amd64.cow \
                                        --distribution focal \
                                        --debootstrapopts --arch=amd64 \
                                        --components 'main universe' --mirror http://ftp.ubuntu.com/ubuntu --debootstrapopts --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
                                    """.stripIndent())
                                }
                            }
                            stage('cow2') {
                                when {
                                    expression {
                                        fileExists("/var/cache/pbuilder/focal-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh('sudo cowbuilder --update --basepath /var/cache/pbuilder/focal-amd64.cow')
                                }
                            }
                            stage('src') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu2004_amd64.tar ws_ubuntu2004_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu2004_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu2004_amd64/build') {
                                        unstash 'tarball'
                                        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
                                        sh("tar -xf ${VERSION.tarName()}.tar.gz")
                                        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
                                        dir(VERSION.tarName()) {
                                            sh("""
                                                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 \
                                                --create "Release package for libcouchbase ${VERSION.deb()}-1"
                                            """.stripIndent())
                                            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
                                        }
                                    }
                                }
                            }
                            stage('deb') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu2004_amd64.tar ws_ubuntu2004_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu2004_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu2004_amd64/build') {
                                        sh("""
                                           sudo cowbuilder --build \
                                           --basepath /var/cache/pbuilder/focal-amd64.cow \
                                           --buildresult libcouchbase-${VERSION.deb()}_ubuntu2004_focal_amd64 \
                                           --debbuildopts -j8 \
                                           --debbuildopts "-us -uc" \
                                           libcouchbase_${VERSION.deb()}-1.dsc
                                        """.stripIndent())
                                        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_ubuntu2004_focal_amd64")
                                        sh("tar cf libcouchbase-${VERSION.tar()}_ubuntu2004_focal_amd64.tar libcouchbase-${VERSION.deb()}_ubuntu2004_focal_amd64")
                                        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_ubuntu2004_focal_amd64.tar", fingerprint: true)
                                    }
                                }
                            }
                        }
                    }
                    stage('ubuntu1804 amd64') {
                        agent { label 'cowbuilder' }
                        stages {
                            stage('u64v18') {
                                steps {
                                    dir('ws_ubuntu1804_amd64') {
                                        sh("sudo chown couchbase:couchbase -R .")
                                        deleteDir()
                                        unstash 'libcouchbase'
                                    }
                                }
                            }
                            stage('cow1') {
                                when {
                                    expression {
                                        !fileExists("/var/cache/pbuilder/bionic-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh("""
                                        sudo apt-get install cowbuilder && \
                                        sudo cowbuilder --create \
                                        --basepath /var/cache/pbuilder/bionic-amd64.cow \
                                        --distribution bionic \
                                        --debootstrapopts --arch=amd64 \
                                        --components 'main universe' --mirror http://ftp.ubuntu.com/ubuntu --debootstrapopts --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
                                    """.stripIndent())
                                }
                            }
                            stage('cow2') {
                                when {
                                    expression {
                                        fileExists("/var/cache/pbuilder/bionic-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh('sudo cowbuilder --update --basepath /var/cache/pbuilder/bionic-amd64.cow')
                                }
                            }
                            stage('src') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu1804_amd64.tar ws_ubuntu1804_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu1804_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu1804_amd64/build') {
                                        unstash 'tarball'
                                        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
                                        sh("tar -xf ${VERSION.tarName()}.tar.gz")
                                        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
                                        dir(VERSION.tarName()) {
                                            sh("""
                                                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 \
                                                --create "Release package for libcouchbase ${VERSION.deb()}-1"
                                            """.stripIndent())
                                            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
                                        }
                                    }
                                }
                            }
                            stage('deb') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu1804_amd64.tar ws_ubuntu1804_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu1804_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu1804_amd64/build') {
                                        sh("""
                                           sudo cowbuilder --build \
                                           --basepath /var/cache/pbuilder/bionic-amd64.cow \
                                           --buildresult libcouchbase-${VERSION.deb()}_ubuntu1804_bionic_amd64 \
                                           --debbuildopts -j8 \
                                           --debbuildopts "-us -uc" \
                                           libcouchbase_${VERSION.deb()}-1.dsc
                                        """.stripIndent())
                                        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_ubuntu1804_bionic_amd64")
                                        sh("tar cf libcouchbase-${VERSION.tar()}_ubuntu1804_bionic_amd64.tar libcouchbase-${VERSION.deb()}_ubuntu1804_bionic_amd64")
                                        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_ubuntu1804_bionic_amd64.tar", fingerprint: true)
                                    }
                                }
                            }
                        }
                    }
                    stage('ubuntu1604 amd64') {
                        agent { label 'cowbuilder' }
                        stages {
                            stage('u64v16') {
                                steps {
                                    dir('ws_ubuntu1604_amd64') {
                                        sh("sudo chown couchbase:couchbase -R .")
                                        deleteDir()
                                        unstash 'libcouchbase'
                                    }
                                }
                            }
                            stage('cow1') {
                                when {
                                    expression {
                                        !fileExists("/var/cache/pbuilder/xenial-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh("""
                                        sudo apt-get install cowbuilder && \
                                        sudo cowbuilder --create \
                                        --basepath /var/cache/pbuilder/xenial-amd64.cow \
                                        --distribution xenial \
                                        --debootstrapopts --arch=amd64 \
                                        --components 'main universe' --mirror http://ftp.ubuntu.com/ubuntu --debootstrapopts --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
                                    """.stripIndent())
                                }
                            }
                            stage('cow2') {
                                when {
                                    expression {
                                        fileExists("/var/cache/pbuilder/xenial-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh('sudo cowbuilder --update --basepath /var/cache/pbuilder/xenial-amd64.cow')
                                }
                            }
                            stage('src') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu1604_amd64.tar ws_ubuntu1604_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu1604_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu1604_amd64/build') {
                                        unstash 'tarball'
                                        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
                                        sh("tar -xf ${VERSION.tarName()}.tar.gz")
                                        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
                                        dir(VERSION.tarName()) {
                                            sh("""
                                                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 \
                                                --create "Release package for libcouchbase ${VERSION.deb()}-1"
                                            """.stripIndent())
                                            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
                                        }
                                    }
                                }
                            }
                            stage('deb') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_ubuntu1604_amd64.tar ws_ubuntu1604_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_ubuntu1604_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_ubuntu1604_amd64/build') {
                                        sh("""
                                           sudo cowbuilder --build \
                                           --basepath /var/cache/pbuilder/xenial-amd64.cow \
                                           --buildresult libcouchbase-${VERSION.deb()}_ubuntu1604_xenial_amd64 \
                                           --debbuildopts -j8 \
                                           --debbuildopts "-us -uc" \
                                           libcouchbase_${VERSION.deb()}-1.dsc
                                        """.stripIndent())
                                        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_ubuntu1604_xenial_amd64")
                                        sh("tar cf libcouchbase-${VERSION.tar()}_ubuntu1604_xenial_amd64.tar libcouchbase-${VERSION.deb()}_ubuntu1604_xenial_amd64")
                                        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_ubuntu1604_xenial_amd64.tar", fingerprint: true)
                                    }
                                }
                            }
                        }
                    }
                    stage('debian9 amd64') {
                        agent { label 'cowbuilder' }
                        stages {
                            stage('d64v9') {
                                steps {
                                    dir('ws_debian9_amd64') {
                                        sh("sudo chown couchbase:couchbase -R .")
                                        deleteDir()
                                        unstash 'libcouchbase'
                                    }
                                }
                            }
                            stage('cow1') {
                                when {
                                    expression {
                                        !fileExists("/var/cache/pbuilder/stretch-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh("""
                                        sudo apt-get install cowbuilder && \
                                        sudo cowbuilder --create \
                                        --basepath /var/cache/pbuilder/stretch-amd64.cow \
                                        --distribution stretch \
                                        --debootstrapopts --arch=amd64 \
                                         --components 'main'
                                    """.stripIndent())
                                }
                            }
                            stage('cow2') {
                                when {
                                    expression {
                                        fileExists("/var/cache/pbuilder/stretch-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh('sudo cowbuilder --update --basepath /var/cache/pbuilder/stretch-amd64.cow')
                                }
                            }
                            stage('src') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_debian9_amd64.tar ws_debian9_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_debian9_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_debian9_amd64/build') {
                                        unstash 'tarball'
                                        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
                                        sh("tar -xf ${VERSION.tarName()}.tar.gz")
                                        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
                                        dir(VERSION.tarName()) {
                                            sh("""
                                                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 \
                                                --create "Release package for libcouchbase ${VERSION.deb()}-1"
                                            """.stripIndent())
                                            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
                                        }
                                    }
                                }
                            }
                            stage('deb') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_debian9_amd64.tar ws_debian9_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_debian9_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_debian9_amd64/build') {
                                        sh("""
                                           sudo cowbuilder --build \
                                           --basepath /var/cache/pbuilder/stretch-amd64.cow \
                                           --buildresult libcouchbase-${VERSION.deb()}_debian9_stretch_amd64 \
                                           --debbuildopts -j8 \
                                           --debbuildopts "-us -uc" \
                                           libcouchbase_${VERSION.deb()}-1.dsc
                                        """.stripIndent())
                                        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_debian9_stretch_amd64")
                                        sh("tar cf libcouchbase-${VERSION.tar()}_debian9_stretch_amd64.tar libcouchbase-${VERSION.deb()}_debian9_stretch_amd64")
                                        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_debian9_stretch_amd64.tar", fingerprint: true)
                                    }
                                }
                            }
                        }
                    }
                    stage('debian10 amd64') {
                        agent { label 'cowbuilder' }
                        stages {
                            stage('d64v10') {
                                steps {
                                    dir('ws_debian10_amd64') {
                                        sh("sudo chown couchbase:couchbase -R .")
                                        deleteDir()
                                        unstash 'libcouchbase'
                                    }
                                }
                            }
                            stage('cow1') {
                                when {
                                    expression {
                                        !fileExists("/var/cache/pbuilder/buster-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh("""
                                        sudo apt-get install cowbuilder && \
                                        sudo cowbuilder --create \
                                        --basepath /var/cache/pbuilder/buster-amd64.cow \
                                        --distribution buster \
                                        --debootstrapopts --arch=amd64 \
                                         --components 'main'
                                    """.stripIndent())
                                }
                            }
                            stage('cow2') {
                                when {
                                    expression {
                                        fileExists("/var/cache/pbuilder/buster-amd64.cow/etc/os-release")
                                    }
                                }
                                steps {
                                    sh('sudo cowbuilder --update --basepath /var/cache/pbuilder/buster-amd64.cow')
                                }
                            }
                            stage('src') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_debian10_amd64.tar ws_debian10_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_debian10_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_debian10_amd64/build') {
                                        unstash 'tarball'
                                        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
                                        sh("tar -xf ${VERSION.tarName()}.tar.gz")
                                        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
                                        dir(VERSION.tarName()) {
                                            sh("""
                                                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 \
                                                --create "Release package for libcouchbase ${VERSION.deb()}-1"
                                            """.stripIndent())
                                            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
                                        }
                                    }
                                }
                            }
                            stage('deb') {
                                post {
                                    failure {
                                        sh("tar cf failure-ws_debian10_amd64.tar ws_debian10_amd64")
                                        archiveArtifacts(artifacts: "failure-ws_debian10_amd64.tar", fingerprint: false)
                                    }
                                }
                                steps {
                                    dir('ws_debian10_amd64/build') {
                                        sh("""
                                           sudo cowbuilder --build \
                                           --basepath /var/cache/pbuilder/buster-amd64.cow \
                                           --buildresult libcouchbase-${VERSION.deb()}_debian10_buster_amd64 \
                                           --debbuildopts -j8 \
                                           --debbuildopts "-us -uc" \
                                           libcouchbase_${VERSION.deb()}-1.dsc
                                        """.stripIndent())
                                        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_debian10_buster_amd64")
                                        sh("tar cf libcouchbase-${VERSION.tar()}_debian10_buster_amd64.tar libcouchbase-${VERSION.deb()}_debian10_buster_amd64")
                                        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_debian10_buster_amd64.tar", fingerprint: true)
                                    }
                                }
                            }
                        }
                    }
            }
        }
        stage('amzn2') {
            agent { label 'amzn2' }
            steps {
                sh('sudo yum install -y rpm-build yum-utils; cat /etc/os-release"')
                cleanWs()
                unstash('centos7-srpm')
                sh('sudo yum-builddep -y libcouchbase-*/*.src.rpm')
                sh('rpmbuild --rebuild libcouchbase-*/*.src.rpm -D "_rpmdir output"')
                dir('output') {
                    sh("mv x86_64 libcouchbase-${VERSION.tar()}_amzn2_x86_64")
                    sh("tar cf libcouchbase-${VERSION.tar()}_amzn2_x86_64.tar libcouchbase-${VERSION.tar()}_amzn2_x86_64")
                    archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_amzn2_x86_64.tar", fingerprint: true)
                }
            }
        }
        stage('repositories') {
            when {
                expression {
                    return IS_GERRIT_TRIGGER.toBoolean() == false
                }
            }
            agent none
            steps {
                build(job: 'lcb-repo-pipeline')
            }
        }
    }
}
