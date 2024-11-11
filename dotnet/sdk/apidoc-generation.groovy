// Please do not Save the Jenkins pipeline with a modified script.
// Instead, use the Replay function to test build script changes, then commit final changes
// to the sdkbuilds-jenkinsfile repository.
def DOTNET_SDK_VERSION = "8.0.401"
def DOTNET_SDK_VERSIONS = ["6.0.425", DOTNET_SDK_VERSION]

// Windows has a 255 character path limit, still.
// cbdep trying to unzip .NET SDK 5.0.x shows a FileNotFound error, which is really a PathTooLong error
// using this path instead of WORKSPACE\deps gets around the issue.
def CBDEP_WIN_PATH = "%TEMP%\\cbnc\\deps"

pipeline {
    agent none
    stages {
        stage("job valid?") {
            when {
                expression {
                    return (API_REPO_NAME == "" || VERSION == "")
                }
            }
            steps {
                error("Exiting early as not valid run")
            }
        }
        stage("prepare and validate") {
            agent { label "centos6||centos7||ubuntu16||ubuntu14||ubuntu20" }
            steps {
                echo "API Repo Name: ${API_REPO_NAME}"
				echo "SHA: ${SHA}"

                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("${API_REPO_NAME}") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[url: "$REPO"]]])
                }

                dir("couchbase-apidocs-docfx") {
                    checkout([$class: "GitSCM", userRemoteConfigs: [[url: "https://github.com/couchbaselabs/couchbase-apidocs-docfx.git"]]])
                }

                echo "Using dotnet core ${DOTNET_SDK_VERSION}"

                stash includes: "${API_REPO_NAME}/", name: "${API_REPO_NAME}", useDefaultExcludes: false
                stash includes: "couchbase-apidocs-docfx/", name: "couchbase-apidocs-docfx", useDefaultExcludes: false
            }
        }
        stage("build") {
            agent { label "windows" }
            stages {
                stage ("unstash") {
                    steps {
                        cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                        unstash "${API_REPO_NAME}"
                        unstash "couchbase-apidocs-docfx"
                    }
                }
                stage ("install-dotnet-sdks") {
                    steps {
                        installSdksForPlatform("windows", DOTNET_SDK_VERSIONS)
                    }
                }
                stage ("build-sdk") {
                    steps {
                        script {
                            def dotNetCmd = getDotnetCmd("windows")
                            def dotNetDir = dotNetCmd[0..-7]
                            withEnv(["PATH=${dotNetDir};${PATH}${dotNetDir}"]) {
                                echo env.PATH
                                batWithEcho("dotnet --list-sdks")
                                batWithEcho("dotnet sdk check")
                                dir("couchbase-net-client")
                                {
                                    batWithEcho("dotnet build src\\Couchbase\\Couchbase.csproj -c Release /p:Version=${VERSION}")
                                }
                            }
                        }
                    }
                }
                stage ("build-docs") {
                    steps {
                        script {
                            def dotNetCmd = getDotnetCmd("windows")
                            def dotNetDir = dotNetCmd[0..-7]
                            withEnv(["PATH=${dotNetDir};${PATH}${dotNetDir}"]) {
                                def year = new Date().year
                                def copyright = "&copy; ${year + 1900} Couchbase, Inc."
                                def overrides = ["_appTitle": VERSION, "_appFooter": copyright ]
                                dir("couchbase-apidocs-docfx") {
                                    dir("${API_REPO_NAME}") {
                                        writeJSON file:"overrides.json", json: overrides
                                    }
                                    batWithEcho("dotnet run --project DocFxRun\\DocFxRun.csproj ${API_REPO_NAME}\\docfx.json")
                                    dir("${API_REPO_NAME}") {
                                        def htmlFiles = findFiles(glob: "_site/api/*.html")
                                        if (htmlFiles.length < 2) {
                                            error "The site doesn't appear to have actually been generated, as there were no API HTML files in _site/api"
                                        }
                                        zip dir: "_site", zipFile: "${API_REPO_NAME}-${VERSION}.zip", archive: true
                                        archiveArtifacts artifacts: "${API_REPO_NAME}-${VERSION}.zip", fingerprint: true
                                        stash includes: "${API_REPO_NAME}-${VERSION}.zip", name: "apidocs", useDefaultExcludes: false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        stage("approval") {
            agent none
            when {
                expression {
                    return PUBLISH_TO_S3.toBoolean() == true
                }
            }
            steps {
                input "Publish Generated API Docs to S3/sdk-api/${API_REPO_NAME}-${VERSION}/?"
            }
        }
        stage("publish") {
            agent { label "centos8" }
            when {
                expression {
                    return PUBLISH_TO_S3.toBoolean() == true
                }
            }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])

                script {
                    unstash "apidocs"
                    unzip zipFile: "${API_REPO_NAME}-${VERSION}.zip", dir: "${API_REPO_NAME}-${VERSION}"
                    withAWS(credentials: 'aws-sdk', region: 'us-west-1') {
                        s3Upload(
                            bucket: 'docs.couchbase.com',
                            path: "sdk-api/${API_REPO_NAME}-${VERSION}/",
                            acl: 'PublicRead',
                            file: "${API_REPO_NAME}-${VERSION}/",
                        )
                    }
                }
            }
        }
    }
}

void shWithEcho(String command) {
    echo "[$STAGE_NAME]"+ sh (script: command, returnStdout: true)
}

void batWithEcho(String command) {
    echo "[$STAGE_NAME]"+ bat (script: command, returnStdout: true)
}

def getDepsDir(PLATFORM) {
    if (PLATFORM.contains("window")) {
        return "${env.TEMP}\\cbnc\\deps"
    }

    return "deps"
}

def getDotnetCmd(PLATFORM) {
    depsDir = getDepsDir(PLATFORM)
    if (PLATFORM.contains("window")) {
        return "${depsDir}\\dotnet-core-sdk-all\\dotnet"
    }

    return "${depsDir}//dotnet-core-sdk-all/dotnet"
}

// 'dotnet' understands forward-slashes on Windows, so the only difference is bat vs. sh
def dotNetWithEcho(PLATFORM, command) {
    dotNetCmd = getDotnetCmd(PLATFORM)
    if (PLATFORM.contains("window")) {
        batWithEcho("${dotNetCmd} ${command}")
    } else {
        shWithEcho("${dotNetCmd} ${command}")
    }
}

def installSDK(PLATFORM, DOTNET_SDK_VERSION) {
    def install = false
    def depsDir = getDepsDir(PLATFORM)

    dir(depsDir) {
        dir("dotnet-core-sdk-${DOTNET_SDK_VERSION}") {
            if (PLATFORM.contains("window")) {
                install = !fileExists("dotnet.exe")
            } else {
                install = !fileExists("dotnet")
            }
        }
    }

    if (install) {
        echo "Installing .NET SDK ${DOTNET_SDK_VERSION}"
        if (PLATFORM.contains("window")) {
            batWithEcho("cbdep install -d ${depsDir} dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        } else {
            shWithEcho("cbdep -V")
            shWithEcho("cbdep --debug install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
            if(PLATFORM.contains("amzn2")) {
            	//Required install for amazon linux 2 - related issue https://github.com/dotnet/runtime/issues/57983
            	shWithEcho("sudo yum install -y libicu60")
            }
        }
    }
    else {
        echo ".NET SDK ${DOTNET_SDK_VERSION} for ${PLATFORM} is already installed."
    }

    return depsDir
}

def installSdksForPlatform(PLATFORM, DOTNET_SDK_VERSIONS) {
    def depsDir = getDepsDir(PLATFORM)
    for (dnv in DOTNET_SDK_VERSIONS) {
        installSDK(PLATFORM, dnv)
    }

    echo "Combining installed dotnet SDKs into dotnet-core-sdk-all"
    // NOTE:  do these in order, even if the deps were already there, so we don't end up with SDK.older overwriting files form SDK.newer.
    for (dnv in DOTNET_SDK_VERSIONS) {
        dir(depsDir) {
            dir ("dotnet-core-sdk-all") {
                if (PLATFORM.contains("window")) {
                    // Zip + Unzip is faster than copy, and windows doesn't care about executable bits
                    // Xcopy might be faster, if we could get the parameters correct
                    zipFile = "..\\dotnet-core-sdk-${dnv}-windows.zip"
                    if (!fileExists(zipFile)) {
                        zip dir: "..\\dotnet-core-sdk-${dnv}", zipFile: zipFile
                    }
                    unzip zipFile: zipFile, dir: "."
                } else {
                    // For UNIX, we use cp to preserve file permissions
                    shWithEcho("cp -r ../dotnet-core-sdk-${dnv}/* .")
                }
            }
        }
    }
}