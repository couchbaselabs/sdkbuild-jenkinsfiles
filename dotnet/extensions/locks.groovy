def PLATFORMS = [
    "windows",
    "ubuntu16",
    "centos7",
	"macos"
]
def DOTNET_SDK_VERSION = "2.2.104"
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

                stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.Locks", useDefaultExcludes: false
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
            agent { label "windows" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "Couchbase.Extensions.Locks-windows"
                installSDK("windows", DOTNET_SDK_VERSION)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${SUFFIX}"
                    }

                    // pack in Release mode (no SNK because some dependencies are not signed)
                    batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet pack Couchbase.Extensions\\src\\Couchbase.Extensions.Locks\\Couchbase.Extensions.Locks.csproj -c Release /p:Version=${version} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
                }
                archiveArtifacts artifacts: "Couchbase.Extensions\\**\\*.nupkg", fingerprint: true
                stash includes: "Couchbase.Extensions\\**\\*.nupkg", name: "Couchbase.Extensions.Locks-package", useDefaultExcludes: false
            }
        }
        // stage("approval") {
        //     agent none
        //     when {
        //         expression {
        //             return IS_RELEASE.toBoolean() == true
        //         }
        //     }
        //     steps {
        //         input "Publish Couchbase.Extensions.Locks .NET to Nuget?"
        //     }
        // }
        // stage("publish") {
        //     agent { label "windows" }
        //     when {
        //         expression {
        //             return IS_RELEASE.toBoolean() == true
        //         }
        //     }
        //     steps {
        //         unstash "Couchbase.Extensions.Locks-package"
        //         echo "Publishing to nuget!"
        //         // TODO: PUBLISH!
        //     }
        // }
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
                    unstash "Couchbase.Extensions.Locks"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\src\\Couchbase.Extensions.Locks\\Couchbase.Extensions.Locks.csproj")
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\tests\\Couchbase.Extensions.Locks.UnitTests\\Couchbase.Extensions.Locks.UnitTests.csproj")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/src/Couchbase.Extensions.Locks/Couchbase.Extensions.Locks.csproj")
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/tests/Couchbase.Extensions.Locks.UnitTests/Couchbase.Extensions.Locks.UnitTests.csproj")
                    }

                    stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.Locks-${platform}", useDefaultExcludes: false
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
                    unstash "Couchbase.Extensions.Locks-${platform}"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test Couchbase.Extensions\\tests\\Couchbase.Extensions.Locks.UnitTests\\Couchbase.Extensions.Locks.UnitTests.csproj --no-build")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test Couchbase.Extensions/tests/Couchbase.Extensions.Locks.UnitTests/Couchbase.Extensions.Locks.UnitTests.csproj --no-build")
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
