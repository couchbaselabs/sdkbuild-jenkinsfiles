pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "couchbase-net-client-scripted-build-pipeline", parameters: [
                    string(name: "_INTERNAL_OK_", value: "true")
                ]
            }
        }
    }
}
