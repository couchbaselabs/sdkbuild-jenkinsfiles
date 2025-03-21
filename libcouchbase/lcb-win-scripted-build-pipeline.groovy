
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


        stage('win') {
            matrix {
                axes {
                    axis {
                        name 'MSVS'
                        values "14 2015", "15 2017", "16 2019", "17 2022"
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

    }
}
