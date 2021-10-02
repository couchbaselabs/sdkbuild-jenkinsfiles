
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

    DynamicCluster(String version) {
        this.version_ = version
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
                        withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                            s3Upload(
                                bucket: 'sdk-snapshots.couchbase.com',
                                file: "${VERSION.tarName()}.tar.gz",
                                path: 'libcouchbase/'
                            )
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
                        values "14 2015", "15 2017", "16 2019", "14 2015 Win64", "15 2017 Win64"
                    }
                    axis {
                        name 'TLS'
                        values true, false
                    }
                }

                agent { label "msvc-${MSVS.split(' ')[1]}" }
                stages {
                    stage('prep') {
                        steps {
                        dir("ws_win_${MSVS.replaceAll(' ', '_')}") {
                                deleteDir()
                                script {
                                    if (TLS) {
                                        bat("cbdep --platform windows_msvc2017 install ${MSVS.matches(/.*(Win64|2019).*/) ? '' : '--x32'} openssl 1.1.1g-sdk2")
                                    }
                                }
                                unstash 'libcouchbase'
                            }
                        }
                    }
                    stage('build') {
                        steps {
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}/build") {
                                bat("cmake -G\"Visual Studio ${MSVS}\" ${TLS ? '-DOPENSSL_ROOT_DIR=..\\install\\openssl-1.1.1g-sdk2' : '-DLCB_NO_SSL=1'} ..\\libcouchbase")
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
                                junit(testResults: "ws_win_${MSVS.replaceAll(' ', '_')}/build/*.xml", allowEmptyResults: true)
                            }
                        }
                        steps {
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}/build") {
                                bat('cmake --build . --target alltests')
                                script {
                                    if (TLS) {
                                        bat('copy ..\\install\\openssl-1.1.1g-sdk2\\bin\\*.dll bin\\Debug\\')
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
                            dir("ws_win_${MSVS.replaceAll(' ', '_')}/build") {
                                bat('cmake --build . --target package')
                                script {
                                    if (TLS) {
                                        bat("move ${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${MSVS.matches(/.*(Win64|2019).*/) ? 'amd64' : 'x86'}.zip ${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${MSVS.matches(/.*(Win64|2019).*/) ? 'amd64' : 'x86'}_openssl.zip")
                                    }
                                }
                                archiveArtifacts(artifacts: "${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${MSVS.matches(/.*(Win64|2019).*/) ? 'amd64' : 'x86'}${TLS ? '_openssl' : ''}.zip", fingerprint: true)
                                withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                                    s3Upload(
                                        bucket: 'sdk-snapshots.couchbase.com',
                                        file: "${VERSION.tarName()}_vc${MSVS.split(' ')[0]}_${MSVS.matches(/.*(Win64|2019).*/) ? 'amd64' : 'x86'}${TLS ? '_openssl' : ''}.zip",
                                        path: 'libcouchbase/'
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
