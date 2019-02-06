pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "couchbase-net-client-scripted-build-pipeline", parameters: [
                    string(name: "SHA", value: SHA),
                    string(name: "REPO", value: REPO),
                    string(name: "IS_RELEASE", value: String.valueOf(IS_RELEASE)),
                    string(name: "_INTERNAL_OK_", value: "true"),
                    string(name: "VERSION", value: VERSION),
                ]
            }
        }
    }
}
