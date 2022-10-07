// Please do not Save the Jenkins pipeline with a modified script.
// Instead, use the Replay function to test build script changes, then commit final changes
// to the sdkbuilds-jenkinsfile repository.
def DOTNET_SDK_VERSION = "6.0.101"

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
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "${API_REPO_NAME}"
                unstash "couchbase-apidocs-docfx"
                installSDK("windows", DOTNET_SDK_VERSION)
                script {
                    env.PATH = "${PATH};${CBDEP_WIN_PATH}\\dotnet-core-sdk-${DOTNET_SDK_VERSION}"
                    dir("couchbase-apidocs-docfx") {
                        batWithEcho("powershell .\\Generate-ApiDocs.ps1 .\\${API_REPO_NAME}\\ -ApiVersion ${VERSION}") // -ZipOutput ${API_REPO_NAME}-${VERSION}.zip")
                        dir("${API_REPO_NAME}") {
                            zip dir: "_site", zipFile: "${API_REPO_NAME}-${VERSION}.zip", archive: true
                            archiveArtifacts artifacts: "${API_REPO_NAME}-${VERSION}.zip", fingerprint: true
                            stash includes: "${API_REPO_NAME}-${VERSION}.zip", name: "apidocs", useDefaultExcludes: false
                            // // if (PUBLISH_TO_S3.toBoolean == true) {
                            // //     dir("_site") {
                            // //         withAWS(credentials: 'aws-sdk', region: 'us-west-1') {
                            // //             s3Upload(
                            // //                 bucket: 'docs.couchbase.com',
                            // //                 path: "sdk-api/${API_REPO_NAME}-${VERSION}/",
                            // //                 acl: 'PublicRead',
                            // //                 file: 'docs/',
                            // //             )
                            // //         }       
                            // //     }
                            // // }
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

def installSDK(PLATFORM, DOTNET_SDK_VERSION) {
    def install = false
    def depsDir = "deps"
    if (PLATFORM.contains("window")) {
        depsDir = "%TEMP%\\cbnc\\deps"
    }
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
            batWithEcho("cbdep install -d %TEMP%\\cbnc\\deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        } else {
            shWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        }
    }
    else {
        echo ".NET SDK ${DOTNET_SDK_VERSION} for ${PLATFORM} is already installed."
    }
}