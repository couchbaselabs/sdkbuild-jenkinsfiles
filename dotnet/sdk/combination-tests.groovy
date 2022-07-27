def LINUX_AGENTS = 'centos8||ubuntu16||ubuntu20'
def QE_AGENTS = "sdkqe-centos8"
def DOTNET_SDK_VERSIONS = ["3.1.410", "5.0.404", "6.0.101"]
def CLUSTER_VERSION = "7.0-stable"
def CURRENT_CLUSTER_ID = ""
def CURRENT_CLUSTER_IP = ""

pipeline {
    agent none
    stages {
        stage('Prepare') {
            agent { label LINUX_AGENTS }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                script {
                    echo "SELECTED_BUILD = ${SELECTED_BUILD}"
                    copyArtifacts(projectName: params.BUILD_PIPELINE_NAME, selector: buildParameter('SELECTED_BUILD'))
                    nugets = findFiles(glob: "**/Release/**/CouchbaseNetClient.*.nupkg")
                    snugets = findFiles(glob: "**/**/CouchbaseNetClient.*.snupkg")
                    echo "nugets = ${nugets}"
                    echo "symbols = ${snugets}"
                    if (nugets.length == 0) {
                        echo "No release packages found.  Looking for debug packages."
                        nugets = findFiles(glob: "**/CouchbaseNetClient.*.nupkg")
                    }

                    def stashDir = "local-nugets"
                    dir (stashDir) {
                        for (filePath in nugets) {
                            shWithEcho("cp ../${filePath} .")
                            shWithEcho("nupkg=${filePath} && cp \"../\${nupkg%.*}.snupkg\" .")
                        }
                    }

                    stash name: stashDir, includes: "${stashDir}/*"
                    dir(stashDir) {
                        shWithEcho('ls -l')
                    }
                }

                echo "Branch: ${GERRIT_BRANCH}"
				echo "SHA: ${SHA}"
				echo "Patchset: ${GERRIT_REFSPEC}"

                dir("couchbase-net-client") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO"]]])
                }

                stash includes: "couchbase-net-client/", name: "couchbase-net-client", useDefaultExcludes: false
            }
        }
        stage('Build and Test') {
            agent { label QE_AGENTS }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                unstash "couchbase-net-client"
                unstash "local-nugets"
                installSdksForPlatform("linux", DOTNET_SDK_VERSIONS)
                dotNetWithEcho("linux", "--info")
                script {
                    def clusterInfo = startCluster(CLUSTER_VERSION, 3)
                    echo "clusterInfo = ${clusterInfo}"
                    CURRENT_CLUSTER_ID = clusterInfo.clusterId
                    CURRENT_CLUSTER_IP = clusterInfo.clusterIp
                    def settingsFile = 'couchbase-net-client/tests/Couchbase.CombinationTests/settings.json'
                    def combiTestSettings = readJSON file: settingsFile
                    combiTestSettings.couchbase.connectionString = "couchbase://${clusterInfo.clusterIp}".toString()
                    writeJSON json:combiTestSettings, file: settingsFile
                    shWithEcho("cat ${settingsFile}")
                }


                script {
                    try {
                        dotNetWithEcho("linux", "nuget add source ${env.WORKSPACE}/local-nugets --name locals || echo 'add source failed'")
                    } catch (Exception e) {
                        echo "add source failed due to ${e}"
                    } finally {
                        dotNetWithEcho("linux", "nuget list source")
                    }
                    nugets = findFiles(glob: "local-nugets/CouchbaseNetClient.*.nupkg")
                    def matcher = nugets[0] =~ /CouchbaseNetClient\.(.*)\.nupkg/
                    def explicitVersion = matcher[0][1]
                    echo "explicitVersion = ${explicitVersion}"
                    try {
                        def versionOverride = "-p:ExplicitCouchbaseNetClientNuget=${explicitVersion}"
                        dotNetWithEcho("linux", "test ${versionOverride} --test-adapter-path:. --logger \"trx\" couchbase-net-client/tests/Couchbase.CombinationTests/ --blame-hang --blame-hang-timeout 5min")
                    } finally {
                        testResultsGenerated = findFiles(glob:"**/TestResults/*.trx")
                        echo "All Test Results = ${testResultsGenerated}"
                        mstest testResultsFile:"**/*.trx", keepLongStdio: true
                    }
                }
            }
            post {
                cleanup {
                    script {
                        if (CURRENT_CLUSTER_ID != "") {
                            removeCluster(CURRENT_CLUSTER_ID)
                        }
                        else
                        {
                            echo "no cluster to remove"
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


def exampleFunc() {
    return [foo: 'bar', baz: 'boo']
}

void removeCluster(clusterID) {
    shWithEcho("cbdyncluster rm ${clusterID}")
}

def startCluster(clusterVersion, numNodes) {
    stage("start cluster version : ${clusterVersion}"){
        def clusterId = null
        try{
            // For debugging, what clusters are open
            shWithEcho("cbdyncluster ps -a")

            // Allocate the cluster
            clusterId = sh(script: "cbdyncluster allocate --num-nodes="+numNodes+" --server-version=" + clusterVersion, returnStdout: true)
            echo "Got cluster ID $clusterId"
            CURRENT_CLUSTER_ID = "${clusterId}"

            //Find the cluster IP
            def ips = sh(script: "cbdyncluster ips $clusterId", returnStdout: true).trim()
            echo "Got raw cluster IPs " + ips
            def ip = ips.tokenize(',')[0]
            echo "Got cluster IP http://" + ip + ":8091"
            CURRENT_CLUSTER_IP = "${ip}"
            sleep(30)
            //Figure services for the cluster
            nodesInCluster = numNodes
            def nodesInfo=" --node kv,index,n1ql,fts,cbas"
            nodesInfo = "$nodesInfo --node kv,index,n1ql,fts,cbas"
            for(int i =2;i<nodesInCluster;i++ ){
                nodesInfo = "$nodesInfo --node kv"
            }

            shWithEcho("cbdyncluster  $nodesInfo setup $clusterId")

            def numReplicas = 1
            shWithEcho("cbdyncluster add-bucket --name default --replica-count $numReplicas $clusterId")
            sleep(10)
            shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://" + ip + ":8091/pools/default/buckets/default")
            shWithEcho("curl -v -X POST -u Administrator:password -d 'storageMode=plasma' http://" + ip + ":8091/settings/indexes")
            return [clusterId: clusterId, clusterIp: ip, numReplicas: numReplicas, clusterVersion: clusterVersion, numNodes: numNodes]
        }catch(Exception ex){
            error("Unable to start cluster: $clusterVersion due to  : ${ex}")
        }
    }
}