// Please do not Save the Jenkins pipeline with a modified script.
// Instead, use the Replay function to test build script changes, then commit final changes
// to the sdkbuilds-jenkinsfile repository.
def DOTNET_SDK_VERSIONS = ["6.0.417", "8.0.100"]
def DOTNET_SDK_VERSION = "8.0.100"
def BUILD_VARIANT = IS_GERRIT_TRIGGER ? "buildbot" : "latest"
def SUFFIX = "r${BUILD_NUMBER}"
def BRANCH = ""
DERIVED_VERSION = "2.0.0-hardcoded"

pipeline {
    agent none
    stages {
        stage("prepare and validate") {
            agent { label "centos7||centos8||ubuntu20" }
            steps {

				echo "Branch: ${GERRIT_BRANCH}"
				echo "SHA: ${SHA}"
				echo "Patchset: ${GERRIT_REFSPEC}"

                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                dir("dotnet-couchbase-encryption") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO"]]])
                    script
                    {
                        if (env.IS_RELEASE.toBoolean() == true || VERSION != "") {
                            explicitVersion = VERSION
                        } else {
                            // first, look for a PACKAGE_VERSION line in the commit message of the latest checkin.
                            // NOTE: PACKAGE_VERSION should not be in the final commit message that goes into master.
                            explicitVersion = sh(
                                script: "git log -n 1 | grep PACKAGE_VERSION | perl -pe 's/PACKAGE_VERSION\\s*[:=]\\s*(.*)/\$1/g'",
                                returnStdout: true
                            ).trim()
                        }

                        if (explicitVersion != "")
                        {
                            DERIVED_VERSION = explicitVersion
                        }
                        else
                        {
                            // make sure we have all the tags that have been defined
                            sh("git fetch --tags origin")

                            // git tag # list the tags
                            // grep  # only versions in N.N.N format (no hyphens, extra info, etc)
                            // sort + tail # get the highest version
                            echo sh(
                                script: "git tag | grep -iE '[0-9]+\\.[0-9]+\\.[0-9]+\\s*\$' | sort --version-sort -s",
                                returnStdout: true)
                            DERIVED_VERSION=sh(
                                script: "git tag | grep -iE '[0-9]+\\.[0-9]+\\.[0-9]+\\s*\$' | sort --version-sort -s | tail -1",
                                returnStdout: true)
                        }

                        DERIVED_VERSION = DERIVED_VERSION.replaceAll("[\n\r]", "").trim()

                        if (env.IS_RELEASE.toBoolean() == true && DERIVED_VERSION != SHA.trim()) {
                            error "Releases should be done on a tag, not a raw SHA.  DERIVED_VERSION=${DERIVED_VERSION}, SHA=${SHA}"
                        }
                    }
                }
                echo "DERIVED_VERSION=${DERIVED_VERSION}"
                echo "full version = ${getVersion(DERIVED_VERSION, BUILD_VARIANT, SUFFIX)}"
                echo "Using dotnet core ${DOTNET_SDK_VERSION}"

                stash includes: "dotnet-couchbase-encryption/", name: "dotnet-couchbase-encryption", useDefaultExcludes: false
            }
        }
        stage("BuildAndTest") {
            matrix {
                axes {
                    axis {
                        name 'PLAT'
                        values "windows","centos8","macos","ubuntu20", /*"qe-grav2-amzn2",*/ "alpine", "m1", "qe-ubuntu20-arm64", "qe-ubuntu22-arm64", "qe-ubuntu24-arm64", "qe-ubuntu24-amd64",
                    }
                }
                agent { label PLAT }
                stages {
                    stage("prep") {
                        steps {
                            echo "DERIVED_VERSION=${DERIVED_VERSION}"
                            cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                            unstash "dotnet-couchbase-encryption"
                            installSdksForPlatform(PLAT, DOTNET_SDK_VERSIONS)
                            dotNetWithEcho(PLAT, "--info")
                        }
                    }
                    stage("build") {
                        steps {
                            dotNetWithEcho(PLAT, "build dotnet-couchbase-encryption/dotnet-couchbase-encryption.sln /p:Version=${DERIVED_VERSION}.${BUILD_NUMBER}")
                            echo "Build finished"
                            script {
                                // get package version from latest release tag and apply suffix if not release build
                                // NOTE: this means the release SHA must be tagged *before* the package is built.
                                def version = getVersion(DERIVED_VERSION, BUILD_VARIANT, SUFFIX)
                                if (PLAT == "windows") {
                                    withCredentials([file(credentialsId: 'netsdk-signkey', variable: 'SDKSIGNKEY')]) {
                                        def toPack = [
                                        "dotnet-couchbase-encryption/src/Couchbase.Encryption/Couchbase.Encryption.csproj"
                                        ]

                                        for (tp in toPack) {
                                            packProject(tp, SDKSIGNKEY, version, DOTNET_SDK_VERSION)
                                        }
                                    }
                                    // create zip file of release files and add it to archived artifacts
                                    zip dir: "dotnet-couchbase-encryption/src/Couchbase.Encryption/bin/Release", zipFile: "Couchbase-Encryption-${version}.zip", archive: true

                                    archiveArtifacts artifacts: "dotnet-couchbase-encryption/**/*.nupkg, dotnet-couchbase-encryption/**/*.snupkg", fingerprint: true
                                    stash includes: "dotnet-couchbase-encryption/**/Release/*.nupkg, dotnet-couchbase-encryption/**/Release/*.snupkg", name: "dotnet-couchbase-encryption-package", useDefaultExcludes: false

                                }
                            }
                            stash includes: "dotnet-couchbase-encryption/", name: "dotnet-couchbase-encryption-${PLAT}", useDefaultExcludes: false
                        }
                    }
                    stage("unit test") {
                        steps {
                            script {
                                def pairs = [:]
                                def unitTestProjects = findFiles(glob: "**/dotnet-couchbase-encryption/tests/**UnitTest**/*.*proj")
                                def failures = 0
                                for (tp in unitTestProjects) {
                                    try {
                                        testOpts = "--test-adapter-path:. --logger \"trx\" ${tp} --filter FullyQualifiedName~UnitTest --no-build --blame-hang --blame-hang-timeout 5min" // --results-directory UnitTestResults"
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
    }
}

void shWithEcho(String command) {
    echo "[$STAGE_NAME]"+ sh (script: command, returnStdout: true)
}

void batWithEcho(String command) {
    echo "[$STAGE_NAME]"+ bat (script: command, returnStdout: true)
}

def getVersion(derivedVersion, buildVariant, suffix) {
    def version = derivedVersion.trim()
    if (env.IS_RELEASE.toBoolean() == false) {
        version = "${version}-${buildVariant.trim()}-${suffix.trim()}"
    }

    version = version.replaceAll("[\n\r]", "")
    return version
}

def packProject(PROJ_FILE, nugetSignKey, version, DOTNET_SDK_VERSION) {
    depsDir = getDepsDir("windows")
    env.NUGET_SIGN_KEY = nugetSignKey
    versionParam = ""
    if (version != "") {
        versionParam = "/p:Version=${version}"
    }

    dotNetWithEcho("windows", "build ${PROJ_FILE} -c Release /p:SignAssembly=true /p:AssemblyOriginatorKeyFile=%NUGET_SIGN_KEY% ${versionParam} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true")
    dotNetWithEcho("windows", "pack ${PROJ_FILE} -c Release /p:SignAssembly=true /p:AssemblyOriginatorKeyFile=%NUGET_SIGN_KEY% ${versionParam} /p:IncludeSymbols=true /p:IncludeSource=true /p:SourceLinkCreate=true /p:SymbolPackageFormat=snupkg")
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
