pipeline {
    agent none
    stages {
        stage('pipeline') {
            steps {
                build job: String.valueOf(BUILD_JOB), parameters: [
                        string(name: "SHA", value: SHA),
                        string(name: "REPO", value: REPO),
                        string(name: "LCB_VERSION", value: LCB_VERSION),
                        string(name: "IS_RELEASE", value: "TRUE"),
                        string(name: "IS_GERRIT_TRIGGER", value: "FALSE"),
                        string(name: "PYCBC_VALGRIND", value: String.valueOf(PYCBC_VALGRIND)),
                        string(name: "PYCBC_DEBUG_SYMBOLS", value: String.valueOf(PYCBC_DEBUG_SYMBOLS)),
                        string(name: "PLATFORMS", value: String.valueOf(PLATFORMS)),
                        string(name: "PY_VERSIONS", value: String.valueOf(PY_VERSIONS)),
                        string(name: "PYCBC_LCB_APIS", value: String.valueOf(PYCBC_LCB_APIS)),
                        string(name: "PYCBC_VERSION", value: String.valueOf(PYCBC_VERSION)),
                        string(name: "PY_ARCHES", value: String.valueOf(PY_ARCHES)),
                        string(name: "SERVER_VERSIONS", value: String.valueOf(SERVER_VERSIONS)),
                        string(name: "WORKFLOW_BRANCH", value: String.valueOf(WORKFLOW_BRANCH)),
                        string(name: "_INTERNAL_OK_", value: "true")
                ]
            }
        }
    }
}