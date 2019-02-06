def PLATFORMS = [
    "windows-2012",
    "ubuntu16",
    "centos7"
]
def DOTNET_SDK_VERSION = "2.1.403"
def SUFFIX = "ci-${BUILD_NUMBER}"
def CLUSTER_VERSIONS = [
    "5.5.0",
    "6.0.0"
]

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

                stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.DependencyInjection", useDefaultExcludes: false
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
        stage("combination-test") {
            agent { label 'sdk-integration-test-linux' }
            steps {
                doCombinationTests(CLUSTER_VERSIONS, DOTNET_SDK_VERSION)
            }
        }
        stage("package") {
            agent { label "windows-2012" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "Couchbase.Extensions.DependencyInjection-windows-2012"
                installSDK("windows-2012", DOTNET_SDK_VERSION)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${SUFFIX}"
                    }

                    // pack in Release mode (no SNK because some dependencies are not signed)
                    batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet pack Couchbase.Extensions\\src\\Couchbase.Extensions.DependencyInjection\\Couchbase.Extensions.DependencyInjection.csproj -c Release /p:Version=${version} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
                }
                archiveArtifacts artifacts: "Couchbase.Extensions\\**\\*.nupkg", fingerprint: true
                stash includes: "Couchbase.Extensions\\**\\*.nupkg", name: "Couchbase.Extensions.DependencyInjection-package", useDefaultExcludes: false
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
                input "Publish Couchbase.Extensions.DependencyInjection .NET to Nuget?"
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
                unstash "Couchbase.Extensions.DependencyInjection"
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
                    unstash "Couchbase.Extensions.DependencyInjection"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\src\\Couchbase.Extensions.DependencyInjection\\Couchbase.Extensions.DependencyInjection.csproj")
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build Couchbase.Extensions\\tests\\Couchbase.Extensions.DependencyInjection.UnitTests\\Couchbase.Extensions.DependencyInjection.UnitTests.csproj")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/src/Couchbase.Extensions.DependencyInjection/Couchbase.Extensions.DependencyInjection.csproj")
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/tests/Couchbase.Extensions.DependencyInjection.UnitTests/Couchbase.Extensions.DependencyInjection.UnitTests.csproj")
                    }

                    if (platform == "ubuntu16") {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build Couchbase.Extensions/tests/Couchbase.Extensions.DependencyInjection.IntegrationTests/Couchbase.Extensions.DependencyInjection.IntegrationTests.csproj")
                    }

                    stash includes: "Couchbase.Extensions/", name: "Couchbase.Extensions.DependencyInjection-${platform}", useDefaultExcludes: false
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
                    unstash "Couchbase.Extensions.DependencyInjection-${platform}"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test Couchbase.Extensions\\tests\\Couchbase.Extensions.DependencyInjection.UnitTests\\Couchbase.Extensions.DependencyInjection.UnitTests.csproj --no-build")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test Couchbase.Extensions/tests/Couchbase.Extensions.DependencyInjection.UnitTests/Couchbase.Extensions.DependencyInjection.UnitTests.csproj --no-build")
                    }
                }
            }
        }
    }

    parallel pairs
}

def doCombinationTests(CLUSTER_VERSIONS, DOTNET_SDK_VERSION) {
    def platform = "ubuntu16"

    installSDK(platform, DOTNET_SDK_VERSION)

    for (cluster_version in CLUSTER_VERSIONS) {
        stage("combintation-test ${platform}/${cluster_version}") {
            cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
            unstash "Couchbase.Extensions.DependencyInjection-${platform}"

            // configure using cbdyncluster
            def clusterId = null
            try {
                // Allocate the cluster (1 KV node)
                clusterId = sh(script: "cbdyncluster allocate --num-nodes=1 --server-version=" + cluster_version, returnStdout: true)
                echo "Got cluster ID $clusterId"

                // Find the cluster IP
                def ips = sh(script: "cbdyncluster ips $clusterId", returnStdout: true).trim()
                echo "Got raw cluster IPs " + ips
                def ip = ips.tokenize(',')[0]
                echo "Got cluster IP http://" + ip + ":8091"

                // Create the cluster
                shWithEcho("cbdyncluster --node kv --bucket default setup $clusterId")

                // replace hostname in config.json
                shWithEcho("sed -i -e 's/localhost/${ip}/' Couchbase.Extensions/tests/Couchbase.Extensions.DependencyInjection.IntegrationTests/configuration.json")

                // run integration tests
                shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test Couchbase.Extensions/tests/Couchbase.Extensions.DependencyInjection.IntegrationTests/Couchbase.Extensions.DependencyInjection.IntegrationTests.csproj")
            }
            finally {
                if (clusterId != null) {
                    // Easy to run out of resources during iterating, so cleanup even
                    // though cluster will be auto-removed after a time
                    shWithEcho("cbdyncluster rm $clusterId")
                }
            }
        }
    }
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
