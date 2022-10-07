TO_PUBLISH = [ ]
pipeline {
    agent none
    parameters {
        string(name: 'BUILD_PIPELINE_NAME', defaultValue: 'couchbase-net-client-scripted-build-pipeline', description: 'Build pipeline to copy artifacts from.')
    }
    stages {
        stage('Pick ZipFile') {
            agent { label 'centos8||ubuntu16||ubuntu20' }
            steps {
                cleanWs()

                // shWithEcho("cbdep install -d deps dotnet-core-sdk 6.0.101")
                script {
                    echo "SELECTED_BUILD = ${SELECTED_BUILD}"
                    copyArtifacts(projectName: params.BUILD_PIPELINE_NAME, selector: buildParameter('SELECTED_BUILD'))
                    zipFile = findFiles(glob: "**/Couchbase-Net-Client-*.zip")
                    echo "zipFile = ${zipFile}"
                    if (zipFile.length == 0) {
                        error "No releease ZIPs found."
                    }

                    for (pkg in zipFile) {
                        echo "pkg = ${pkg}"
                        TO_PUBLISH.add(pkg.path)
                    }

                    def stashDir = "publish-zipfile-${BUILD_NUMBER}"
                    dir (stashDir) {
                        for (filePath in TO_PUBLISH) {
                            shWithEcho("cp ../${filePath} .")
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
                input "Continue with Publish to S3? (${TO_PUBLISH})"
            }
        }
        stage('publish') {
            agent { label 'centos8' }
            steps {
                cleanWs(patterns: [[pattern: 'deps/**', type: 'EXCLUDE']])
                script {
                    def stashDir = "publish-zipfile-${BUILD_NUMBER}"
                    unstash stashDir
                    dir(stashDir)
                    {
                        for (pkg in TO_PUBLISH) {
                            withAWS(credentials: 'aws-sdk', region: 'us-east-1') {
                                s3Upload(
                                    bucket: 'packages.couchbase.com',
                                    path: "clients/net/3.3/",
                                    acl: 'PublicRead',
                                    file: "${pkg}",
                                )
                            }
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