// Please do not Save the Jenkins pipeline with a modified script.
// Instead, use the Replay function to test build script changes, then commit final changes
// to the sdkbuilds-jenkinsfile repository.
def DOTNET_SDK_VERSIONS = ["2.1.816", "3.1.410", "5.0.404", "6.0.101"]
def DOTNET_SDK_VERSION = "6.0.101"
def FLAVOR = IS_GERRIT_TRIGGER ? "-gerrit-" : "-latest-"
def SUFFIX = "r${BUILD_NUMBER}"
def BRANCH = ""

pipeline {
    agent none
    stages {
        stage("job valid?") {
            when {
                expression {
                    return _INTERNAL_OK_.toBoolean() != true || (IS_RELEASE.toBoolean() == true && (VERSION.contains('changeme') || VERSION == ""))
                }
            }
            steps {
                error("Exiting early as not valid run")
            }
        }
        stage("prepare and validate") {
            agent { label "centos6||centos7||ubuntu16||ubuntu14||ubuntu20" }
            steps {

				echo "Branch: ${GERRIT_BRANCH}"
				echo "SHA: ${SHA}"
				echo "Patchset: ${GERRIT_REFSPEC}"

                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("couchbase-net-client") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO"]]])
                }
                
                echo "Using dotnet core ${DOTNET_SDK_VERSION}"

                stash includes: "couchbase-net-client/", name: "couchbase-net-client", useDefaultExcludes: false
            }
        }
        stage("BuildAndTest") {
            matrix {
                axes {
                    axis {
                        name 'PLAT'
                        values "windows","ubuntu16","centos7","macos","ubuntu20", "qe-grav2-amzn2", "alpine", "m1", "qe-ubuntu20-arm64"
                    }
                }
                agent { label PLAT }
                stages {
                    stage("prep") {
                        steps {
                            cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                            unstash "couchbase-net-client"
                            installSdksForPlatform(PLAT, DOTNET_SDK_VERSIONS)
                            dotNetWithEcho(PLAT, "--info")
                        }
                    }
                    stage("build") {
                        steps {
                            dotNetWithEcho(PLAT, "build couchbase-net-client/couchbase-net-client.sln")
                            stash includes: "couchbase-net-client/", name: "couchbase-net-client-${PLAT}", useDefaultExcludes: false
                        }
                    }
                    stage("unit test") {
                        steps {
                            script {
                                def pairs = [:]
                                def unitTestProjects = findFiles(glob: "**/couchbase-net-client/tests/**UnitTest**/*.*proj")
                                def failures = 0
                                for (tp in unitTestProjects) {
                                    try {
                                        testOpts = "--test-adapter-path:. --logger \"trx\" ${tp} --filter FullyQualifiedName~UnitTest --no-build --blame-hang --blame-hang-timeout 5min" // --results-directory UnitTestResults"
                                        if (PLAT == "m1") {
                                            // we only support Apple M1 on .NET 6.0 or later
                                            testOpts = testOpts + " -f net6.0"
                                        }
                                        dotNetWithEcho(PLAT, "test ${testOpts}")
                                        pairs[tp.name] = "SUCCESS"
                                    } catch (Exception e) {
                                        pairs[tp.name] = "FAILED"
                                        failures = failures + 1
                                    }
                                }
                                
                                echo "done with unit tests for ${PLAT}"
                                echo "${pairs}"
                                testResultsGenerated = findFiles(glob:"**/TestResults/*.trx")
                                echo "All Test Results = ${testResultsGenerated}"
                                mstest testResultsFile:"**/*.trx", keepLongStdio: true
                                if (failures > 0) {
                                    error "${pairs}"
                                }
                            }
                        }
                    }
                }
            }
        }
        stage("package") {
            agent { label "windows" }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "couchbase-net-client-windows"
                installSdksForPlatform("windows", DOTNET_SDK_VERSIONS)

                script {
                    // get package version and apply suffix if not release build
                    def version = env.VERSION
                    if (env.IS_RELEASE.toBoolean() == false) {
                        version = "${version}-${FLAVOR}-${SUFFIX}"
                    }

                    // pack with SNK
                    if (version != "") {
                        withCredentials([file(credentialsId: 'netsdk-signkey', variable: 'SDKSIGNKEY')]) {
                            def toPack = [
                                "couchbase-net-client\\src\\Couchbase\\Couchbase.csproj",
                                "couchbase-net-client\\src\\Couchbase.Extensions.DependencyInjection\\Couchbase.Extensions.DependencyInjection.csproj",
                                "couchbase-net-client\\src\\Couchbase.Extensions.OpenTelemetry\\Couchbase.Extensions.OpenTelemetry.csproj",
                                "couchbase-net-client\\src\\Couchbase.Transactions\\Couchbase.Transactions.csproj"
                            ]

                            for (tp in toPack) {
                                packProject(tp, SDKSIGNKEY, version, DOTNET_SDK_VERSION)
                            }
                        }

                        // create zip file of release files and add it to archived artifacts
                        zip dir: "couchbase-net-client\\src\\Couchbase\\bin\\Release", zipFile: "couchbase-net-client-${version}.zip", archive: true
                    }
                }

                archiveArtifacts artifacts: "couchbase-net-client\\**\\*.nupkg, couchbase-net-client\\**\\*.snupkg", fingerprint: true
                stash includes: "couchbase-net-client\\**\\Release\\*.nupkg, couchbase-net-client\\**\\Release\\*.snupkg", name: "couchbase-net-client-package", useDefaultExcludes: false
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

def packProject(PROJ_FILE, nugetSignKey, version, DOTNET_SDK_VERSION) {
    depsDir = getDepsDir("windows")
    env.NUGET_SIGN_KEY = nugetSignKey
    versionParam = ""
    if (version != "") {
        versionParam = "/p:Version=${version}"
    }

    batWithEcho("${depsDir}\\dotnet-core-sdk-all\\dotnet build ${PROJ_FILE} -c Release /p:SignAssembly=true /p:AssemblyOriginatorKeyFile=%NUGET_SIGN_KEY% ${versionParam} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
    batWithEcho("${depsDir}\\dotnet-core-sdk-all\\dotnet pack ${PROJ_FILE} -c Release /p:SignAssembly=true /p:AssemblyOriginatorKeyFile=%NUGET_SIGN_KEY% ${versionParam} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
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
        if (PLATFORM != "m1" || dnv.startsWith("6.0")) {
            installSDK(PLATFORM, dnv)
        } else {
            echo "Skipping ${dnv} on ${PLATFORM}"
        }
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
                    if (PLATFORM != "m1" || dnv.startsWith("6.0")) {
                        // For UNIX, we use cp to preserve file permissions
                        shWithEcho("cp -r ../dotnet-core-sdk-${dnv}/* .")
                    } else {
                        // We only support .NET 6 on M1
                    }
                }
            }
        }
    }
}

def selectSDK(BRANCH, DOTNET_SDK_VERSIONS){
    if(BRANCH == "master"){
        return DOTNET_SDK_VERSIONS.last()
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
