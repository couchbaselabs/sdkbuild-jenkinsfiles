def PLATFORMS = [
    "windows-2012",
    "ubuntu16",
    "centos7",
	"macos"
]
def DOTNET_SDK_VERSION = "2.2.300"
def SUFFIX = "ci-${BUILD_NUMBER}"

pipeline {
    agent none
    stages {
        stage("job valid?") {
            when {
                expression {
                    return _INTERNAL_OK_.toBoolean() != true
                }
            }
            steps {
                error("Exiting early as not valid run")
            }
        }
        stage("prepare and validate") {
            agent { label "centos6||centos7||ubuntu16||ubuntu14" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("linq2couchbase") {
                    script {
						if (env.PR_NUMBER != "") {
							echo "Building Github PR #: ${env.PR_NUMBER}"
							checkout([$class: 'GitSCM',
								branches: [[name: "FETCH_HEAD"]],
								doGenerateSubmoduleConfigurations: false,
								extensions: [[$class: 'LocalBranch']],
								userRemoteConfigs: [[refspec: "+refs/pull/${env.PR_NUMBER}/head:refs/remotes/origin/PR-${env.PR_NUMBER} +refs/heads/master:refs/remotes/origin/master",
													url: "git@github.com:couchbaselabs/Linq2Couchbase.git"]]
							])
						} else {
							echo "Building HEAD"
							checkout([$class: "GitSCM", userRemoteConfigs: [[url: "git@github.com:couchbaselabs/Linq2Couchbase.git", poll: false]]])
						}
					}
                }

                // TODO: UPDATE METADATA HERE (SEE GOCB OR COUCHNODE FOR EXAMPLES)
                // TODO: PUT ANY LINTING/CODE QUALITY TOOLS HERE TOO

                stash includes: "linq2couchbase/", name: "linq2couchbase", useDefaultExcludes: false
            }
        }
        stage("build") {
            agent { label "master" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                doBuild(PLATFORMS, DOTNET_SDK_VERSION)
            }
        }
        stage("unit-test") {
            agent { label "master" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                doUnitTests(PLATFORMS, DOTNET_SDK_VERSION)
            }
        }
        stage("package") {
            agent { label "windows-2012" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "linq2couchbase-windows-2012"
                installSDK("windows-2012", DOTNET_SDK_VERSION)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${SUFFIX}"
                    }

                    // pack in Release mode (no SNK because some dependencies are not signed)
                    batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet pack linq2couchbase\\Src\\Couchbase.Linq\\Couchbase.Linq.csproj -c Release /p:Version=${version} /p:IncludeSymbols=false /p:IncludeSource=false /p:SourceLinkCreate=false")
                }
                archiveArtifacts artifacts: "linq2couchbase\\**\\*.nupkg", fingerprint: true
                stash includes: "linq2couchbase\\**\\*.nupkg", name: "linq2couchbase-package", useDefaultExcludes: false
            }
        }
        stage("approval") {
            agent none
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true }
            }
            steps {
                input "Publish?"
            }
        }
        stage("publish") {
            agent { label "windows-2012" }
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true }
            }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "linq2couchbase-package"

				script {
                    withCredentials([string(credentialsId: 'netsdk-nugetkey', variable: 'NUGETKEY')]) {
                        if (!NUGETKEY?.trim()) {
                            echo "No Nuget key configured, unable to publish package"
                        } else {
                            unstash "linq2couchbase-package"
                            echo "Publishing package to Nuget .."

                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet nuget push linq2couchbase\\**\\*.nupkg -k ${NUGETKEY} -s https://api.nuget.org/v3/index.json --no-symbols true")
                        }
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: "linq2couchbase/", fingerprint: true
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

def doBuild(PLATFORMS, DOTNET_SDK_VERSION) {
    def pairs = [:]
    for (j in PLATFORMS) {
        def platform = j

        pairs[platform]= {
            node(platform) {
                stage("build ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "linq2couchbase"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build linq2couchbase\\Src\\couchbase-net-linq.sln")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build linq2couchbase/Src/couchbase-net-linq.sln")
                    }

                    stash includes: "linq2couchbase/", name: "linq2couchbase-${platform}", useDefaultExcludes: false
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

        pairs[platform]= {
            node(platform) {
                stage("test ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "linq2couchbase-${platform}"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (platform.contains("windows")) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test linq2couchbase\\Src\\Couchbase.Linq.UnitTests\\Couchbase.Linq.UnitTests.csproj -f net46 --no-build")
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test linq2couchbase\\Src\\Couchbase.Linq.UnitTests\\Couchbase.Linq.UnitTests.csproj -f netcoreapp2.0 --no-build")
                    } else {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test linq2couchbase/Src/Couchbase.Linq.UnitTests/Couchbase.Linq.UnitTests.csproj -f netcoreapp2.0 --no-build")
                    }

                    // converts test results into JUnit format, requires MSTest Jenkins plugin
                    // step([$class: "MSTestPublisher", testResultsFile:"**/unit_tests.xml", failOnError: true, keepLongStdio: true])

                    // TODO: IF YOU HAVE INTEGRATION TESTS THAT RUN AGAINST THE MOCK DO THAT HERE
                    // USING THE PACKAGE(S) CREATED ABOVE
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
