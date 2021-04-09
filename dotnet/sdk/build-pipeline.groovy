// Please do not Save the Jenkins pipeline with a modified script.
// Instead, use the Replay function to test build script changes, then commit final changes
// to the sdkbuilds-jenkinsfile repository.
def PLATFORMS = [
    "windows",
    "ubuntu16",
    "centos7",
	"macos"
]
def DOTNET_SDK_VERSIONS = ["2.2.402", "3.1.404"]
def DOTNET_SDK_VERSION = ""
def CB_SERVER_VERSIONS = [
    "7.0.0-3507",
    "6.6.0",
    "6.5.0",
	"6.0.0",
	"5.5.2"
]
def SUFFIX = "r${BUILD_NUMBER}"
def BRANCH = ""

// use Replay and change this line to force Combination tests to run, even on a gerrit-trigger build.
// useful for testing test-only changes.
def FORCE_COMBINATION_TEST_RUN = false

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
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO"]]])
                }

				script {
					BRANCH = "${GERRIT_BRANCH}"
					DOTNET_SDK_VERSION = selectSDK(BRANCH, DOTNET_SDK_VERSIONS)
				}

                // TODO: UPDATE METADATA HERE (SEE GOCB OR COUCHNODE FOR EXAMPLES)
                // TODO: PUT ANY LINTING/CODE QUALITY TOOLS HERE TOO
                

                echo "Using dotnet core ${DOTNET_SDK_VERSION}"

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
        stage("combination-test") {
            agent { label "sdkqe-centos7" }
			when {
                expression { return IS_GERRIT_TRIGGER.toBoolean() != true || RUN_COMBINATION_TESTS.toBoolean() == true || FORCE_COMBINATION_TEST_RUN }
            }
            steps {
                doCombinationTests(CB_SERVER_VERSIONS, DOTNET_SDK_VERSION, BRANCH)
            }
        }
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
                    /*
                    dir("couchbase-net-client") {
                        def REL_VERSION = env.VERSION
                        sh("""
                            git config user.name "Couchbase SDK Team"
                            git config user.email "sdk_dev@couchbase.com"
                            git config user.signingkey 50984187E4FCD540EF7461781616981CC4A088B2
                            git tag -asm "Release v$REL_VERSION" v$REL_VERSION
                            git push origin v$REL_VERSION
                        """)
                    }
                    */

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
                        if (platform.contains("window")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet build couchbase-net-client\\couchbase-net-client.sln")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet build couchbase-net-client/couchbase-net-client.sln")
                        }
                    } else if (BRANCH == "release27") {
                        if (platform.contains("window")) {
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
                        if (platform.contains("window")) {
                            try {
                                batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test --test-adapter-path:. --logger:junit couchbase-net-client\\tests\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f netcoreapp3.1 --no-build")
                            }
                            finally {
                                junit allowEmptyResults: true, testResults: "couchbase-net-client\\tests\\Couchbase.UnitTests\\TestResults\\TestResults.xml"
                            }
                        } else {
                            try {
                                shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test --test-adapter-path:. --logger:junit couchbase-net-client/tests/Couchbase.UnitTests/Couchbase.UnitTests.csproj -f netcoreapp3.1 --no-build")
                            }
                            finally {
                                junit  allowEmptyResults: true, testResults: "couchbase-net-client/tests/Couchbase.UnitTests/TestResults/TestResults.xml"
                            }
                        }
                    } else if (BRANCH == "release27") {
                        if (platform.contains("window")) {
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet restore couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj")//cleanup if NuGet hangs
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f net452 --no-build")
                            batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f netcoreapp2.0 --no-build")
                            //batWithEcho("deps\\dotnet-core-sdk-${DOTNET_SDK_VERSION}\\dotnet test couchbase-net-client\\Src\\Couchbase.UnitTests\\Couchbase.UnitTests.csproj -f netcoreapp1.1 --no-build")
                        } else {
                            shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet restore couchbase-net-client/Src/Couchbase.UnitTests/Couchbase.UnitTests.csproj")//cleanup if NuGet hangs
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

def doCombinationTests(CB_SERVER_VERSIONS, DOTNET_SDK_VERSION, BRANCH) {
    installSDK("ubuntu16", DOTNET_SDK_VERSION)
    sh("cbdyncluster ps -a")
    for (j in CB_SERVER_VERSIONS) {
        cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
        unstash "couchbase-net-client-ubuntu16"
        def cluster_version = j
        def caps = "kv,index,n1ql,fts"
        if (cluster_version>="5.5"){
            caps=caps+",cbas"
        }

        stage("combination-test ${cluster_version}") {
            environment {
                CB_SERVER_VERSION = cluster_version
            }
            def clusterId = null
            try {
                // Allocate the cluster
                clusterId = sh(script: "cbdyncluster allocate --num-nodes=3 --server-version=" + cluster_version, returnStdout: true)
                echo "Got cluster ID $clusterId"

                // Find the cluster IP
                def ips = sh(script: "cbdyncluster ips $clusterId", returnStdout: true).trim()
                echo "Got raw cluster IPs " + ips
                ips = ips.tokenize(',')
                def ip = ips[0]
                echo "Got cluster IP http://" + ip + ":8091"

                shWithEcho("cbdyncluster --node ${caps} --node kv --node kv --bucket default setup ${clusterId}")

                // Create the cluster
                shWithEcho("curl -v -X POST -u Administrator:password -d 'memoryQuota=2048' http://${ip}:8091/pools/default" )
                shWithEcho("cbdyncluster --name=beer-sample add-sample-bucket $clusterId")
                shWithEcho("cbdyncluster --name=travel-sample add-sample-bucket $clusterId")

                // setup buckets, users, storage mode
                // TODO: one command that does all the default bucket setup (flush, replica, etc...)
                shWithEcho("curl -vv -X POST -u Administrator:password -d'storageMode=plasma' http://${ip}:8091/settings/indexes")
                shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://${ip}:8091/pools/default/buckets/default")
                shWithEcho("curl -v -X POST -u Administrator:password -d replicaNumber=2 http://${ip}:8091/pools/default/buckets/default")
                // give time for bucket to populate, before rebalancing
                sleep(30)
                shWithEcho("curl http://Administrator:password@${ip}:8091/pools/default/buckets/beer-sample")
                shWithEcho("curl http://Administrator:password@${ip}:8091/pools/default/buckets/travel-sample")
                shWithEcho("curl -vv -X POST -u Administrator:password -d 'knownNodes=ns_1%40${ip}%2Cns_1%40${ips[1]}%2Cns_1%40${ips[2]}' http://${ip}:8091/controller/rebalance")
                waitUntilRebalanceComplete("${ip}")
                shWithEcho("curl -vv -XPOST http://Administrator:password@${ip}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON `default` USING GSI'")
                shWithEcho("curl -vv -XPOST http://Administrator:password@${ip}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON `beer-sample` USING GSI'")
                shWithEcho("curl -vv -XPOST http://Administrator:password@${ip}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON `travel-sample` USING GSI'")

                // sleep a bit so the index should probably be ready.
                sleep(30)


                if (BRANCH == "master") {
                    def configFile = "couchbase-net-client/tests/Couchbase.IntegrationTests/config.json"
                    def projFile   = "couchbase-net-client/tests/Couchbase.IntegrationTests/Couchbase.IntegrationTests.csproj"
                    def configFileManagement = "couchbase-net-client/tests/Couchbase.IntegrationTests.Management/config.json"
                    def testResults = "couchbase-net-client/tests/Couchbase.IntegrationTests.Management/TestResults/TestResults.xml"
                    def projFileManagement   = "couchbase-net-client/tests/Couchbase.IntegrationTests.Management/Couchbase.IntegrationTests.Management.csproj"
                    
                    // replace hostname in config.json
                    shWithEcho("sed -i -e 's/localhost/${ip}/' ${configFile}")
                    shWithEcho("cat ${configFile}")
                    shWithEcho("sed -i -e 's/localhost/${ip}/' ${configFileManagement}")
                    shWithEcho("cat ${configFile}")
                    
                    // run management tests to set up environment
                    shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test -f netcoreapp3.1 --filter DisplayName~VerifyEnvironment ${projFileManagement}")
                    sleep(30);

                    // run integration tests
                    try {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test --test-adapter-path:. --logger:junit -f netcoreapp3.1 ${projFile}")
                    }
                    finally {
                        junit allowEmptyResults: true, testResults: "couchbase-net-client/tests/Couchbase.IntegrationTests/TestResults/TestResults.xml"
                    }

                    // run integration tests
                    try {
                        shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test --test-adapter-path:. --logger:junit -f netcoreapp3.1  ${projFileManagement}")
                    }
                    finally {
                        junit allowEmptyResults: true, testResults: "couchbase-net-client/tests/Couchbase.IntegrationTests.Management/TestResults.xml"
                    }
                }
                else if (BRANCH == "release27") {
                    // This does not actually work as it doesn't appear the integration tests
                    // in the 2.7 releases actually supports our CI environment currently.
                    
                    // replace hostname in config.json
                    //shWithEcho("sed -i -e 's/localhost/${ip}/' couchbase-net-client/Src/Couchbase.IntegrationTests/config.json")
                    //shWithEcho("cat couchbase-net-client/Src/Couchbase.IntegrationTests/config.json")

                    // run integration tests
                    //shWithEcho("deps/dotnet-core-sdk-${DOTNET_SDK_VERSION}/dotnet test couchbase-net-client/Src/Couchbase.IntegrationTests/Couchbase.IntegrationTests.csproj")
                }
                else {
                    echo "Unknown gerrit branch ${BRANCH}"
                }
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

    dir("deps") {
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
            batWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        } else {
            shWithEcho("cbdep install -d deps dotnet-core-sdk ${DOTNET_SDK_VERSION}")
        }
    }
}

def selectSDK(BRANCH, DOTNET_SDK_VERSIONS){
    if(BRANCH == "master"){
        return DOTNET_SDK_VERSIONS[1]
    }else{
        return DOTNET_SDK_VERSIONS[0]
    }
}

void waitUntilRebalanceComplete(String ip) {
    def cmd = "curl -u Administrator:password http://${ip}:8091/pools/default/rebalanceProgress"
    progress = true
    iterations = 0
    while(progress && iterations < 20) {
        def ret = sh(returnStdout: true, script: cmd).trim()
        echo("got '${ret}'")
        iterations += 1
        progress = !ret.contains("""{"status":"none"}""")
        if(progress) {
            echo("got '${ret}', sleeping for 20 sec")
            sleep(20)
        }
    }

}

void curl_with_retry(String url, String method, String data) {
    def command = """curl -u Administrator:password -X ${method} -s -o /dev/null -w "%{http_code}" -d '${data}' ${url} """
    echo(command)
    def return_code = 500
    retval = 1
    iterations =  0
    while(retval > 0 && iterations < 10) {
        def ret = sh(returnStdout: true, script: command).trim()
        iterations += 1
        echo "returned ${ret}"
        return_code = ret as int
        // 2XX is success, but sometimes the bucket is already there
        // (in the case of installing the sample buckets), so lets ignore
        // that and just make this "not 500"
        if (return_code > 199 && return_code < 500) {
            echo("success = ${return_code}")
            retval = 0
        } else {
            echo("got #{return_code}, sleeping for 20 sec to try again...")
            sleep(20)
        }
    }
    return retval
}
