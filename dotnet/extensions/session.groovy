def PLATFORMS = [
    "windows-2012",
    "ubuntu16",
    "centos7"
]
def DOTNET_SDK_VERSION = "2.1.403"
def SUFFIX = "ci-${BUILD_NUMBER}"

pipeline {
    agent none
    stages {
        stage("prepare and validate") {
            agent { label "centos6||centos7||ubuntu16||ubuntu14" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("Couchbase.Extensions") {
                    checkout([$class: 'GitSCM', userRemoteConfigs: [[url: 'git@github.com:couchbaselabs/Couchbase.Extensions.git', poll: false]]])
                }

                // TODO: UPDATE METADATA HERE (SEE GOCB OR COUCHNODE FOR EXAMPLES)
                // TODO: PUT ANY LINTING/CODE QUALITY TOOLS HERE TOO

                stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.Session", useDefaultExcludes: false
            }
        }
        stage("build") {
            agent { label "master" }
            steps {
                doBuilds(PLATFORMS, DOTNET_SDK_VERSION)
            }
        }
        stage("unit-test") {
            agent { label "master" }
            steps {
                doUnitTests(PLATFORMS, DOTNET_SDK_VERSION)
            }
        }
        stage("package") {
            agent { label "windows-2012" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "Couchbase.Extensions.Session-windows-2012"
                installSDK("windows-2012", DOTNET_SDK_VERSION)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${SUFFIX}"
                    }

                    // pack in Release mode (no SNK because some dependencies are not signed)
                    batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet pack Couchbase.Extensions\\src\\Couchbase.Extensions.Session\\Couchbase.Extensions.Session.csproj -c Release /p:Version=${version} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
                }
                archiveArtifacts artifacts: "Couchbase.Extensions\\**\\*.nupkg", fingerprint: true
                stash includes: "Couchbase.Extensions\\**\\*.nupkg", name: "Couchbase.Extensions.Session-package", useDefaultExcludes: false
            }
        }
        stage("approval") {
            agent none
            when {
                expression {
                    return IS_RELEASE.toBoolean() == true
                }
            }
            steps {
                input "Publish Couchbase.Extensions.Session .NET to Nuget?"
            }
        }
        stage("publish") {
            agent { label "windows-2012" }
            when {
                expression {
                    return IS_RELEASE.toBoolean() == true
                }
            }
            steps {
                unstash "Couchbase.Extensions.Session"
                echo "Publishing to nuget!"
                // TODO: PUBLISH!
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

def doBuilds(PLATFORMS, DOTNET_SDK_VERSION) {
    def pairs = [:]
    for (j in PLATFORMS) {
        def platform = j

        pairs[platform] = {
            node(platform) {
                stage("build ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "Couchbase.Extensions.Session"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\src\\Couchbase.Extensions.Session\\Couchbase.Extensions.Session.csproj")
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\tests\\Couchbase.Extensions.Session.UnitTests\\Couchbase.Extensions.Session.UnitTests.csproj")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/src/Couchbase.Extensions.Session/Couchbase.Extensions.Session.csproj")
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/tests/Couchbase.Extensions.Session.UnitTests/Couchbase.Extensions.Session.UnitTests.csproj")
                    }

                    stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.Session-${platform}", useDefaultExcludes: false
                }
            }
        }
    }

    parallel pairs
}

def doUnitTests(PLATFORMS, DOTNET_SDK_VERSION) {
    def pairs = [:]
    for (j in PLATFORMS) {
        def platform = j

        pairs[platform] = {
            node(platform) {
                stage("unit-test ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "Couchbase.Extensions.Session-${platform}"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test Couchbase.Extensions\\tests\\Couchbase.Extensions.Session.UnitTests\\Couchbase.Extensions.Session.UnitTests.csproj --no-build")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test Couchbase.Extensions/tests/Couchbase.Extensions.Session.UnitTests/Couchbase.Extensions.Session.UnitTests.csproj --no-build")
                    }
                }
            }
        }
    }

    parallel pairs
}

def installSDK(PLATFORM, DOTNET_SDK_VERSION) {
    def install = false

    if (!fileExists("deps")) {
        install = true
    } else {
        dir("deps") {
            install = !fileExists("dotnet-core-sdk-${DOTNET_SDK_VERSION}")
        }
    }

    if (install) {
        if (PLATFORM.contains("windows")) {
            batWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        } else {
            shWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        }
    }
}
