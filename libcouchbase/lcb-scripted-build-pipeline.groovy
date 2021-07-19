
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

                stage('ubuntu20 mock') {
                    agent { label 'ubuntu20' }
                    stages {
                        stage('ubu20') {
                            steps {
                                dir('ws_ubuntu20_x64') {
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            steps {
                                dir('ws_ubuntu20_x64') {
                                    dir('build') {
                                        sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ../libcouchbase')
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''}")
                                        sh("make -j8 ${VERBOSE.toBoolean() ? 'VERBOSE=1' : ''} alltests")
                                    }
                                }
                                stash includes: 'ws_ubuntu20_x64/', name: 'ubuntu20_build'
                            }
                        }
                        stage('test') {
                            when {
                                expression {
                                    return IS_GERRIT_TRIGGER.toBoolean() && !SKIP_TESTS.toBoolean()
                                }
                            }
                            options {
                                timeout(time: 30, unit: 'MINUTES')
                            }
                            environment {
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                always {
                                    junit(testResults: "ws_ubuntu20_x64/build/*.xml", allowEmptyResults: true)
                                }
                            }
                            steps {
                                dir('ws_ubuntu20_x64/build') {
                                    sh("ulimit -a; cat /proc/sys/kernel/core_pattern || true")
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
                            when {
                                expression {
                                    return IS_GERRIT_TRIGGER.toBoolean() && !SKIP_TESTS.toBoolean()
                                }
                            }
                            options {
                                timeout(time: 30, unit: 'MINUTES')
                            }
                            environment {
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                always {
                                    junit(testResults: "ws_centos7_x64/build/*.xml", allowEmptyResults: true)
                                }
                            }
                            steps {
                                dir('ws_centos7_x64/build') {
                                    sh("ulimit -a; cat /proc/sys/kernel/core_pattern || true")
                                    sh("ctest ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                    }
                }
                stage('w64v14s') {
                    agent { label 'msvc-2015' }
                    stages {
                        stage('prep') {
                            steps {
                                dir('ws_win64_vc14_ssl') {
                                    deleteDir()
                                    bat('cbdep --platform windows_msvc2017 install  openssl 1.1.1g-sdk2')
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            steps {
                                dir('ws_win64_vc14_ssl/build') {
                                    bat('cmake --version --help')
                                    bat('cmake -G"Visual Studio 14 2015 Win64" -DOPENSSL_ROOT_DIR=..\\install\\openssl-1.1.1g-sdk2 ..\\libcouchbase')
                                    bat('cmake --build .')
                                }
                            }
                        }
                        stage('test') {
                            when {
                                expression {
                                    return !SKIP_TESTS.toBoolean()
                                }
                            }
                            options {
                                timeout(time: 30, unit: 'MINUTES')
                            }
                            environment {
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                always {
                                    junit(testResults: "ws_win64_vc14_ssl/build/*.xml", allowEmptyResults: true)
                                }
                            }
                            steps {
                                dir('ws_win64_vc14_ssl/build') {
                                    bat('cmake --build . --target alltests')
                                    bat('copy ..\\install\\openssl-1.1.1g-sdk2\\bin\\*.dll bin\\Debug\\')
                                    bat("ctest -C debug ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                        stage("pack") {
                            when {
                                expression {
                                    return !IS_GERRIT_TRIGGER.toBoolean()
                                }
                            }
                            steps {
                                dir('ws_win64_vc14_ssl/build') {
                                    bat('cmake --build . --target package')
                                    bat("move ${VERSION.tarName()}_vc14_amd64.zip ${VERSION.tarName()}_vc14_amd64_openssl.zip")
                                    archiveArtifacts(artifacts: "${VERSION.tarName()}_vc14_amd64_openssl.zip", fingerprint: true)
                                }
                            }
                        }
                    }
                }
                stage('w64v15') {
                    agent { label 'msvc-2017' }
                    stages {
                        stage('prep') {
                            steps {
                                dir('ws_win64_vc15') {
                                    deleteDir()
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            steps {
                                dir('ws_win64_vc15/build') {
                                    bat('cmake --version --help')
                                    bat('cmake -G"Visual Studio 15 2017 Win64" -DLCB_NO_SSL=1 ..\\libcouchbase')
                                    bat('cmake --build .')
                                }
                            }
                        }
                        stage('test') {
                            when {
                                expression {
                                    return !SKIP_TESTS.toBoolean()
                                }
                            }
                            options {
                                timeout(time: 30, unit: 'MINUTES')
                            }
                            environment {
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                always {
                                    junit(testResults: "ws_win64_vc15/build/*.xml", allowEmptyResults: true)
                                }
                            }
                            steps {
                                dir('ws_win64_vc15/build') {
                                    bat('cmake --build . --target alltests')
                                    bat("ctest -C debug ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                        stage("pack") {
                            when {
                                expression {
                                    return !IS_GERRIT_TRIGGER.toBoolean()
                                }
                            }
                            steps {
                                dir('ws_win64_vc15/build') {
                                    bat('cmake --build . --target package')
                                    archiveArtifacts(artifacts: "${VERSION.tarName()}_vc15_amd64.zip", fingerprint: true)
                                }
                            }
                        }
                    }
                }
                stage('w64v15s') {
                    agent { label 'msvc-2017' }
                    stages {
                        stage('prep') {
                            steps {
                                dir('ws_win64_vc15_ssl') {
                                    deleteDir()
                                    bat('cbdep --platform windows_msvc2017 install  openssl 1.1.1g-sdk2')
                                    unstash 'libcouchbase'
                                }
                            }
                        }
                        stage('build') {
                            steps {
                                dir('ws_win64_vc15_ssl/build') {
                                    bat('cmake --version --help')
                                    bat('cmake -G"Visual Studio 15 2017 Win64" -DOPENSSL_ROOT_DIR=..\\install\\openssl-1.1.1g-sdk2 ..\\libcouchbase')
                                    bat('cmake --build .')
                                }
                            }
                        }
                        stage('test') {
                            when {
                                expression {
                                    return !SKIP_TESTS.toBoolean()
                                }
                            }
                            options {
                                timeout(time: 30, unit: 'MINUTES')
                            }
                            environment {
                                CTEST_PARALLEL_LEVEL=1
                                CTEST_OUTPUT_ON_FAILURE=1
                            }
                            post {
                                always {
                                    junit(testResults: "ws_win64_vc15_ssl/build/*.xml", allowEmptyResults: true)
                                }
                            }
                            steps {
                                dir('ws_win64_vc15_ssl/build') {
                                    bat('cmake --build . --target alltests')
                                    bat('copy ..\\install\\openssl-1.1.1g-sdk2\\bin\\*.dll bin\\Debug\\')
                                    bat("ctest -C debug ${VERBOSE.toBoolean() ? '-VV' : ''}")
                                }
                            }
                        }
                        stage("pack") {
                            when {
                                expression {
                                    return !IS_GERRIT_TRIGGER.toBoolean()
                                }
                            }
                            steps {
                                dir('ws_win64_vc15_ssl/build') {
                                    bat('cmake --build . --target package')
                                    bat("move ${VERSION.tarName()}_vc15_amd64.zip ${VERSION.tarName()}_vc15_amd64_openssl.zip")
                                    archiveArtifacts(artifacts: "${VERSION.tarName()}_vc15_amd64_openssl.zip", fingerprint: true)
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
                    return !IS_GERRIT_TRIGGER.toBoolean()

                }
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                        values '5.5.6', '6.0.5', '6.5.2', '6.6-stable'//, '7.0.0-5292', '7.0-stable'
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
                        when {
                            expression {
                                return !IS_GERRIT_TRIGGER.toBoolean() && !SKIP_TESTS.toBoolean()
                            }
                        }
                        environment {
                            LCB_LOGLEVEL=5
                            LCB_TEST_CLUSTER_CONF="${CLUSTER[CB_VERSION].connectionString()}"
                            CTEST_PARALLEL_LEVEL=1
                            CTEST_OUTPUT_ON_FAILURE=1
                        }
                        options {
                            timeout(time: 30, unit: 'MINUTES')
                        }
                        steps {
                            unstash('centos7_build')
                            dir('ws_centos7_x64/build') {
                                sh("sed -i s:/home/couchbase/jenkins/workspace/lcb/lcb-scripted-build-pipeline/ws_centos7_x64/build:\$(realpath .):g tests/CTestTestfile.cmake")
                                sleep(20)
                                sh("ulimit -a; cat /proc/sys/kernel/core_pattern || true")
                                sh("ctest -E BUILD ${VERBOSE.toBoolean() ? '-VV' : ''}")
                            }
                        }
                    }
                }
            }
        }
        stage('package') {
            when {
                expression {
                    return !IS_GERRIT_TRIGGER.toBoolean()
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
    }
}
