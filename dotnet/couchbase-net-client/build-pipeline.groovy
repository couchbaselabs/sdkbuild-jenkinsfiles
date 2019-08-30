def PLATFORMS = [
    "windows",
    "ubuntu16",
    //"centos7",
	"macos"
]
def DOTNET_SDK_VERSION = "2.2.401"
def CB_VERSIONS = ["5.5.2", "6.0.0"]
def SUFFIX = "r${BUILD_NUMBER}"
def BRANCH = ""

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

				echo "Branch: ${GERRIT_BRANCH}"
				echo "SHA: ${SHA}"
				echo "Patchset: ${GERRIT_REFSPEC}"

                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("couchbase-net-client") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO", poll: false]]])
                }

				script {
					BRANCH = "${GERRIT_BRANCH}"
				}

                // TODO: UPDATE METADATA HERE (SEE GOCB OR COUCHNODE FOR EXAMPLES)
                // TODO: PUT ANY LINTING/CODE QUALITY TOOLS HERE TOO

                stash includes: "couchbase-net-client/", name: "couchbase-net-client", useDefaultExcludes: false
            }
        }
        stage("build") {
            agent { label "master" }
            steps {
                doBuilds(PLATFORMS, DOTNET_SDK_VERSION, BRANCH)
            }
        }
        stage("unit-test") {
            agent { label "master" }
            steps {
                doUnitTests(PLATFORMS, DOTNET_SDK_VERSION, BRANCH)
            }
        }
        // stage("mock-test") {
        //     agent { label "master" }
        //     steps {
        //         doMockTests(PLATFORMS, DOTNET_SDK_VERSION)
        //     }
        // }
        // stage("combintation-test") {
        //     agent { label "master" }
        //     steps {
        //         doCombintationTests(PLATFORMS, DOTNET_SDK_VERSION)
        //     }
        // }
        stage("package") {
            agent { label "windows" }
            when {
                expression {
                    return IS_GERRIT_TRIGGER.toBoolean() == false
                }
            }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "couchbase-net-client-windows"
                installSDK("windows", DOTNET_SDK_VERSION)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${SUFFIX}"
                    }

                    // pack with SNK
                    withCredentials([file(credentialsId: 'netsdk-signkey', variable: 'SDKSIGNKEY')]) {
                        batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet pack couchbase-net-client\\Src\\Couchbase\\Couchbase.csproj -c Release /p:SignAssembly=true /p:AssemblyOriginatorKeyFile=${SDKSIGNKEY} /p:Version=${version} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
                    }

					// create zip file of release files
					zip dir: "couchbase-net-client\\src\\Couchbase\\bin\\Release", zipFile: "couchbase-net-client-${version}.zip", archive: true
					// stash includes: "couchbase-net-client-${version}.zip", name: "couchbase-net-client-package-zip", useDefaultExcludes: false
                }
                archiveArtifacts artifacts: "couchbase-net-client\\**\\*.nupkg", fingerprint: true
                stash includes: "couchbase-net-client\\**\\*.nupkg", name: "couchbase-net-client-package", useDefaultExcludes: false
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
                input "Publish .NET SDK to Nuget?"
            }
        }
        stage("publish") {
            agent { label "windows" }
            when {
                expression {
                    return IS_RELEASE.toBoolean() == true
                }
            }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])

                script {
                    withCredentials([string(credentialsId: 'netsdk-nugetkey', variable: 'NUGETKEY')]) {
                        if (!NUGETKEY?.trim()) {
                            echo "No Nuget key configured, unable to publish package"
                        } else {
                            unstash "couchbase-net-client-package"
                            echo "Publishing package to Nuget .."

                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet nuget push couchbase-net-client\\**\\*.nupkg -k ${NUGETKEY} -s https://api.nuget.org/v3/index.json --no-symbols true")
                        }
                    }

					// TODO: S3 credentials not configured yet
					// unstash "couchbase-net-client-package-zip"
					// echo "Pushing ZIP to S3 .."
					// s3Upload(file:'*.zip', bucket:'packages.couchbase.com', path:'clients/net/3.0/', acl:'PublicRead')
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

def doBuilds(PLATFORMS, DOTNET_SDK_VERSION, BRANCH) {
    def pairs = [:]
    for (j in PLATFORMS) {
        def platform = j

        pairs[platform] = {
            node(platform) {
                stage("build ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "couchbase-net-client"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (BRANCH == "master") {
                        if (platform.contains("windows")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build couchbase-net-client\\couchbase-net-client.sln")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build couchbase-net-client/couchbase-net-client.sln")
                        }
                    } else if (BRANCH == "release27") {
                        if (platform.contains("windows")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build couchbase-net-client\\Src\\couchbase-net-client.sln")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build couchbase-net-client/Src/couchbase-net-client.sln")
                        }
                    } else {
                        echo "Unknown gerrit branch ${BRANCH}"
                    }

                    stash includes: "couchbase-net-client/", name: "couchbase-net-client-${platform}", useDefaultExcludes: false
                }
            }
        }
    }

    parallel pairs
}

def doUnitTests(PLATFORMS, DOTNET_SDK_VERSION, BRANCH) {
    def pairs = [:]
    for (j in PLATFORMS) {
        def platform = j

        pairs[platform] = {
            node(platform) {
                stage("unit-test ${platform}") {
                    cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                    unstash "couchbase-net-client-${platform}"
                    installSDK(platform, DOTNET_SDK_VERSION)

                    if (BRANCH == "master") {
                        if (platform.contains("windows")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\tests\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj --no-build")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test couchbase-net-client/tests/Couchbase.UnitTests/Couchbase.UnitTests.csproj --no-build")
                        }
                    } else if (BRANCH == "release27") {
                        if (platform.contains("windows")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f net452 --no-build")
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f netcoreapp2.0 --no-build")
                            //batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f netcoreapp1.1 --no-build")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test couchbase-net-client/Src/Couchbase.UnitTests/Couchbase.UnitTests.csproj -f netcoreapp2.0 --no-build")
                            //shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test couchbase-net-client/Src/Couchbase.UnitTests/Couchbase.UnitTests.csproj -f netcoreapp1.1 --no-build")
                        }
                    } else {
                        echo "Unknown gerrit branch ${BRANCH}"
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

// def doMockTests(PLATFORMS, DOTNET_SDK_VERSION) {
//     def pairs = [:]
//     for (j in PLATFORMS) {
//         def platform = j

//         pairs[platform] = {
//             node(platform) {
//                 stage("mock-test ${platform}") {

//                 }
//             }
//         }
//     }

//     parallel pairs
// }

// def doCombintationTests(PLATFORMS, DOTNET_SDK_VERSION) {
//     def pairs = [:]
//     for (j in PLATFORMS) {
//         def platform = j

//         pairs[platform] = {
//             node(platform) {
//                 stage("combintation-test ${platform}") {

//                 }
//             }
//         }
//     }

//     parallel pairs
// }

def installSDK(PLATFORM, DOTNET_SDK_VERSION) {
    def install = false

    dir("deps") {
        dir("dotnet-core-sdk-${DOTNET_SDK_VERSION}") {
            install = !fileExists("dotnet")
        }
    }

    if (install) {
        echo "Installing .NET SDK ${DOTNET_SDK_VERSION}"
        if (PLATFORM.contains("windows")) {
            batWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        } else {
            shWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        }
    } else {
        echo ".NET SDK ${DOTNET_SDK_VERSION} already installed"
    }
}
