/* def parseEnvList(String line){
    return String(line).split("\s*")
}

def booleanOr(String line, Boolean fallBack = False)
{
    if (!line.size()){
        return fallBack
    }
    return line.toBoolean()
} */

def PLATFORMS =  "${PLATFORMS}".split(/\s+/) ?: [ "centos7", "windows-2012" ]
def DEFAULT_PLATFORM = PLATFORMS[0]
def PY_VERSIONS = "${PY_VERSIONS}".split(/\s+/) ?: [ "2.7.15", "3.7.0" ]
def PY_ARCHES = "${PY_ARCHES}".split(/\s+/) ?: [ "x64", "x86" ]

def PACKAGE_PLATFORM = "centos7"
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
                buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, "${PYCBC_VALGRIND}", "${PYCBC_DEBUG_SYMBOLS}", "${IS_RELEASE}", "${PACKAGE_PLATFORM}", "${PACKAGE_PY_VERSION}", "${PACKAGE_PY_ARCH}", "${WIN_PY_DEFAULT_VERSION}")
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
                unstash "lcb-" + PACKAGE_PLATFORM + "-" + PACKAGE_PY_VERSION + "-" + PACKAGE_PY_ARCH
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
                    shWithEcho("cat dev_requirements.txt | xargs -n 1 pip install")
                    shWithEcho("python setup.py build_sphinx")
                    shWithEcho("mkdir dist")
                }
                shWithEcho("cp -r dist/* couchbase-python-client/dist/")
                stash includes: 'couchbase-python-client/', name: "couchbase-python-client-package", useDefaultExcludes: false
            }
            post {
                always {
                    archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true
                }
            }
        }
        stage('test-integration-server') {
            agent { label 'ubuntu14||ubuntu16||centos6||centos7' }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                cleanWs()
                // build job: "couchbase-net-client-test-integration", parameters: [
                // ]
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
                // TODO: PUBLISH!
            }
            post {
                always {
                    archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true
                }
            }
        }
    }
}

void installPython(String platform, String version, String pyshort, String path, String arch) {
    def cmd = "cbdep install python ${version} -d ${path}"
    if (arch == "x86") {
        cmd = cmd + " --x32"
    }
    if (platform.contains("windows"))
    {
        batWithEcho(cmd)
    }
    else
    {
        shWithEcho(cmd)
    }
}


void shWithEcho(String command) {
    echo "[$STAGE_NAME]:${command}:"+ sh (script: command, returnStdout: true)
}

void batWithEcho(String command) {
    echo "[$STAGE_NAME]:${command}:"+ bat (script: command, returnStdout: true)
}
String prefixWorkspace(String path){
    return "${WORKSPACE}/${path}"
}
def addCombi(combis,PLATFORM,PY_VERSION,PY_ARCH)
{
    def plat = combis.get(PLATFORM,null)
    if (!plat)
    {
        plat =[:]
    }
    def version = plat.get(PY_VERSION,null)
    if (!version)
    {
        version = [:]
    }
    arch=version.get(PY_ARCH,null)
    if (!arch)
    {
        version[PY_ARCH]=true
        plat[PY_VERSION]=version
        combis[PLATFORM]=plat
    }
    return combis
}
def buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, IS_RELEASE, PACKAGE_PLATFORM, PACKAGE_PY_VERSION, PACKAGE_PY_ARCH, WIN_PY_DEFAULT_VERSION) {
    def pairs = [:] as Map
    
    def combis = [:]
    //.withDefault { key -> [:]}
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


    def SKIP_PACKAGING = IS_GERRIT_TRIGGER.toBoolean()
    if (!SKIP_PACKAGING){
        combis=addCombi(combis,PACKAGE_PLATFORM,PACKAGE_PY_VERSION,PACKAGE_PY_ARCH)
    }
    def PLATFORM_LIST=[]
    if (hasWindows && !hasWinDefaultPlat)
    {
        for (arch in PY_ARCHES)
        {
            combis=addCombi(combis,"windows",WIN_PY_DEFAULT_VERSION,arch)
        }
    }
    echo "Got combis ${combis}"
    for (j in combis) {
        for (k in j.value) {
            for (l in k.value) {
                def platform = j.key
                def pyversion = k.key
                def arch = l.key
                echo "got ${platform} ${pyversion} ${arch}"
                if (platform.contains("windows") && (pyversion.contains("2.7"))) {
                    continue
                }

                if (!platform.contains("windows") && arch == "x86") {
                    continue
                }

                pairs[platform + "_" + pyversion + "_" + arch]= {
                    node(platform) {
                        def envStr = []
                        def pyshort=pyversion.tokenize(".")[0] + "." + pyversion.tokenize(".")[1]
                        def win_arch=[x86:[],x64:['Win64']][arch]
                        def plat_build_dir_rel="build_${platform}_${pyversion}_${arch}"
                        def plat_build_dir="${WORKSPACE}/${plat_build_dir_rel}"
                        def sep = "/"
                        if (platform.contains("windows")) {
                            sep = "\\"
                        }
                        def libcouchbase_build_dir_rel="${plat_build_dir_rel}${sep}libcouchbase"
                        def libcouchbase_build_dir="${WORKSPACE}${sep}${libcouchbase_build_dir_rel}"
                        //def dist_dir_rel="${plat_build_dir_rel}${sep}dist"
                        def dist_dir_rel="dist"
                        def dist_dir="${WORKSPACE}${sep}${dist_dir_rel}"
                        def libcouchbase_checkout="${WORKSPACE}${sep}libcouchbase"
                        if (platform.contains("windows")) { 
                            //batWithEcho("md ${dist_dir}")
                            envStr = ["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH"]//, "LCB_PATH=${WORKSPACE}\\libcouchbase", "LCB_BUILD=${WORKSPACE}\\libcouchbase\\build", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated", "LD_LIBRARY_PATH=${WORKSPACE}\\libcouchbase\\build\\lib;\$LD_LIBRARY_PATH"]
                        } else {
                            //shWithEcho("mkdir -p ${dist_dir}")
                            envStr = ["PYCBC_VALGRIND=${PYCBC_VALGRIND}","PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase", "LCB_BUILD=${WORKSPACE}/libcouchbase/build", "LCB_LIB=${WORKSPACE}/libcouchbase/build/lib", "LCB_INC=${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated", "LD_LIBRARY_PATH=${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH"]
                        }
                        withEnv(envStr) {
                            stage("build ${platform}_${pyversion}_${arch}") {
                                timestamps {
                                    cleanWs()
                                    unstash 'couchbase-python-client'

                                    // TODO: CHECK THIS ALL LOOKS GOOD
                                    if (platform.contains("windows")) {
                                        batWithEcho("SET")
                                        dir("deps") {
                                            installPython("windows", "${pyversion}", "${pyshort}", "python", "${arch}")
                                        }

                                        batWithEcho("python --version")
                                        batWithEcho("pip --version")

                                        batWithEcho("git clone http://review.couchbase.org/p/libcouchbase ${WORKSPACE}\\libcouchbase")
                                        dir("libcouchbase") {
                                            batWithEcho("git checkout ${LCB_VERSION}")
                                        }
                                        cmake_arch=(['Visual Studio 14 2015']+win_arch).join(' ')
                                        
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

                                        dir("couchbase-python-client") {
                                            batWithEcho("copy ${WORKSPACE}\\build\\bin\\RelWithDebInfo\\libcouchbase.dll couchbase\\libcouchbase.dll")
                                            batWithEcho("python setup.py build_ext --inplace --library-dirs ${WORKSPACE}\\build\\lib\\RelWithDebInfo --include-dirs ${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\build\\generated install")
                                            batWithEcho("pip install wheel")
                                            batWithEcho("python setup.py bdist_wheel")
                                            batWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                                        }
                                        //archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true, onlyIfSuccessful: false
                                        archiveArtifacts artifacts: '${dist_dir_rel}', fingerprint: true, onlyIfSuccessful: false
                                    } else {
                                        shWithEcho('env')
                                        installPython("${platform}", "${pyversion}", "${pyshort}", "deps", "x64")

                                        shWithEcho("python --version")
                                        shWithEcho("pip --version")

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

                                        dir("couchbase-python-client") {
                                            shWithEcho("pip install cython")
                                            shWithEcho("python setup.py build_ext --inplace --library-dirs ${LCB_LIB} --include-dirs ${LCB_INC}")
                                            shWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                                        }
                                    }

                                    stash includes: 'dist/', name: "dist-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    stash includes: 'libcouchbase/', name: "lcb-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    stash includes: 'couchbase-python-client/', name: "couchbase-python-client-build-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                }
                            }
                            stage("test ${platform}_${pyversion}_${arch}") {
                                timestamps {
                                    //if (!platform.contains("windows")){
                                    //    sh 'chmod -R u+w .git'
                                    //}
                                    //unstash "couchbase-python-client-build-${platform}-${pyversion}-${arch}"
                                    //unstash "dist-${platform}-${pyversion}-${arch}"
                                    //unstash "lcb-${platform}-${pyversion}-${arch}"
                                    // TODO: IF YOU HAVE INTEGRATION TESTS THAT RUN AGAINST THE MOCK DO THAT HERE
                                    // USING THE PACKAGE(S) CREATED ABOVE
                                    try {
                                        if (platform.contains("windows")) {
                                            dir("couchbase-python-client") {
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
                                                batWithEcho("pip install -r dev_requirements.txt")
                                                batWithEcho("nosetests --with-xunit -v")
                                            }
                                        } else {
                                            shWithEcho("python --version")
                                            shWithEcho("pip --version")
                                            if (PYCBC_VALGRIND != "") {
                                                shWithEcho("curl -LO ftp://sourceware.org/pub/valgrind/valgrind-3.13.0.tar.bz2")
                                                shWithEcho("tar -xvf valgrind-3.13.0.tar.bz2")
                                                shWithEcho("mkdir deps && mkdir deps/valgrind")
                                                dir("valgrind-3.13.0") {
                                                    shWithEcho("./configure --prefix=${WORKSPACE}/deps/valgrind")
                                                    shWithEcho("make && make install")
                                                }
                                            }

                                            dir("couchbase-python-client") {
                                                shWithEcho("pip install configparser")
                                                shWithEcho('''
                                                    cat > updateTests.py <<EOF
try:
    from configparser import ConfigParser
except:
    from ConfigParser import ConfigParser

import os
fp = open("tests.ini.sample", "r")
template = ConfigParser()
template.readfp(fp)
template.set("realserver", "enabled", "False")
if os.path.exists("tests.ini"):
    raise Exception("tests.ini already exists")
with open("tests.ini", "w") as fp:
    template.write(fp)
EOF
                                                ''')
                                                shWithEcho("python updateTests.py")
                                                shWithEcho("cat dev_requirements.txt | xargs -n 1 pip install")

                                                if (PYCBC_VALGRIND != "") {
                                                    shWithEcho("""
                                                        export VALGRIND_REPORT_DIR="build/valgrind/${PYCBC_VALGRIND}"
                                                        mkdir -p \$VALGRIND_REPORT_DIR
                                                        valgrind --suppressions=jenkins/suppressions.txt --gen-suppressions=all --track-origins=yes --leak-check=full --xml=yes --xml-file=\$VALGRIND_REPORT_DIR/valgrind.xml --show-reachable=yes `which python` `which nosetests` -v "${PYCBC_VALGRIND}" > build/valgrind.txt""")
                                                        //shWithEcho("python jenkins/parse_suppressions.py") VERY SLOW
                                                        // TODO: NEED PUBLISH VALGRIND
                                                }

                                                if (PYCBC_DEBUG_SYMBOLS == "") {
                                                    shWithEcho("which nosetests")
                                                    shWithEcho("nosetests --with-xunit -v")
                                                } else {
                                                    shWithEcho("""
                                                    export TMPCMDS="${pyversion}_${LCB_VERSION}_cmds"
                                                    echo "trying to write to: ["
                                                    echo "\$TMPCMDS"
                                                    echo "]"
                                                    echo "run `which nosetests` -v --with-xunit" > "\$TMPCMDS"
                                                    echo "bt" >>"\$TMPCMDS"
                                                    echo "py-bt" >>"\$TMPCMDS"
                                                    echo "quit" >>"\$TMPCMDS"
                                                    gdb -batch -x "\$TMPCMDS" `which python`""")
                                                }
                                            }
                                        }
                                    } catch (Exception e) {
                                        echo "Caught an error"
                                        throw e
                                    } finally {
                                        junit 'couchbase-python-client/nosetests.xml'
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (PARALLEL_PAIRS)
    {
        parallel pairs
    }
}
