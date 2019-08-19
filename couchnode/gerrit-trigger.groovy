pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "couchnode-scripted-build-pipeline", parameters: [
                    string(name: "SHA", value: "${GERRIT_PATCHSET_REVISION}"),
                    string(name: "GERRIT_REFSPEC", value: "${GERRIT_REFSPEC}"),
                    string(name: "_INTERNAL_OK_", value: "true"),
                    string(name: "IS_GERRIT_TRIGGER", value: "true"),
                ]
            }
        }
    }
}
