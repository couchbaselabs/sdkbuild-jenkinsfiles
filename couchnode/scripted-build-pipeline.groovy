def PLATFORMS = [ "centos7", "windows-2012", "ubuntu16", "macos" ]
def DEFAULT_PLATFORM = PLATFORMS[0]
def NODE_VERSIONS = [  "11.1.0", "10.13.0", "9.11.2", "8.12.0" ]
def DEFAULT_NODE_VERSION = NODE_VERSIONS[0]
def ARCHES = [ "x64", "x86" ]
def DEFAULT_ARCH = ARCHES[0]
def PY_VERSION_SHORT=PY_VERSION.tokenize(".")[0] + "." + PY_VERSION.tokenize(".")[1]

pipeline {
    agent none
    stages {
        stage('job valid?') {
            when {
                expression {
                    jobFailed = false;
                    if (IS_RELEASE.toBoolean() && SHA.length() != 40) {
                        jobFailed = true;
                    }
                    if (!_INTERNAL_OK_.toBoolean()) {
                        jobFailed = true;
                    }
                    return jobFailed
                }
            }
            steps {
                error("Not a valid run.  Note that you must specify an explicit SHA1 when doing RELEASE builds, and _INTERNAL_OK_ must be set.")
            }
        }
        stage('prepare and validate') {
            agent { label "${DEFAULT_PLATFORM}" }
            environment {
                PATH="${WORKSPACE}/deps/node-v${DEFAULT_NODE_VERSION}-linux-x64/bin:${PATH}"
            }
            steps {
                cleanWs()
                shWithEcho("env")
                installNode(DEFAULT_PLATFORM, DEFAULT_NODE_VERSION, DEFAULT_ARCH)

                shWithEcho("node --version")
                shWithEcho("npm --version")

                dir("couchnode") {
                    checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])

                    script {
                        echo "Updating metadata..."
                        def buildNum = VersionNumber([projectStartDate: '', versionNumberString: '${BUILDS_ALL_TIME, XXXX}', versionPrefix: '', worstResultForIncrement: 'NOT_BUILT'])
                        def version = sh(script: 'cat package.json | grep "version" | awk \'{print $2}\' | cut -d "\\"" -f 2 | tr -d "\\n"', returnStdout: true)

                        if (IS_RELEASE.toBoolean() == true) {
                            // Strip the dash-naming from the semver version
                            version = sh(script: "awk -F- '{print \$1}' <<< ${version} | tr -d '\\n'", returnStdout: true)
                        } else {
                            // Append our build number
                            version = version + "." + buildNum
                        }

                        println version
                        shWithEcho("sed -i 's/\\(\"version\": \\).*\$/\\1\"$version\",/' package.json")
                        shWithEcho("sed -i 's/\\(\"version\": \\).*\$/\\1\"$version\",/' package-lock.json")
                    }

                    // TODO: DO ANY LINTING HERE, CHECKDEPS IS FAILING ATM
                    shWithEcho("npm install")
                    //shWithEcho("make checkdeps lint")
                }

                stash includes: 'couchnode/', name: 'couchnode', useDefaultExcludes: false
            }
        }
        stage('build') {
            agent { label 'master' }
            steps {
                cleanWs()
                buildsAndTests(PLATFORMS, NODE_VERSIONS, ARCHES, "${PY_VERSION}", PY_VERSION_SHORT)
            }
        }
        stage('package') {
            agent { label "${DEFAULT_PLATFORM}" }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            environment {
                PATH="${WORKSPACE}/deps/node-v${DEFAULT_NODE_VERSION}-linux-x64/bin:${PATH}"
            }
            steps {
                cleanWs()
                unstash "couchnode"

                installNode(DEFAULT_PLATFORM, DEFAULT_NODE_VERSION, DEFAULT_ARCH)

                script {
                    for (j in PLATFORMS) {
                        for (k in NODE_VERSIONS) {
                            for (l in ARCHES) {
                                if (l == "x86" && !j.contains("windows")) {
                                    // ignore x86 for all non-windows platforms
                                    continue
                                }
                                if (j.contains('ubuntu')) {
                                    // ignore the ubuntu binaries when packaging, this
                                    // is to ensure that the lower libc of cantos is used.
                                    continue
                                }
                                unstash "prebuilds-" + j + "-" + k + "-" + l
                            }
                        }
                    }
                }

                dir("couchnode") {
                    shWithEcho("make docs")
                }
                stash includes: 'couchnode/', name: "couchnode-package", useDefaultExcludes: false
            }
            post {
                always {
                    archiveArtifacts artifacts: 'couchnode/**/*', excludes: 'couchnode/node_modules/**/*'
                }
            }
        }
        stage('test-integration-server') {
            agent { label 'master' }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                //build job: "couchhnode-test-integration", parameters: [
                //]
            }
        }
        stage('quality') {
            agent { label 'master' }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                // Situational testing will go here
            }
        }
        stage('snapshot') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == false && IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                // TODO: Upload build artefacts to snapshot server here
            }
        }
        stage('approval') {
            agent none
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true && IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                input 'Publish?'
            }
        }
        stage('publish') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true && IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            environment {
                PATH="${WORKSPACE}/deps/node-v${DEFAULT_NODE_VERSION}-linux-x64/bin:${PATH}"
            }
            steps {
                cleanWs()
                unstash "couchnode-package"

                shWithEcho("env")
                installNode(DEFAULT_PLATFORM, DEFAULT_NODE_VERSION, DEFAULT_ARCH)

                dir("couchnode") {
                    script {
                        RELVERSION = sh(script: "node -e 'console.log(JSON.parse(fs.readFileSync(\"package.json\")).version)' | tr -d '\\n'", returnStdout: true)
                    }

                    shWithEcho("""
                        git config user.name "Couchbase SDK Team"
                        git config user.email "sdk_dev@couchbase.com"
                        git config user.signingkey 7CD637BCC6326B4ED62959B8D21968C134100A58
                        git tag -asm "Release v$RELVERSION" v$RELVERSION
                        git push origin v$RELVERSION
                    """)

                    withCredentials([string(credentialsId: 'npmjs-authtoken', variable: 'NPMJS_AUTHTOKEN')]) {
                        shWithEcho("npm set //registry.npmjs.org/:_authToken $NPMJS_AUTHTOKEN")
		                shWithEcho("npm publish")
                    }

                    withCredentials([string(credentialsId: 'github-prebuilds', variable: 'GHBUILD_TOKEN')]) {
		                shWithEcho("npm install prebuild")
		                shWithEcho("node_modules/.bin/prebuild --upload-all=${GHBUILD_TOKEN}")
                    }

                    s3Upload consoleLogLevel: 'INFO', dontWaitForConcurrentBuildCompletion: false, entries: [[bucket: "docs.couchbase.com/sdk-api/couchbase-node-client-${RELVERSION}", excludedFile: '', flatten: false, gzipFiles: false, keepForever: false, managedArtifacts: false, noUploadOnFailure: false, selectedRegion: 'us-west-1', showDirectlyInBrowser: true, sourceFile: 'docs/**/*', storageClass: 'STANDARD', uploadFromSlave: false, useServerSideEncryption: false]], pluginFailureResultConstraint: 'FAILURE', profileName: 'sdk-jenkins-docs', userMetadata: []
                }
            }
        }
    }
}

void installNode(String platform, String version, String arch) {
    shWithEcho("cbdep install nodejs ${version} -d deps")
}

void installNodeDows(String platform, String version, String arch) { // TODO: NEEDS PYTHON FROM CBDEP ON WINDOWS
    batWithEcho("if exist C:\\cbdeps\\node rmdir C:\\cbdeps\\node /S /Q")
    def cmd = "cbdep install nodejs ${version} -d C:\\cbdeps\\node"
    if (arch == "x86") {
        cmd = cmd + " --x32"
    }
    batWithEcho(cmd)

}

void installPython(String platform, String version, String path) {
    shWithEcho("cbdep install python ${version} -d ${path}")
}

void shWithEcho(String command) {
    echo "[$STAGE_NAME]"+ sh (script: command, returnStdout: true)
}

void batWithEcho(String command) {
    echo "[$STAGE_NAME]"+ bat (script: command, returnStdout: true)
}

def buildsAndTests(PLATFORMS, VERSIONS, ARCHES, PY_VERSION, PY_VERSION_SHORT) {
    def pairs = [:]
    for (j in PLATFORMS) {
        for (k in VERSIONS) {
            for (l in ARCHES) {
                def platform = j
                def version = k
                def arch = l
                if (arch == "x86" && !platform.contains("windows")) {
                    continue
                }

                pairs[platform + "_" + version + "_" + arch]= {
                    node(platform) {
                        def envStr = []
                        // Note that we include the node_modules path for windows here as there is a
                        // bug where it is not automatically included in the `npm test` commands...
                        if (platform.contains("windows")) {
                            envStr = ["PATH=${WORKSPACE}/couchnode/node_modules/.bin;C:\\cbdeps\\node\\node-v${version}-win-${arch};C:\\Python27;C:\\Python27\\bin;C:\\Program Files (x86)\\Microsoft Visual Studio\\2017\\Professional\\MSBuild\\15.0\\Bin;$PATH"] // Windows is a bad person and won't let us extract node to a path > 260 chars long
                        } else if (platform.contains("macos")) {
                            envStr = ["PATH=${WORKSPACE}/deps/node-v${version}-darwin-x64/bin:${WORKSPACE}/deps/python${PY_VERSION}:${WORKSPACE}/deps/python${PY_VERSION}/bin/:$PATH"]
                        } else {
                            envStr = ["PATH=${WORKSPACE}/deps/node-v${version}-linux-x64/bin:${WORKSPACE}/deps/python${PY_VERSION}:${WORKSPACE}/deps/python${PY_VERSION}/bin/:$PATH"]
                        }
                        withEnv(envStr) {
                            stage("build ${platform}_${version}_${arch}") {
                                cleanWs()
                                unstash 'couchnode'

                                dir("couchnode") {
                                    dir("node_modules") {
                                        deleteDir()
                                    }
                                }

                                if (platform.contains("windows")) {
                                    batWithEcho("SET")
                                    installNodeDows(platform, version, arch)
                                    batWithEcho("node --version")
                                    batWithEcho("npm --version")
                                    batWithEcho("python --version")

                                    dir("couchnode") {
                                        // This is a workaround for an issue with windows where
                                        // modules are not being correctly installed...
                                        batWithEcho("npm install inherits async")

                                        // TODO: I'm reasonably sure blanket using msvs 2017 isn't correct
                                        batWithEcho("npm install --ignore-scripts --unsafe-perm --msvs_version=2017")
                                        batWithEcho("SET npm_config_loglevel=\"silly\" && node ./node_modules/prebuild/bin.js -b ${version} --verbose --force")
                                    }
                                } else {
                                    installNode(platform, version, "x64")
                                    installPython("${platform}", "${PY_VERSION}", "deps")
                                    shWithEcho("node --version")
                                    shWithEcho("npm --version")
                                    shWithEcho("python --version")

                                    dir("couchnode") {
                                        // we can probably do away with this check but I'm leaving it for now
                                        shWithEcho("""
                                        if [ \"${arch}\" == \"x86\" ]; then
                                          CFLAGS=\"-m32\"
                                          CXXFLAGS=\"-m32\"
                                          LDFLAGS=\"-m32\"
                                        else
                                          CXXFLAGS=\"\"
                                          LDFLAGS=\"\"
                                        fi
                                        export CFLAGS CXXFLAGS LDFLAGS
                                        npm install --ignore-scripts --unsafe-perm
                                        """)
                                        shWithEcho("""
                                        if [ \"${arch}\" == \"x86\" ]; then
                                          CFLAGS=\"-m32\"
                                          CXXFLAGS=\"-m32\"
                                          LDFLAGS=\"-m32\"
                                        else
                                          CXXFLAGS=\"\"
                                          LDFLAGS=\"\"
                                        fi
                                        export CFLAGS CXXFLAGS LDFLAGS
                                        npm install --ignore-scripts --unsafe-perm
                                        export npm_config_loglevel=\"silly\" && node ./node_modules/prebuild/bin.js -b ${version} --verbose --force
                                        """)
                                    }
                                }

                                stash includes: 'couchnode/prebuilds/*', name: "prebuilds-${platform}-${version}-${arch}", useDefaultExcludes: false
                            }
                            stage("test ${platform}_${version}_${arch}") {
                                dir("couchnode") {
                                    // Run the testing for both platforms using the mock
                                    if (platform.contains("windows")) {
                                        batWithEcho("dir node_modules")
                                        batWithEcho("dir node_modules\\.bin")
                                        batWithEcho("echo %PATH%")
                                        batWithEcho("mocha --version")
                                        batWithEcho("npm test")
                                    } else {
                                        shWithEcho("npm test")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    parallel pairs
}
