
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
    boolean useTLS = false;
    boolean useCertAuth = false;
    String certsDir = null;

    DynamicCluster(String version) {
        this.version_ = version
    }

    String clusterId() {
        return id_
    }

    String connectionString() {
        def prefix = "couchbase://"
        if (useTLS) {
            prefix = "couchbases://"
        }
        def connstr = prefix + ips_.replaceAll(',', ';')
        def bucket = ",default"
        def auth = ",Administrator,password"
        if (useTLS) {
            connstr += "?truststorepath=$certsDir/ca.pem"
        }
        if (useCertAuth) {
            auth = ""
            connstr += "&certpath=$certsDir/client.pem&keypath=$certsDir/client.key"
        }
        return connstr + bucket + auth
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

    int major() {
        return version().tokenize(".")[0] as Integer
    }

    int minor() {
        // e.g. 7.1-stable or 7.1.0 becomes 1
        return version().tokenize("-")[0].tokenize(".")[1] as Integer
    }

    int numRootCAs() {
        if (major() > 7 || (major() == 7 && minor() >= 1)) {
            return 2
        } else {
            return 1
        }
    }

    String inspect() {
        return "Cluster(id: \"${id_}\", IPs: \"${ips_}\", connstr: \"${connectionString()}\", version: \"${version_}\")"
    }
}

def package_src(name, arch, codename, VERSION) {
    dir("ws_${name}_${arch}/build") {
        unstash 'tarball'
        sh("ln -s ${VERSION.tarName()}.tar.gz libcouchbase_${VERSION.deb()}.orig.tar.gz")
        sh("tar -xf ${VERSION.tarName()}.tar.gz")
        sh("sed -i 's/dh_auto_test /true /g;s/LCB_NO_MOCK=1/LCB_NO_MOCK=1 -DLCB_BUILD_DTRACE=0/g' ../libcouchbase/packaging/deb/rules")
        sh("cp -a ../libcouchbase/packaging/deb ${VERSION.tarName()}/debian")
        dir(VERSION.tarName()) {
            sh("""
                DEBEMAIL=support@couchbase.com \
                dch --no-auto-nmu --package libcouchbase --newversion ${VERSION.deb()}-1 --distribution ${codename} \
                --create "Release package for libcouchbase ${VERSION.deb()}-1"
            """.stripIndent())
            sh("dpkg-buildpackage -rfakeroot -d -S -sa")
        }
    }
}

def package_deb(name, arch, codename, VERSION) {
    dir("ws_${name}_${arch}/build") {
        sh("""
            sudo cowbuilder --build \
            --basepath /var/cache/pbuilder/${codename}-${arch}.cow \
            --buildresult libcouchbase-${VERSION.deb()}_${name}_${codename}_${arch} \
            --debbuildopts -j8 \
            --debbuildopts "-us -uc" \
            libcouchbase_${VERSION.deb()}-1.dsc
        """.stripIndent())
        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.deb()}_${name}_${codename}_${arch}")
        sh("tar cf libcouchbase-${VERSION.tar()}_${name}_${codename}_${arch}.tar libcouchbase-${VERSION.deb()}_${name}_${codename}_${arch}")
        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_${name}_${codename}_${arch}.tar", fingerprint: true)
    }
}

def package_srpm(name, bits, relno, arch, mock, VERSION) {
    dir("ws_${name}${relno}-${bits}/build") {
        unstash 'tarball'
        if (!(relno == 7 && name == 'centos')) {
            sh("sed -i 's/openssl11-devel/openssl-devel/g' ../libcouchbase/packaging/rpm/libcouchbase.spec.in")
        }
        if (relno == 2023 && name == 'amzn') {
            sh("sed -i '1i %undefine _package_note_file\\nBuildRequires: redhat-rpm-config' ../libcouchbase/packaging/rpm/libcouchbase.spec.in")
        }
        sh("""
            sed 's/@VERSION@/${VERSION.rpmVer()}/g;s/@RELEASE@/${VERSION.rpmRel()}/g;s/@TARREDAS@/${VERSION.tarName()}/g;s/NO_MOCK=1/NO_MOCK=1 -DLCB_BUILD_DTRACE=0/g;/systemtap/d;s/^make.*test/true/g' \
            < ../libcouchbase/packaging/rpm/libcouchbase.spec.in > libcouchbase.spec
        """.stripIndent())
        sh("""
            sudo mock --buildsrpm -r ${mock} --spec libcouchbase.spec --sources ${pwd()} --old-chroot \
            --resultdir="libcouchbase-${VERSION.tar()}_${name}${relno}_srpm"
        """.stripIndent())
        sh("find libcouchbase-${VERSION.tar()}_${name}${relno}_srpm/")
        stash(includes: "libcouchbase-${VERSION.tar()}_${name}${relno}_srpm/*.src.rpm", name: "${name}${relno}-srpm")
    }
}

def package_rpm(name, bits, relno, arch, mock, VERSION) {
    dir("ws_${name}${relno}-${bits}/build") {
        sh("""
            sudo mock --rebuild -r ${mock} --resultdir="libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}" --old-chroot \
            --verbose libcouchbase-${VERSION.tar()}_${name}${relno}_srpm/libcouchbase-${VERSION.version()}-${VERSION.rpmRel()}.*${relno}.src.rpm
        """.stripIndent())
        sh("sudo chown couchbase:couchbase -R libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}")
        sh("rm -rf libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}/*.log")
        sh("tar cf libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}.tar libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}")
        archiveArtifacts(artifacts: "libcouchbase-${VERSION.tar()}_${name}${relno}_${arch}.tar", fingerprint: true)
    }
}

pipeline {
    agent none
    parameters {
        string(name: "REPO", defaultValue: "ssh://review.couchbase.org:29418/libcouchbase")
        string(name: "SHA", defaultValue: "master")
        booleanParam(name: "IS_RELEASE", defaultValue: false)
        booleanParam(name: "IS_GERRIT_TRIGGER", defaultValue: false)
        string(name: "GERRIT_REFSPEC", defaultValue: "refs/heads/master")
        booleanParam(name: "VERBOSE", defaultValue: false)
        booleanParam(name: "SKIP_TESTS", defaultValue: false)
        booleanParam(name: "USE_TLS", defaultValue: false)
        booleanParam(name: "USE_CERT_AUTH", defaultValue: false)
    }
    stages {
        stage('prepare and validate') {
            agent { label 'rockylinux9' }
            steps {
                script {
                    if (IS_GERRIT_TRIGGER.toBoolean()) {
                        currentBuild.displayName = "cv-${BUILD_NUMBER}"
                    } else {
                        currentBuild.displayName = "full-${BUILD_NUMBER}"
                    }
                }
                cleanWs(cleanWhenNotBuilt: false, deleteDirs: true, disableDeferredWipeout: true)

                dir('libcouchbase') {
                    checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])
                    script {
                        VERSION = new Version(sh(script: 'git describe --long --abbrev=10', returnStdout: true))
                        echo "Building ${VERSION.gitVersion}, gerrit: ${IS_GERRIT_TRIGGER.toBoolean()}, release: ${IS_RELEASE.toBoolean()}, skip_tests: ${SKIP_TESTS.toBoolean()}"
                    }
                }

                stash includes: 'libcouchbase/', name: 'libcouchbase', useDefaultExcludes: false

                dir('libcouchbase') {
                    dir('build') {
                        sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLCB_NO_PLUGINS=1 -DLCB_NO_TESTS=1 -DLCB_NO_MOCK=1 ..')
                        sh('cmake --build . --target dist')
                        archiveArtifacts(artifacts: "${VERSION.tarName()}.tar.gz", fingerprint: true)
                        stash includes: "${VERSION.tarName()}.tar.gz", name: 'tarball', useDefaultExcludes: false
                    }
                }
            }
        }

        stage('nix') {
            matrix {
                axes {
                    axis {
                        name 'PLATFORM'
                        values "ubuntu20", "debian9", "rockylinux9", "m1", "qe-grav2-amzn2", "alpine", "qe-ubuntu20-arm64", "qe-ubuntu22-arm64", "qe-rhel9-arm64"
                    }
                }

                agent { label PLATFORM }
                stages {
                    stage("prep") {
                        steps {
                            dir("ws_${PLATFORM}") {
                                deleteDir()
                                unstash 'libcouchbase'
                            }
                        }
                    }
                    stage('build') {
                        environment {
                            CMAKE_BUILD_PARALLEL_LEVEL=8
                        }
                        steps {
                            dir("ws_${PLATFORM}") {
                                dir('build') {
                                    sh('cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ../libcouchbase')
                                    sh("cmake --build . --target all ${VERBOSE.toBoolean() ? '--verbose' : ''}")
                                    sh("cmake --build . --target alltests ${VERBOSE.toBoolean() ? '--verbose' : ''}")
                                }
                            }
                            stash(includes: "ws_${PLATFORM}/", name: "${PLATFORM}_build")
                        }
                    }
                    stage('test') {
                        when {
                            expression {
                                return !SKIP_TESTS.toBoolean()
                            }
                        }
                        options {
                            timeout(time: 60, unit: 'MINUTES')
                        }
                        environment {
                            CTEST_PARALLEL_LEVEL=1
                            CTEST_OUTPUT_ON_FAILURE=1
                        }
                        post {
                           always {
                               junit(testResults: "ws_${PLATFORM}/build/*.xml", allowEmptyResults: true)
                           }
                       }
                       steps {
                           dir("ws_${PLATFORM}/build") {
                               sh("ctest --label-exclude contaminating ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
                               sh("ctest --label-exclude normal ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
                           }
                       }
                    }
                }
            }
        }

        stage('win') {
            matrix {
                axes {
                    axis {
                        name 'MSVS'
                        values "16 2019", "17 2022"
                    }
                    axis {
                        name 'TLS'
                        values true, false
                    }
                    axis {
                        name 'ARCH'
                        values 'x64', 'Win32'
                    }
                }

                agent { label "msvc-${MSVS.split(' ')[1]}" }
                stages {
                    stage('prep') {
                        steps {
                        dir("ws_win_${MSVS.replaceAll(' ', '_')}_${ARCH}") {
                                deleteDir()

/*
                                script {
                                    if (TLS.toBoolean()) {
bat("""
    set INSTALLER_URL=https://slproweb.com/download/${ARCH == 'x64' ? 'Win64' : 'Win32'}OpenSSL-3_4_1.exe
    set DOWNLOAD_DIR=%TEMP%\\openssl_installer_${ARCH}
    mkdir "%DOWNLOAD_DIR%"
    powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri %INSTALLER_URL% -OutFile %DOWNLOAD_DIR%\\openssl_installer.exe"
    "%DOWNLOAD_DIR%\\openssl_installer.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
    rd /s /q "%DOWNLOAD_DIR%"
""")
                                    }
                                }
*/
bat("""
set TARGET_DIR=%USERPROFILE%\\cmake
set CMAKE_ZIP_URL=https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-windows-x86_64.zip
set CMAKE_ZIP_FILE=%USERPROFILE%\\cmake.zip

if exist "%TARGET_DIR%" goto :end
powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%CMAKE_ZIP_URL%' -OutFile '%CMAKE_ZIP_FILE%'"
if not exist "%CMAKE_ZIP_FILE%" exit /b 1
powershell -Command "Expand-Archive -Path '%CMAKE_ZIP_FILE%' -DestinationPath '%TEMP%\\cmake'"
move "%TEMP%\\cmake\\cmake-*" "%TARGET_DIR%"
del "%CMAKE_ZIP_FILE%"
:end
""")

                                unstash 'libcouchbase'
                            }
                        }
                    }
                    stage('build') {
                        steps {
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}_${ARCH}/build") {
                                bat('%USERPROFILE%\\cmake\\bin\\cmake.exe --help --version')
                                bat("%USERPROFILE%\\cmake\\bin\\cmake.exe -G\"Visual Studio ${MSVS}\" -A ${ARCH} ${TLS.toBoolean() ? (ARCH == "x64" ? '-DOPENSSL_ROOT_DIR="%ProgramFiles%\\OpenSSL-Win64"' : '-DOPENSSL_ROOT_DIR="%ProgramFiles(x86)%\\OpenSSL-Win32"') : '-DLCB_NO_SSL=1'} ..\\libcouchbase")
                                bat('%USERPROFILE%\\cmake\\bin\\cmake.exe --build .')
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
                            timeout(time: 60, unit: 'MINUTES')
                        }
                        environment {
                            CTEST_PARALLEL_LEVEL=1
                            CTEST_OUTPUT_ON_FAILURE=1
                        }
                        post {
                            always {
                                junit(testResults: "ws_win_${MSVS.replaceAll(' ', '_')}_${ARCH}/build/*.xml", allowEmptyResults: true)
                            }
                        }
                        steps {
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}_${ARCH}/build") {
                                bat('cmake --build . --target alltests')
                                script {
                                    if (TLS.toBoolean()) {
                                        bat("copy ${ARCH == "x64" ? '"%ProgramFiles%\\OpenSSL-Win64"' : '"%ProgramFiles(x86)%\\OpenSSL-Win32"'}\\*.dll bin\\Debug\\")
                                    }
                                }
                                bat("ctest --label-exclude contaminating --build-config debug ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
                                bat("ctest --label-exclude normal --build-config debug ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
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
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}_${ARCH}/build") {
                                bat('cmake --build . --target package')
                                script {
                                    bat("if exist ${VERSION.tarName()}__${ARCH == 'x64' ? 'amd64' : 'x86'}.zip move ${VERSION.tarName()}__${ARCH == 'x64' ? 'amd64' : 'x86'}.zip ${VERSION.tarName()}_vc17_${ARCH == 'x64' ? 'amd64' : 'x86'}.zip ")
                                    if (TLS.toBoolean()) {
                                        bat("move ${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${ARCH == 'x64' ? 'amd64' : 'x86'}.zip ${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${ARCH == 'x64' ? 'amd64' : 'x86'}_openssl3.zip")
                                    }
                                }
                                archiveArtifacts(artifacts: "${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${ARCH == 'x64' ? 'amd64' : 'x86'}${TLS.toBoolean() ? '_openssl3' : ''}.zip", fingerprint: true)
                            }
                        }
                    }
                }
            }
        }

        stage('int') {
            when {
                expression {
                    return !IS_GERRIT_TRIGGER.toBoolean() && !SKIP_TESTS.toBoolean()
                }
            }
            matrix {
                axes {
                    axis {
                        name 'CB_VERSION'
                        values '7.6-release', '7.2-release', '7.1-release', '7.0-release', '6.6-release', '6.5-release', '6.0-release'
                    }
                }
                agent { label 'sdkqe-rockylinux9' }
                stages {
                    stage("env") {
                        steps {
                            script {
                                def cluster = new DynamicCluster(CB_VERSION)
                                cluster.id_ = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version=${cluster.version()}", returnStdout: true).trim()
                                cluster.ips_ = sh(script: "cbdyncluster ips ${cluster.clusterId()}", returnStdout: true).trim()
                                if (USE_TLS.toBoolean()) {
                                    cluster.useTLS = true
                                    cluster.certsDir = WORKSPACE
                                }
                                cluster.useCertAuth = USE_CERT_AUTH.toBoolean()
                                CLUSTER[CB_VERSION] = cluster
                            }
                            echo("Allocated ${CLUSTER[CB_VERSION].inspect()}")
                            sh("cbdyncluster setup ${CLUSTER[CB_VERSION].clusterId()} --node=kv,index,n1ql --node=kv,fts --node=kv,cbas --bucket=default ${CLUSTER[CB_VERSION].extraOptions()}")
                            script {
                                if (USE_TLS.toBoolean()) {
                                    sh("cbdyncluster setup-cert-auth ${CLUSTER[CB_VERSION].clusterId()} --user Administrator --num-roots ${CLUSTER[CB_VERSION].numRootCAs()}")
                                }
                            }
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
                        post {
                            always {
                                junit(testResults: "ws_centos7/build/*.xml", allowEmptyResults: true)
                                sh("cbdyncluster ps -a; cbdyncluster rm ${CLUSTER[CB_VERSION].clusterId()}")
                            }
                        }
                        environment {
                            LCB_LOGLEVEL=5
                            LCB_TEST_CLUSTER_CONF="${CLUSTER[CB_VERSION].connectionString()}"
                            LCB_MAX_TEST_DURATION=1500
                            CTEST_PARALLEL_LEVEL=1
                            CTEST_OUTPUT_ON_FAILURE=1
                        }
                        options {
                            timeout(time: 60, unit: 'MINUTES')
                        }
                        steps {
                            unstash('rockylinux9_build')
                            dir('ws_rockylinux9/build') {
                                sh("sed -i s:/home/couchbase/jenkins/workspace/lcb/lcb-scripted-build-pipeline/ws_centos7/build:\$(realpath .):g tests/CTestTestfile.cmake")
                                sleep(20)
                                sh("cbdyncluster ps -a")
                                sh("ctest --label-exclude contaminating --exclude-regex BUILD ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
                                sh("ctest --label-exclude normal --exclude-regex BUILD ${VERBOSE.toBoolean() ? '--extra-verbose' : ''}")
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
                                    sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get install -y cowbuilder && \
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
                                package_src("ubuntu1804", "amd64", "bionic", VERSION)
                            }
                        }
                        stage('deb') {
                            steps {
                                package_deb("ubuntu1804", "amd64", "bionic", VERSION)
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
                                    sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get install -y cowbuilder && \
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
                                package_src("debian10", "amd64", "buster", VERSION)
                            }
                        }
                        stage('deb') {
                            steps {
                                package_deb("debian10", "amd64", "buster", VERSION)
                            }
                        }
                    }
                }
            }
        }
    }
}
