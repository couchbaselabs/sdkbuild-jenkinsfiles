import org.junit.Test

def PLATFORMS =  "${PLATFORMS}".split(/\s+/) ?: ["centos7", "windows-2012" ]
def DEFAULT_PLATFORM = PLATFORMS[0]
def PY_VERSIONS = "${PY_VERSIONS}".split(/\s+/) ?: [ "2.7.15", "3.7.0" ]
def PY_ARCHES = "${PY_ARCHES}".split(/\s+/) ?: [ "x64", "x86" ]
def SERVER_VERSIONS = "${SERVER_VERSIONS}"?[ "5.5.0", "6.0.0"]: "${SERVER_VERSIONS}".split(/\s+/)
def PACKAGE_PLATFORM = "${DEFAULT_PLATFORM}"
def PACKAGE_PY_VERSION = "2.7.15"
def PACKAGE_PY_VERSION_SHORT=PACKAGE_PY_VERSION.tokenize(".")[0] + "." + PACKAGE_PY_VERSION.tokenize(".")[1]
def PACKAGE_PY_ARCH = "x64"
echo "Got platforms ${PLATFORMS}"
echo "Got PY_VERSIONS ${PY_VERSIONS}"
echo "Got PY_ARCHES ${PY_ARCHES}"

def DEFAULT_PY_VERSION = PY_VERSIONS[0]
def DEFAULT_VERSION_SHORT=DEFAULT_PY_VERSION.tokenize(".")[0] + "." + DEFAULT_PY_VERSION.tokenize(".")[1]
def DEFAULT_PY_ARCH = PY_ARCHES[0]
def PARALLEL_PAIRS = "${PARALLEL_PAIRS}".toBoolean()
def WIN_PY_DEFAULT_VERSION = "3.7.0"
def PYCBC_ASSERT_CONTINUE = "${PYCBC_ASSERT_CONTINUE}"
String[] PYCBC_LCB_APIS="${PYCBC_LCB_APIS}"?"${PYCBC_LCB_APIS}".split(/,/):null
String COMMIT_MSG="${COMMIT_MSG}"
def USE_NOSE_GIT=true
def NOSE_GIT=USE_NOSE_GIT?"git+https://github.com/nose-devs/nose.git":""
String PYCBC_VERSION = "${PYCBC_VERSION}"
echo "Got PARALLEL_PAIRS ${PARALLEL_PAIRS}"

pipeline {
    agent none
    stages {
        stage('job valid?') {
            when {
                expression {
                    return _INTERNAL_OK_.toBoolean() != true
                }
            }
            steps {
                error("Exiting early as not valid run")
            }
        }
        stage('prepare and validate') {
            agent { label "${DEFAULT_PLATFORM}" }
            steps {
                cleanWs()
                shWithEcho("env")
                dir("couchbase-python-client") {
                    checkout([$class: 'GitSCM', branches: [[name: '$SHA']], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: '$REPO', poll: false]]])
                    script {
                        def metaData=readMetadata()
                        PYCBC_VERSION = getVersion(metaData)
                        if (PYCBC_LCB_APIS==null) {
                            def DEFAULT_LCB_API=null
                            try{
                                DEFAULT_LCB_API=metaData.comp_options.PYCBC_LCB_API
                            }
                            catch(Exception e){

                            }
                            DEFAULT_LCB_API=(DEFAULT_LCB_API!=null)?DEFAULT_LCB_API:"default"
                            PYCBC_LCB_APIS= [DEFAULT_LCB_API]
                            try {
                                echo("Trying to read LCB_APIS from ${metaData}")
                                def LCB_APIS = metaData.comp_options.PYCBC_LCB_API_ALL_SUPPORTED
                                if (LCB_APIS) {
                                    echo("Got LCB_APIS=${LCB_APIS}")
                                    PYCBC_LCB_APIS = LCB_APIS
                                    echo("Set PYCBC_LCB_APIS=${PYCBC_LCB_APIS}")
                                }
                            }
                            catch (Exception e) {
                                echo("Got exception ${e} trying to read PYCBC_LCB_API_ALL_SUPPORTED from ${metaData} ")
                            }
                        }
                        //tag_version(PYCBC_VERSION, DEFAULT_PLATFORM)
                    }
                }

                // TODO: UPDATE METADATA HERE
                script {
                    if (env.IS_RELEASE == true) {
                        echo "This is release, not updating metadata"
                    } else {
                        echo "This is not release, updating metadata but not because cant yet"
                    }
                }

                // TODO: RUN CODE QUALITY TOOLS HERE, e.g. LINTING

                stash includes: 'couchbase-python-client/', name: 'couchbase-python-client', useDefaultExcludes: false
            }
        }
        stage('build') {
            agent { label "master" }
            steps {
                buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, "${PYCBC_VALGRIND}", "${PYCBC_DEBUG_SYMBOLS}", "${IS_RELEASE}", "${WIN_PY_DEFAULT_VERSION}", PYCBC_LCB_APIS, "${NOSE_GIT}")
            }
        }
        stage('package') {
            agent { label "${PACKAGE_PLATFORM}" }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            environment {
                LCB_PATH="${WORKSPACE}/libcouchbase"
                LCB_BUILD="${WORKSPACE}/libcouchbase/build"
                LCB_LIB="${WORKSPACE}/libcouchbase/build/lib"
                LCB_INC="${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated"
                LD_LIBRARY_PATH="${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH"
                PATH="${WORKSPACE}/python/python${PACKAGE_PY_VERSION}:${WORKSPACE}/python/python${PACKAGE_PY_VERSION}/bin:$PATH"
            }
            steps {
                cleanWs()
                //unstash "lcb-" + PACKAGE_PLATFORM + "-" + PACKAGE_PY_VERSION + "-" + PACKAGE_PY_ARCH
                unstash "couchbase-python-client-build-" + PACKAGE_PLATFORM + "-" + PACKAGE_PY_VERSION + "-" + PACKAGE_PY_ARCH
                installPython("${PACKAGE_PLATFORM}", "${PACKAGE_PY_VERSION}", "${PACKAGE_PY_VERSION_SHORT}", "python", "${PACKAGE_PY_ARCH}")
                echo "My path:${PATH}"
                shWithEcho("""
                
echo "Path:${PATH}"
echo "Pip is:"
echo `which pip`

pip install --verbose Twisted gevent""")
                unstash "dist-" + PACKAGE_PLATFORM + "-" + PACKAGE_PY_VERSION + "-" + PACKAGE_PY_ARCH
                dir("couchbase-python-client") {
                    installReqs(PACKAGE_PLATFORM, NOSE_GIT)
                    shWithEcho("python setup.py build_sphinx")
                    shWithEcho("mkdir -p dist")
                }
                archiveArtifacts artifacts: "couchbase-python-client/build/sphinx/**/*", fingerprint: true, onlyIfSuccessful: false
                shWithEcho("cp -r dist/* couchbase-python-client/dist/")
                stash includes: 'couchbase-python-client/', name: "couchbase-python-client-package", useDefaultExcludes: false
            }
        }
        stage('test-integration-server') {
            agent { label 'qe-slave-linux1' }
            when {
                expression
                        { return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                doIntegration("${PACKAGE_PLATFORM}", "${PACKAGE_PY_VERSION}", "${PACKAGE_PY_VERSION_SHORT}", "${PACKAGE_PY_ARCH}", "${LCB_VERSION}", "${PYCBC_VALGRIND}", "${PYCBC_DEBUG_SYMBOLS}", SERVER_VERSIONS, "${WORKSPACE}", PYCBC_LCB_APIS, NOSE_GIT, "${PIP_INSTALL}", PYCBC_VERSION)
            }
        }
        stage('quality') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                // TODO: SITUATIONAL TESTING JOB WILL BE HOOKED HERE
            }
        }
        stage('snapshot') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == false && IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                // TODO: Upload build artefacts to snapshot server here
            }
        }
        stage('approval') {
            agent none
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true }
            }
            steps {
                emailext body: "Jenkins: approval required for PYCBC -$BUILD_URL", subject: 'Jenkins: approval required for PYCBC', to: 'ellis.breen@couchbase.com'
                input 'Publish?'
            }
        }
        stage('publish') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_RELEASE.toBoolean() == true }
            }
            steps {
                cleanWs()
                unstash "couchbase-python-client-package"
                doOptionalPublishing()
                dir ("couchbase-python-client") {
                    script {
                        if (false){
                            shWithEcho("""git push --tags""")
                        }
                    }
                }
            }
        }
    }
}

def tag_version(String PYCBC_VERSION, platform) {
    if (PYCBC_VERSION && PYCBC_VERSION.length() > 0) {
        dir("couchbase-python-client") {
            cmdWithEcho(platform, """
git config user.name "Couchbase SDK Team"
                            git config user.email "sdk_dev@couchbase.com"
""")

            cmdWithEcho(platform, """git tag -a ${PYCBC_VERSION} -m "Release of client version ${PYCBC_VERSION}" """, false)
        }
    }
}

def doOptionalPublishing()
{
    String PACKAGE_PY_VERSION = "2.7.15"
    envStr=getEnvStr("linux", PACKAGE_PY_VERSION,"x64","","")

    script{
        try{
            String version = getVersion(readMetadata())
            installPython("linux", "${PACKAGE_PY_VERSION}", "", "deps", "x64")
            withEnv(envStr){
                dir ("couchbase-python-client") {
                    withCredentials([usernameColonPassword(credentialsId: 'twine', usernameVariable: 'USER', passwordVariable: 'PASSWORD')]) {

                            sh("""
                                pip install twine
                                twine upload -u $USER -p $PASSWORD dist/* -r pypi"""
                            )
                    }
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-PYCBC']]) {
                        cmdWithEcho("unix", "aws s3 sync build/sphinx/html/ s3://docs.couchbase.com/sdk-api/couchbase-python-client-${PYCBC_VERSION} --acl public-read", true)
                    }
                }
            }
        }
        catch(Exception e)
        {
            echo("Caught failure while doing optional publishing steps: ${e}")
        }

    }
}

def getVersion(cbuild_cfg) {
    String version = "${PYCBC_VERSION}"

    if (version.length() == 0) {
        try {
            version = "${PYCBC_VERSION_JIRA}"
        }
        catch (Exception e) {
            echo("Could not read version from PYCBC_VERSION_JIRA: ${e}")
        }
    }

    if (version.length() == 0) {
        if (cbuild_cfg!=null)
        {
            try{
                version=cbuild_cfg.comp_options.PYCBC_VERSION
            }
            catch (Exception e){

            }
        }
    }
    if (version==null)
    {
        version=""
    }

    return version
}

def readMetadata() {
    try {
        def cbuild_cfg = readJSON file: 'cbuild_cfg.json'
        echo("Read build_cfg ${cbuild_cfg}")
        return cbuild_cfg
    }
    catch (Exception e) {
        echo("Could not read version from metadata: ${e}")
    }
    return null
}

/*
trait Platform
{
    void shell(String command, boolean returnStdout = true )
    {
        def STAGE_NAME="fred"
        print "[$STAGE_NAME]:${command}:"+this.real_shell(script:command, returnStdout: returnStdout)
        
    }
    abstract String real_shell(Map args)
}

class Windows implements Platform
{
   String real_shell(Map args){
        return bat(args)
    }
}

class Unix implements Platform
{
   String real_shell(Map args){
        return sh(args)
    }
}*/
class BuildParams{
    public String PYCBC_LCB_API=null

    BuildParams(String PYCBC_LCB_API) {
        this.PYCBC_LCB_API = PYCBC_LCB_API
    }
}

class TestParams{
    boolean INSTALL_REQS=false
    String NOSE_GIT=null
    String PYCBC_VALGRIND=null
    BuildParams buildParams
    TestParams(BuildParams buildParams, boolean INSTALL_REQS, String NOSE_GIT, String PYCBC_VALGRIND) {
        this.buildParams = buildParams
        this.INSTALL_REQS = INSTALL_REQS
        this.NOSE_GIT = NOSE_GIT
        this.PYCBC_VALGRIND=PYCBC_VALGRIND
    }

}

void installPython(String platform, String version, String pyshort, String path, String arch, boolean isDebug = false) {
    if (isDebug && false) { // workaround hack, disable for now
        //BigDecimal versionAsDecimal=BigDecimal.valueOf(Double.parseDouble(version))
        if (isWindows(platform)) {
            def PY_DEBUG_INSTALL_DIR = path//getPythonDebugInstall(platform, version, arch)
            def TEMP_DIR = "${WORKSPACE}\\temp"
            def FIXED_DIR = "${PY_DEBUG_INSTALL_DIR}"
            def DL="python-${version}${arch}.exe"
            def URL = "https://www.python.org/ftp/python/${version}/${DL}"
            batWithEcho("""
C:\\cbdep-priv\\wix-3.11.1\\dark.exe -x ${TEMP_DIR}  ${TEMP_DIR}\\${DL}
            msiexec /qn /a ${TEMP_DIR}\\AttachedContainer\\core_d.msi TARGETDIR=${FIXED_DIR}
            msiexec /qn /a ${TEMP_DIR}\\AttachedContainer\\lib_d.msi TARGETDIR=${FIXED_DIR}
            msiexec /qn /a ${TEMP_DIR}\\AttachedContainer\\dev_d.msi TARGETDIR=${FIXED_DIR}
            msiexec /qn /a ${TEMP_DIR}\\AttachedContainer\\exe_d.msi TARGETDIR=${FIXED_DIR}
            del ${FIXED_DIR}\\*.msi
            ${FIXED_DIR}\\python.exe -E -s -m ensurepip --default-pip
          ${FIXED_DIR}\\python.exe -m venv ${path}\\python${version}${arch}
""")
        }
        /*else
        {
            if (versionAsDecimal>=3.3)
            {
                shWithEcho("""
            export FIXED_DIR=${WORKSPACE}/.pyenv/versions/${version}
            git clone git://github.com/pyenv/pyenv.git ${HOME}/.pyenv 2>/dev/null || true
            cd ${HOME}/.pyenv && git pull
            ${HOME}/.pyenv/bin/pyenv install ${VERSION}
            fixed_dir: ${HOME}/.pyenv/versions/${VERSION}
            ${FIXED_DIR}/bin/python -m venv ${INSTALL_DIR}/python${version}
"""
            }
            else if (versionAsDecimal>=2.7 && versionAsDecimal< 3.0)
            shWithEcho("""
            export FIXED_DIR=${WORKSPACE}/.pyenv/versions/${version}
            git clone git://github.com/pyenv/pyenv.git ${HOME}/.pyenv 2>/dev/null || true
            cd ${HOME}/.pyenv && git pull
            ${HOME}/.pyenv/bin/pyenv install ${VERSION}
            ${FIXED_DIR}/bin/python -m pip install virtualenv
            ${FIXED_DIR}/bin/python -m virtualenv ${INSTALL_DIR}/python${VERSION}""")
        }*/
    } else {
        def cmd = "cbdep install python ${version} -d ${path}"
        if (arch == "x86") {
            cmd = cmd + " --x32"
        }

        def plat_class = null
        if (isWindows(platform)) {
            //plat_class = Windows()
            batWithEcho(cmd)
        } else {
            //plat_class = Unix()
            shWithEcho(cmd)
        }
    }
    //plat_class.shell(cmd)
}

private GString getPythonDebugInstall(String version, String arch) {
    "${WORKSPACE}\\cbdep\\Python${version}${arch}-debug"
}

def shWithEcho(String command) {
    result=sh(script: command, returnStdout: true)
    echo "[$STAGE_NAME]:${command}:"+ result
    return result
}

def batWithEcho(String command) {
    result=bat(script: command, returnStdout: true)
    echo "[$STAGE_NAME]:${command}:"+ result
    return result
}

def cmdWithEcho(platform, command, quiet=false)
{
    try{
        if (isWindows(platform)){
            return batWithEcho(command)
        }
        else{
            return shWithEcho(command)
        }
    }
    catch (Exception e)
    {
        if (quiet)
        {
            return ""
        }
        else
        {
            throw e
        }
    }
}

def isWindows(platform)
{
    
    return platform.toLowerCase().contains("windows")
}

def installReqs(platform, NOSE_GIT)
{
    dir("${WORKSPACE}/couchbase-python-client")
    {
        cmdWithEcho(platform,"""pip install -r dev_requirements.txt
""")
        if (!isWindows(platform)){
            if (NOSE_GIT) {
                shWithEcho("pip uninstall --yes nose && pip install ${NOSE_GIT}")
            }
        }
    }
}

String prefixWorkspace(String path){
    return "${WORKSPACE}/${path}"
}
def addCombi(combis,platform,PY_VERSION,PY_ARCH)
{

    if (isWindows(platform) && (PY_VERSION.contains("2.7"))) {
        return combis
    }

    if (!isWindows(platform) && PY_ARCH == "x86") {
        return combis
    }

    echo "adding ${platform}/${PY_VERSION}/${PY_ARCH} to ${combis}"
    def plat = combis.get("${platform}",null)
    if (plat==null)
    {
        plat =[:]
    }
    def version = plat.get("${PY_VERSION}",null)
    if (version==null)
    {
        version = [:]
    }
    arch=version.get("${PY_ARCH}",null)
    if (arch==null)
    {
        version.put("${PY_ARCH}","True")
        plat.put("${PY_VERSION}",version)
        combis.put("${platform}",plat)
    }
    echo "added, got ${combis}"
    return combis
}
def getCommitEnvStrAdditions() {
    commit_env_additions = []
    for (item in getAttribs().entrySet()) {
        commit_env_additions += ["${item.key}=${item.value}"]
    }
    return commit_env_additions
}

def getEnvStr( platform,  pyversion,  arch,  server_version, PYCBC_VALGRIND)
{
    PYCBC_DEBUG_LOG_LEVEL = "${PYCBC_DEBUG_LOG_LEVEL}" ?: ""
    LCB_LOGLEVEL = "${LCB_LOGLEVEL}" ?: ""
    
    common_vars=["PIP_INSTALL=${PIP_INSTALL}","LCB_LOGLEVEL=${LCB_LOGLEVEL}","PYCBC_DEBUG_LOG_LEVEL=${PYCBC_DEBUG_LOG_LEVEL}","PYCBC_JENKINS_INVOCATION=TRUE","PYCBC_MIN_ANALYTICS=${PYCBC_MIN_ANALYTICS}","PYCBC_TEST_OLD_ANALYTICS=${PYCBC_TEST_OLD_ANALYTICS}"]
    if ("${PYCBC_ASSERT_CONTINUE}"!="")
    {
        common_vars=common_vars+["PYCBC_ASSERT_CONTINUE=${PYCBC_ASSERT_CONTINUE}"]
    }        
    if (isWindows(platform)) {
        envStr = ["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH", "PYCBC_SERVER_VERSION=${server_version}"]//, "LCB_PATH=${WORKSPACE}\\libcouchbase", "LCB_BUILD=${WORKSPACE}\\libcouchbase\\build", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated", "LD_LIBRARY_PATH=${WORKSPACE}\\libcouchbase\\build\\lib;\$LD_LIBRARY_PATH"]
    } else {
        envStr = ["PYCBC_VALGRIND=${PYCBC_VALGRIND}","PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase", "LCB_BUILD=${WORKSPACE}/libcouchbase/build", "LCB_LIB=${WORKSPACE}/libcouchbase/build/lib", "LCB_INC=${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated", "LD_LIBRARY_PATH=${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH", "PYCBC_SERVER_VERSION=${server_version}"]
    }
    return envStr+common_vars+getCommitEnvStrAdditions()
}


def getEnvStr2(platform, pyversion, arch = "", server_version = "MOCK", PYCBC_LCB_API="DEFAULT", PYCBC_VALGRIND="") {
    envStr=[]
    PYCBC_LCB_API_SECTION=(PYCBC_LCB_API!="DEFAULT")?["PYCBC_LCB_API=${PYCBC_LCB_API}"]:[]
    if (isWindows(platform)) {
        envStr = PYCBC_LCB_API_SECTION+["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated"]
    } else {
        envStr = PYCBC_LCB_API_SECTION+["PYCBC_VALGRIND=${PYCBC_VALGRIND}", "PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase", "LCB_BUILD=${WORKSPACE}/libcouchbase/build", "LCB_LIB=${WORKSPACE}/libcouchbase/build/lib", "LCB_INC=${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated", "LD_LIBRARY_PATH=${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH"]
    }
    return envStr+getCommitEnvStrAdditions()
}


def getServiceIp(node_list, name)
{
                    //cbas_ip = first_ip
                    cbas_ip=node_list.last().ip
                for (entry in node_list){
                    if (name in entry.services)
                    {
                        cbas_ip=entry['ip']
                    }
                }
                return cbas_ip

}

def mkdir(GString test_full_path, platform) {
    dir(test_full_path) {}
    if (isWindows(platform)) {
        batWithEcho("""
setlocal enableextensions
md %1
endlocal
""")
    } else {
        shWithEcho("echo ${PWD} && mkdir -p ${test_full_path} && ls -alrt")
    }
}

List getNoseArgs(SERVER_VERSION, String platform, pyversion = "", TestParams testParams) {
    sep = getSep(platform)
    test_rel_path = "${platform}_${pyversion}_${SERVER_VERSION}_" + testParams.buildParams.PYCBC_LCB_API ?: ""
    test_full_path = "couchbase-python-client${sep}${test_rel_path}"
    test_rel_xunit_file = "${test_rel_path}${sep}nosetests.xml"

    nosetests_args = " --with-xunit --xunit-file=${test_rel_xunit_file} -v "
    if (testParams.NOSE_GIT && !isWindows(platform))
    {
        nosetests_args+="--xunit-testsuite-name=${test_rel_path} --xunit-prefix-with-testsuite-name"
    }
    mkdir(test_full_path, platform)
    [test_rel_path, nosetests_args, test_full_path]
}


def installReqsIfNeeded(TestParams params, def platform) {

    if (params.INSTALL_REQS){
        installReqs(platform,params.NOSE_GIT)
    }
}


def doTests(node_list, platform, pyversion, LCB_VERSION, PYCBC_DEBUG_SYMBOLS, SERVER_VERSION, TestParams testParams)
{
    PARSE_SUPPRESSIONS=false
    timestamps {
        // TODO: IF YOU HAVE INTEGRATION TESTS THAT RUN AGAINST THE MOCK DO THAT HERE
        // USING THE PACKAGE(S) CREATED ABOVE
        def (GString test_rel_path, GString nosetests_args, GString test_full_path) = getNoseArgs(SERVER_VERSION ?: "Mock", platform, pyversion, testParams)
        try {
            mkdir(test_full_path,platform)
            if (isWindows(platform)) {
                dir("${WORKSPACE}\\couchbase-python-client") {
                    dir("${test_rel_path}"){}
                    batWithEcho("md ${test_rel_path}")
                    batWithEcho('''
                        echo try: > "updateTests.py"
                        echo     from configparser import ConfigParser >> "updateTests.py"
                        echo except: >> "updateTests.py"
                        echo     from ConfigParser import ConfigParser >> "updateTests.py"
                        echo import os >> "updateTests.py"
                        echo fp = open("tests.ini.sample", "r") >> "updateTests.py"
                        echo template = ConfigParser() >> "updateTests.py"
                        echo template.readfp(fp) >> "updateTests.py"
                        echo template.set("realserver", "enabled", "False") >> "updateTests.py"
                        echo if os.path.exists("tests.ini"): >> "updateTests.py"
                        echo     raise Exception("tests.ini already exists") >> "updateTests.py"
                        echo with open("tests.ini", "w") as fp: >> "updateTests.py"
                        echo     template.write(fp) >> "updateTests.py"
                    ''')
                    batWithEcho("python updateTests.py")
                    installReqsIfNeeded(testParams,platform)
                    batWithEcho("nosetests ${nosetests_args}")
                }
            } else {
                shWithEcho("python --version")
                shWithEcho("pip --version")
                if (testParams.PYCBC_VALGRIND != "") {
                    shWithEcho("curl -LO ftp://sourceware.org/pub/valgrind/valgrind-3.13.0.tar.bz2")
                    shWithEcho("tar -xvf valgrind-3.13.0.tar.bz2")
                    shWithEcho("mkdir -p deps/valgrind")
                    dir("valgrind-3.13.0") {
                        shWithEcho("./configure --prefix=${WORKSPACE}/deps/valgrind")
                        shWithEcho("make && make install")
                    }
                }
                def first_ip=""
                def cbas_ip=""
                if (SERVER_VERSION && node_list) {
                    first_ip = node_list[0].ip
                    cbas_ip = getServiceIp(node_list, 'cbas')
                }
                else {
                    first_ip =""
                    cbas_ip =""
                }

                dir("${WORKSPACE}/couchbase-python-client") {
                    mkdir(test_full_path,platform)
                    shWithEcho("echo $PWD && mkdir -p ${test_rel_path}")
                    shWithEcho("pip install configparser")
                    shWithEcho(genTestIniModifier(SERVER_VERSION, first_ip, cbas_ip))


                    shWithEcho("python updateTests.py")
                    shWithEcho("ls -alrt")
                    shWithEcho("cat tests.ini")
                    installReqsIfNeeded(testParams, platform)
                    if (testParams.PYCBC_VALGRIND != "") {
                        shWithEcho("""
                            export VALGRIND_REPORT_DIR="build/valgrind/${testParams.PYCBC_VALGRIND}"
                            mkdir -p \$VALGRIND_REPORT_DIR
                            valgrind --suppressions=jenkins/suppressions.txt --gen-suppressions=all --track-origins=yes --leak-check=full --xml=yes --xml-file=\$VALGRIND_REPORT_DIR/valgrind.xml --show-reachable=yes `which python` `which nosetests` -v "${
                            testParams.PYCBC_VALGRIND
                        }" > build/valgrind.txt""")
                        if (PARSE_SUPPRESSIONS) {
                            shWithEcho("python jenkins/parse_suppressions.py")
                        }
                        publishValgrind(
                                failBuildOnInvalidReports: false,
                                failBuildOnMissingReports: false,
                                failThresholdDefinitelyLost: '',
                                failThresholdInvalidReadWrite: '',
                                failThresholdTotal: '',
                                pattern: '**/valgrind.xml',
                                publishResultsForAbortedBuilds: false,
                                publishResultsForFailedBuilds: false,
                                sourceSubstitutionPaths: '',
                                unstableThresholdDefinitelyLost: '',
                                unstableThresholdInvalidReadWrite: '',
                                unstableThresholdTotal: ''
                        )
                    }
                    shWithEcho("echo $PWD && ls -alrt")

                    if (platform.toLowerCase().contains("centos") || PYCBC_DEBUG_SYMBOLS == "") {
                        shWithEcho("which nosetests")
                        shWithEcho("nosetests ${nosetests_args}")
                    } else {
                        def TMPCMDS = "${pyversion}_${LCB_VERSION}_cmds"
                        def batchFile = ""
                        def invoke = ""
                        if (platform.contains("macos")) {
                            batchFile = """
echo "run `which nosetests` ${nosetests_args}" >> "${TMPCMDS}"
echo "bt" >>"${TMPCMDS}"
echo "py-bt" >>"${TMPCMDS}"
echo "quit" >>"${TMPCMDS}"
"""
                            invoke = "lldb --batch -K ${TMPCMDS} -o run -f `which python` -- `which nosetests` ${nosetests_args}"
                        } else {
                            batchFile = """
echo "break abort" > "${TMPCMDS}"
echo "handle all stop" > "${TMPCMDS}"
echo "run `which nosetests` ${nosetests_args}" >> "${TMPCMDS}"
echo "bt" >>"${TMPCMDS}"
echo "py-bt" >>"${TMPCMDS}"
echo "quit" >>"${TMPCMDS}"
"""
                            invoke = "gdb -batch -x \"${TMPCMDS}\" `which python`"
                        }
                        shWithEcho("""
                        
                        echo "trying to write to: ["
                        echo "${TMPCMDS}"
                        echo "]"
                        ${batchFile}
                        ${invoke}""")
                    }
                    shWithEcho("echo $PWD && ls -alrt")
                }
            }
        } catch (Exception e) {
            echo "Caught an error in doTests: ${e}"
            throw e
        } finally {
            junit "couchbase-python-client/**/nosetests.xml"
            if (isWindows(platform)){
                batWithEcho("rmdir /Q /S ${test_full_path}")
            }
            else{
                shWithEcho("rm -rf ${test_full_path}")
            }
        }
    }
}

def genTestIniModifier(SERVER_VERSION, first_ip = "", cbas_ip = "") {
    return """
                        cat > updateTests.py <<EOF
try:
    from configparser import ConfigParser
except:
    from ConfigParser import ConfigParser

import os
fp = open("tests.ini.sample", "r")
template = ConfigParser()
template.readfp(fp)
is_realserver="${SERVER_VERSION}"!="null"
template.set("realserver", "enabled", str(is_realserver))
template.set("mock", "enabled", str(not is_realserver))
if "${first_ip}":
    template.set("realserver", "host", "${first_ip}")
template.set("realserver", "admin_username", "Administrator")
template.set("realserver", "admin_password", "password")
template.set("realserver", "bucket_password", "password")
try:
    template.add_section("analytics")
except e:
    print("got exception: {}".format(e))
    pass
if "${cbas_ip}":
    template.set("analytics", "host", "${cbas_ip}")
with open("tests.ini", "w") as fp:
    template.write(fp)
    print("Wrote to file")
print("Done writing")
print("Wrote {}".format(template))
EOF
                    """
}

def kill_clusters(clusters_running) {
    for (cluster in clusters_running.split('\n')) {
        // May need to remove some if they're stuck.  -f forces, allows deleting cluster we didn't open
        if (cluster.contains("node_")) {
            continue
        }
        if (cluster.contains("qe-slave1")) {
            cluster_id_tokens = cluster.trim().split(/\s+/)
            if (cluster_id_tokens.size() > 0) {
                cluster_id = cluster_id_tokens[0]
                echo "killing cluster ${cluster_id}"

                shWithEcho("cbdyncluster rm ${cluster_id}")
            }
        }
    }
}

void testAgainstServer(serverVersion, platform, envStr, testActor) {
    script{
        // Note this must be run inside a script {} block to allow try/finally
        def clusterId = null
        try {
            /* def my_plat = null
            if (isWindows(platform))
            {
                my_plat = new Windows()
            }
            else
            {
                my_plat = new Unix()
            } */
            // For debugging, what clusters are open
            clusters_running=shWithEcho("cbdyncluster ps -a")
            echo "got clusters_running: ${clusters_running}"
            withEnv(envStr){
                if ("${KILL_CLUSTERS}"){
                    kill_clusters(clusters_running)
                }


                // Allocate the cluster.  3 KV nodes.
                def node_list = [[services:["kv","index","n1ql"]],[services:["kv,fts"]],[services:["kv,cbas"]]]
                def node_count = node_list.size()
                clusterId = sh(script: "cbdyncluster allocate --num-nodes=${node_count} --server-version=" + serverVersion, returnStdout: true)
                echo "Got cluster ID " + clusterId

                // Find the cluster IP
                def ips = sh(script: "cbdyncluster ips " + clusterId, returnStdout: true).trim()
                echo "Got raw cluster IPs " + ips
                def ip_list = ips.tokenize(',')
                def ip=ip_list[0]
                print "Got cluster IP http://" + ip + ":8091\n"
                def cmd_str = ""
                def count=0
                for (entry in node_list){
                    cmd_str+=" --node "+entry.services.join(",")
                    entry['ip']=ip_list[count]
                    count+=1
                }
                print "got node_list ${node_list}"
                print cmd_str
                // Create the cluster
                shWithEcho("cbdyncluster ${cmd_str} --storage-mode plasma --bucket default setup " + clusterId)
                // Make the bucket flushable
                shWithEcho("curl -v -X POST -u Administrator:password -d flushEnabled=1 http://" + ip + ":8091/pools/default/buckets/default")
                shWithEcho("""curl -v -X POST -u Administrator:password -d '["beer-sample"]' http://${ip}:8091/sampleBuckets/install""")
                sleep(30)
                shWithEcho("""curl -X PUT --data "name=default&roles=admin&password=password" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                http://Administrator:password@${ip}:8091/settings/rbac/users/local/default
                """)
                shWithEcho("curl -X GET http://Administrator:password@${ip}:8091/settings/rbac/users")
                shWithEcho("curl http://Administrator:password@${ip}:8091/pools/default/buckets/default")

                testActor.call(node_list)
            }
        }
        catch (e)
        {
            echo "Caught an error: ${e}"
        }
        finally {
            if (clusterId != null) {
                // Easy to run out of resources during iterating, so cleanup even
                // though cluster will be auto-removed after a time
                shWithEcho("cbdyncluster rm " + clusterId)
            }
        }
    }
}


def getCMakeTarget(platform, arch)
{
    def win_arch=[x86:[],x64:['Win64']][arch]
    cmake_arch=(['Visual Studio 14 2015']+win_arch).join(' ')
    return cmake_arch
}

def buildLibCouchbase(platform, arch)
{
    dir("${WORKSPACE}")
    {
        cmdWithEcho(platform,"git clone http://review.couchbase.org/libcouchbase $LCB_PATH",false)
        cmake_arch = getCMakeTarget(platform, arch)
        if (isWindows(platform))
        {
            dir("libcouchbase") {
                batWithEcho("git checkout ${LCB_VERSION}")
            }
            
            dir("build") {
                if (IS_RELEASE == "true") {
                    batWithEcho("""
                        cmake -G "${cmake_arch}" -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ..\\libcouchbase
                        cmake --build .
                    """)
                } else {
                    // TODO: I'VE TIED THIS TO VS 14 2015, IS THAT CORRECT?
                    batWithEcho("""
                        cmake -G "${cmake_arch}" -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ..\\libcouchbase
                        cmake --build .
                    """)
                }
                batWithEcho("""
                    cmake --build . --target alltests
                    ctest -C debug
                """)
                batWithEcho("cmake --build . --target package")
            }
        }
        else
        {
            dir("libcouchbase") {
                shWithEcho("git checkout ${LCB_VERSION}")
                dir("build") {
                    if (IS_RELEASE == "true") {
                        shWithEcho("cmake ../")
                    } else {
                        shWithEcho("cmake ../ -DCMAKE_BUILD_TYPE=DEBUG")
                    }
                    shWithEcho("make")
                }
            }
        }
    }    
}

def installPythonClient(platform, build_ext_args, PIP_INSTALL) {
    def installCmd=""
    cmdWithEcho(platform, """
                            pip install restructuredtext-lint
                            restructuredtext-lint README.md"""
    )
    if (PIP_INSTALL.toUpperCase() == "TRUE") {
        //cmdWithEcho(platform, "pip install --upgrade pip")
        installCmd="pip install -e . -v -v -v"
    } else {
        //build_ext_args=((build_ext_args!=null)?build_ext_args:"")+" --inplace --debug"
        installCmd="python setup.py build_ext ${build_ext_args} install"
    }
    cmdWithEcho(platform, installCmd)
}


def doIntegration(String platform, String pyversion, String pyshort, String arch, LCB_VERSION, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, SERVER_VERSIONS, String WORKSPACE, String[] PYCBC_LCB_APIS, String NOSE_GIT, String PIP_INSTALL, String PYCBC_VERSION)
{
    cleanWs()
    unstash "couchbase-python-client"
    unstash "dist-${platform}-${pyversion}-${arch}"
    //unstash "lcb-${platform}-${pyversion}-${arch}"
    installPython("${platform}", "${pyversion}", "${pyshort}", "deps", "${arch}", PYCBC_DEBUG_SYMBOLS?true:false)
    envStr=getEnvStr(platform,pyversion,arch,"5.5.0", PYCBC_VALGRIND)
    withEnv(envStr)
    {
        installReqs(platform, NOSE_GIT)
    }
    for (server_version in SERVER_VERSIONS)
    {
        envStr=getEnvStr(platform,pyversion,arch,server_version,PYCBC_VALGRIND)
        for (PYCBC_LCB_API in PYCBC_LCB_APIS) {
            withEnv(envStr)
            {
                BuildParams buildParams= new BuildParams(PYCBC_LCB_API)

                TestParams testParams=new TestParams(buildParams, false, NOSE_GIT, PYCBC_VALGRIND)
                testAgainstServer(server_version, platform, envStr, { ip -> doTests(ip, platform, pyversion, LCB_VERSION, PYCBC_DEBUG_SYMBOLS, server_version, testParams) })
            }
        }
    }
}

def getSep(platform){
    def sep = "/"
    if (isWindows(platform)){
        sep = "\\"
    }
    return sep
}

def getAttribs() {
    // TODO: fix
    //def COMMIT_MSG_JSON = COMMIT_MSG.split("\n").findAll { it.contains('{') }
    COMMIT_MSG_ATTRIBS=[:]
    //def COMMIT_MSG_ATTRIBS = COMMIT_MSG_JSON.empty ? [:] : readJSON(COMMIT_MSG_JSON[0])
    if (COMMIT_MSG.contains('PYCBC_BYPASS_V3_FAILURES')){
        COMMIT_MSG_ATTRIBS['PYCBC_BYPASS_V3_FAILURES']="TRUE"
    }
    return COMMIT_MSG_ATTRIBS
}

def getStageName( platform,  pyversion,  arch, PYCBC_LCB_API="DFLT_LCB", SERVER_VERSION="MOCK") {

    return "${platform}_${pyversion}_${arch}_${PYCBC_LCB_API}_${SERVER_VERSION}"
}


def doBuild(stage_name, String platform, String pyversion, pyshort, String arch, PYCBC_DEBUG_SYMBOLS, BUILD_LCB, win_arch, IS_RELEASE, build_ext_args, dist_dir, dist_dir_rel) {
    timestamps {
        cleanWs()
        unstash 'couchbase-python-client'
        if ("${PYCBC_VERSION}".length()>0)
        {
            tag_version("${PYCBC_VERSION}",platform)
        }
        dir("couchbase-python-client") {
            cmdWithEcho(platform, "")
        }
            // TODO: CHECK THIS ALL LOOKS GOOD
        if (isWindows(platform)) {
            batWithEcho("SET")
            dir("deps") {
                installPython("windows", "${pyversion}", "${pyshort}", "python", "${arch}", PYCBC_DEBUG_SYMBOLS ? true : false)
            }

            batWithEcho("python --version")
            batWithEcho("pip --version")
            if (BUILD_LCB) {
                batWithEcho("git clone http://review.couchbase.org/p/libcouchbase ${WORKSPACE}\\libcouchbase")
                dir("libcouchbase") {
                    batWithEcho("git checkout ${LCB_VERSION}")
                }
                cmake_arch = (['Visual Studio 14 2015'] + win_arch).join(' ')

                dir("build") {
                    if (IS_RELEASE == "true") {
                        batWithEcho("""
                                                            cmake -G "${cmake_arch}" -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ..\\libcouchbase
                                                            cmake --build .
                                                        """)
                    } else {
                        // TODO: I'VE TIED THIS TO VS 14 2015, IS THAT CORRECT?
                        batWithEcho("""
                                                            cmake -G "${cmake_arch}" -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ..\\libcouchbase
                                                            cmake --build .
                                                        """)
                    }
                    batWithEcho("""
                                                        cmake --build . --target alltests
                                                        ctest -C debug
                                                    """)
                    batWithEcho("cmake --build . --target package")
                }
            }
            dir("couchbase-python-client") {
                if (BUILD_LCB) {
                    batWithEcho("copy ${WORKSPACE}\\build\\bin\\RelWithDebInfo\\libcouchbase.dll couchbase\\libcouchbase.dll")
                    build_ext_args+= getBuildExtArgs(platform, "${WORKSPACE}")
                }

                withEnv(["CPATH=${LCB_INC}", "LIBRARY_PATH=${LCB_LIB}"]) {
                    installPythonClient(platform, build_ext_args, "${PIP_INSTALL}")
                    batWithEcho("pip install wheel")
                }
                batWithEcho("python setup.py bdist_wheel --dist-dir ${dist_dir}")
                batWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
            }
            archiveArtifacts artifacts: "${dist_dir_rel}/*", fingerprint: true, onlyIfSuccessful: false
        } else {
            shWithEcho('env')
            installPython("${platform}", "${pyversion}", "${pyshort}", "deps", "x64", PYCBC_DEBUG_SYMBOLS ? true : false)

            shWithEcho("python --version")
            shWithEcho("pip --version")
            if (BUILD_LCB) {

                shWithEcho("git clone http://review.couchbase.org/libcouchbase $LCB_PATH")
                dir("libcouchbase") {
                    shWithEcho("git checkout ${LCB_VERSION}")
                    dir("build") {
                        if (IS_RELEASE == "true") {
                            shWithEcho("cmake ../")
                        } else {
                            shWithEcho("cmake ../ -DCMAKE_BUILD_TYPE=DEBUG")
                        }
                        shWithEcho("make")
                    }
                }
                build_ext_args+=getBuildExtArgs(platform, "${WORKSPACE}")
            }
            dir("couchbase-python-client") {
                shWithEcho("pip install cython")
                installPythonClient(platform, build_ext_args, "${PIP_INSTALL}")
                withEnv(["CPATH=${LCB_INC}", "LIBRARY_PATH=${LCB_LIB}"]) {
                    installReqs(platform,null)
                    try {
                        shWithEcho("python setup.py build_sphinx")
                    }
                    catch(e)
                    {
                        echo("Got exception ${e} while trying to build docs")
                    }
                    shWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                }
            }
        }
        dir("couchbase-python-client") {
            cmdWithEcho(platform, """
pip install twine
twine check dist/*
""")
        }

        archiveArtifacts artifacts: "couchbase-python-client/build/sphinx/**/*", fingerprint: true, onlyIfSuccessful: false
        stash includes: 'dist/', name: "dist-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
        //stash includes: 'libcouchbase/', name: "lcb-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
        stash includes: 'couchbase-python-client/', name: "couchbase-python-client-build-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
    }

}

def getBuildExtArgs(PLATFORM, WORKSPACE) {
    if (isWindows(PLATFORM)){
        return "--library-dirs ${WORKSPACE}\\build\\lib\\RelWithDebInfo --include-dirs ${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\build\\generated"
    }
    else
    {
        return "--library-dirs ${LCB_LIB} --include-dirs ${LCB_INC}"
    }

}


def buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, IS_RELEASE, WIN_PY_DEFAULT_VERSION, PYCBC_LCB_APIS, NOSE_GIT) {
    def SERVER_VERSION="MOCK"
    def pairs = [:]
    
    def combis = [:]
    def hasWindows = false
    def hasWinDefaultPlat = false
    for (j in PLATFORMS) {
        hasWindows|=j.startsWith("windows")
        for (k in PY_VERSIONS) {
            hasWinDefaultPlat|=k.startsWith("${WIN_PY_DEFAULT_VERSION}")
            for (l in PY_ARCHES)
            {
                combis=addCombi(combis,j,k,l)
            }          
        }
    }
    echo "Got combis ${combis}, PYCBC_LCB_APIS = < ${PYCBC_LCB_APIS} >"
    for (j in PLATFORMS) {
        for (k in PY_VERSIONS) {
            for (l in PY_ARCHES) {
                for (PYCBC_LCB_API in PYCBC_LCB_APIS) {
                    String platform = j
                    String pyversion = k
                    String arch = l
                    def try_invalid_combo = "${COMMIT_MSG}".contains("PYCBC_TRY_INVALID_COMBO")
                    if (isWindows(platform) && (pyversion<("3.0")) && !try_invalid_combo) {
                        continue
                    }

                    if (!isWindows(platform) && arch == "x86") {
                        continue
                    }
                    def label = platform
                    if (platform == "windows") {
                        if (pyversion >= "3.5") {
                            label = "msvc-2015"
                        } else if (pyversion >= "3.3") {
                            label = "msvc-2010"
                        } else {
                            label = "msvc-2015"
                        }
                    }
                    def stage_name=getStageName(platform, pyversion, arch, PYCBC_LCB_API, SERVER_VERSION)
                    echo "got ${platform} ${pyversion} ${arch} PYCBC_LCB_API=< ${PYCBC_LCB_API} >: launching with label ${label}"

                    pairs[stage_name] = {
                        node(label) {
                            BuildParams buildParams = new BuildParams(PYCBC_LCB_API)
                            TestParams testParams = new TestParams(buildParams, true, NOSE_GIT, PYCBC_VALGRIND)

                            def pyshort = pyversion.tokenize(".")[0] + "." + pyversion.tokenize(".")[1]
                            def win_arch = [x86: [], x64: ['Win64']][arch]
                            def plat_build_dir_rel = "build_${platform}_${pyversion}_${arch}"
                            def sep = getSep(platform)
                            def libcouchbase_build_dir_rel = "${plat_build_dir_rel}${sep}libcouchbase"
                            def dist_dir_rel = "dist"
                            def dist_dir = "${WORKSPACE}${sep}${dist_dir_rel}"
                            def envStr = getEnvStr2(platform, pyversion, arch,"MOCK", PYCBC_LCB_API, PYCBC_VALGRIND)
                            def build_ext_args = "--inplace " + ((PYCBC_DEBUG_SYMBOLS&&!isWindows(platform))?"--debug ":"")
                            withEnv(envStr) {
                                Exception exception_received=null;
                                try {
                                    stage("build ${stage_name}") {
                                        def BUILD_LCB = (PYCBC_LCB_API==null || PYCBC_LCB_API=="default")
                                        doBuild(stage_name, platform, pyversion, pyshort, arch, PYCBC_DEBUG_SYMBOLS, BUILD_LCB, win_arch, IS_RELEASE, build_ext_args, dist_dir, dist_dir_rel)
                                    }
                                    stage("test ${stage_name}") {
                                        doTestsMock(platform, PYCBC_DEBUG_SYMBOLS, pyversion, testParams)
                                    }
                                }
                                catch(Exception e){
                                    exception_received=e
                                    if(!try_invalid_combo)
                                    {
                                        throw e
                                    }
                                }
                                if (try_invalid_combo)
                                {
                                    if (!exception_received){
                                        throw new RuntimeException("Invalid combo unexpectedly succeeded")
                                    }
                                    else
                                    {
                                        echo("Got exception as expected: ${exception_received}")
                                    }

                                }
                            }

                        }
                    }
                }
            }
        }
    }
    parallel pairs
}


def doTestsMock(platform, PYCBC_DEBUG_SYMBOLS, pyversion, TestParams testParams) {

    doTests(null, platform, pyversion, LCB_VERSION, PYCBC_DEBUG_SYMBOLS, null, testParams)
}
