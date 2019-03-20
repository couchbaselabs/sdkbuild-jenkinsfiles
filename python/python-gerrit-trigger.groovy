pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: "python-scripted-build-pipeline", parameters: [
                        string(name: "SHA", value: "${GERRIT_PATCHSET_REVISION}"),
                        string(name: "GERRIT_REFSPEC", value: "${GERRIT_REFSPEC}"),
                        string(name: "REPO", value: "http://review.couchbase.com/p/couchbase-python-client.git"),
                        string(name: "_INTERNAL_OK_", value: "true"),
                        string(name: "PYCBC_DEBUG_SYMBOLS", value: "TRUE"),
                        string(name: "IS_GERRIT_TRIGGER", value: ("${GERRIT_CHANGE_COMMIT_MESSAGE}".contains("SDKJENKINS_FULL_PIPELINE"))?"FALSE":"TRUE"),
                        string(name: "WORKFLOW_BRANCH", value: ("${GERRIT_CHANGE_COMMIT_MESSAGE}".contains("SDKJENKINS_PIP_INSTALL"))?"PYCBC_PIPINSTALL":"master"),
                        string(name: "PYCBC_ASSERT_CONTINUE", value: ("${GERRIT_CHANGE_COMMIT_MESSAGE}".contains("PYCBC_ASSERT_CONTINUE"))?"YES":""),
                        string(name: "PIP_INSTALL", value: ("${GERRIT_CHANGE_COMMIT_MESSAGE}".contains("PYCBC_PIP_INSTALL"))?"YES":""),
                        string(name: "PLATFORMS", value: ("${GERRIT_CHANGE_COMMIT_MESSAGE}".contains("SDKJENKINS_LINUX")?"ubuntu16":"ubuntu16 windows"))
                ]
            }
        }
    }
}