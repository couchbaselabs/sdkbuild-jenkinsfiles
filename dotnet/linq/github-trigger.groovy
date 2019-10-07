pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "linq2couchbase-scripted-build-pipeline", parameters: [
                    string(name: "_INTERNAL_OK_", value: "true"),
                    string(name: "IS_GITHUB_TRIGGER", value: "true"),
                    // string(name: "GERRIT_BRANCH", value: "${GERRIT_BRANCH}"),
                    // string(name: "SHA", value: "${GERRIT_PATCHSET_REVISION}"),
                    // string(name: "GERRIT_REFSPEC", value: "${GERRIT_REFSPEC}")
                ]
            }
        }
    }
}
