pipeline {
    agent none
    parameters {
        string(name: 'BUILD_PIPELINE_NAME', defaultValue: 'couchbase-net-client-scripted-build-pipeline', description: 'Build pipeline to copy artifacts from.')
    }
    stages {
        stage('Pick Packages') {
            agent { label 'centos8||ubuntu16||ubuntu20' }
            steps {
                cleanWs()
                
                // shWithEcho("cbdep install -d deps dotnet-core-sdk 6.0.101")
                script {
                    echo "SELECTED_BUILD = ${SELECTED_BUILD}"
                    echo "PACKAGES_TO_PUBLISH = ${PACKAGES_TO_PUBLISH}"
                    def pattern = PACKAGES_TO_PUBLISH.split('\n').join('|')
                    pattern = "(${pattern}).*\\.nupkg"
                    copyArtifacts(projectName: params.BUILD_PIPELINE_NAME, selector: buildParameter('SELECTED_BUILD'))
                    nugets = findFiles(glob: "**/Release/**/*.nupkg")
                    snugets = findFiles(glob: "**/**/*.snupkg")
                    echo "nugets = ${nugets}"
                    echo "symbols = ${snugets}"
                    if (nugets.length == 0) {
                        echo "No releease packages found.  Looking for debug packages."
                        nugets = findFiles(glob: "**/*.nupkg")
                    }

                    def toPublish = [ ]
                    for (pkg in nugets) {
                        echo "pkg = ${pkg}"
                        if (pkg =~ ".*.symbols.nupkg") {
                            echo "Skipping ${pkg} in favor of snupkg (build with /p:SymbolPackageFormat=snupkg or update your project files accordingly)"
                        } else if (pkg =~ pattern) {
                            echo "${pkg} matches ${pattern}"
                            toPublish.add(pkg.path)
                        }
                        else {
                            echo "(no match)"
                        }
                    }

                    def stashDir = "publish-nuget-${BUILD_NUMBER}"
                    dir (stashDir) {
                        for (filePath in toPublish) {
                            shWithEcho("cp ../${filePath} .")
                            shWithEcho("nupkg=${filePath} && cp \"../\${nupkg%.*}.snupkg\" .")
                        }
                    }

                    stash name: stashDir, includes: "${stashDir}/*"
                    dir(stashDir) {
                        shWithEcho('ls -l')
                    }
                }
            }
        }
        stage("approval") {
            agent none
            steps {
                input "Continue with Publish to NuGet?"
            }
        }
        stage('Publish NuGets') {
            agent { label 'centos8||ubuntu16||ubuntu20' }
            steps {
                shWithEcho("cbdep install -d deps dotnet-core-sdk 6.0.101")
                unstash "publish-nuget-${BUILD_NUMBER}"
                
                script {
                    withCredentials([string(credentialsId: 'netsdk-nugetkey', variable: 'NUGETKEY')]) {
                        if (!NUGETKEY?.trim()) {
                            echo "No Nuget key configured, unable to publish package"
                        } else {
                            echo "Publishing to NuGet"
                            shWithEcho('deps/dotnet-core-sdk-6.0.101/dotnet nuget push "publish-nuget-${BUILD_NUMBER}/*.nupkg" -k $NUGETKEY -s https://api.nuget.org/v3/index.json')
                        }
                    }
                }
            }
        }
    }
}

void shWithEcho(String command) {
    echo sh (script: command, returnStdout: true)
}