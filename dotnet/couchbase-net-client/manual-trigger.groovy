pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "couchbase-net-client-scripted-build-pipeline", parameters: [
                    string(name: "_INTERNAL_OK_", value: "true"),
                    string(name: "GERRIT_BRANCH", value: GERRIT_BRANCH),
                    string(name: "SHA", value: GERRIT_BRANCH),
                    string(name: "VERSION", value: VERSION),
                    string(name: "IS_RELEASE", value: String.valueOf(IS_RELEASE))
                ]
            }
        }
    }
}
