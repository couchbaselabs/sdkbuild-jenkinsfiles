def PLATFORMS = [ "centos7", "windows-2012" ]
//def PLATFORMS = [ "windows-2012" ]
def DEFAULT_PLATFORM = PLATFORMS[0]
def PY_VERSIONS = [ "2.7.15", "3.7.0" ] // 3.7.0 is failing tests
//def PY_ARCHES = [ "x64" ] //, "x86" ]
def PY_ARCHES = [ "x64" , "x86" ]
def DEFAULT_PY_VERSION = PY_ARCHES[0]
def DEFAULT_VERSION_SHORT=DEFAULT_PY_VERSION.tokenize(".")[0] + "." + DEFAULT_PY_VERSION.tokenize(".")[1]
def DEFAULT_PY_ARCH = PY_ARCHES[0]

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
                buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, "${PYCBC_VALGRIND}", "${PYCBC_DEBUG_SYMBOLS}", "${IS_RELEASE}")
            }
        }
        stage('package') {
            agent { label "${DEFAULT_PLATFORM}" }
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
                PATH="${WORKSPACE}/deps/python${DEFAULT_VERSION}:${WORKSPACE}/deps/python${DEFAULT_VERSION}/bin:$PATH"
            }
            steps {
                cleanWs()
                unstash "lcb-" + DEFAULT_PLATFORM + "-" + DEFAULT_PY_VERSION + "-" + DEFAULT_PY_ARCH
                unstash "couchbase-python-client-build-" + DEFAULT_PLATFORM + "-" + DEFAULT_PY_VERSION + "-" + DEFAULT_PY_ARCH
                installPython("${DEFAULT_PLATFORM}", "${DEFAULT_PY_VERSION}", "${DEFAULT_VERSION_SHORT}", "${DEFAULT_PY_ARCH}", "deps", true)

                shPython("pip install --verbose Twisted gevent")
                unstash "dist-" + DEFAULT_PLATFORM + "-" + DEFAULT_PY_VERSION + "-" + DEFAULT_PY_ARCH
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
    shWithEcho(cmd)
}

void installPythonDows(String platform, String version, String pyshort, String path, String arch) {
    def cmd = "cbdep install python ${version} -d ${path}"
    if (arch == "x86") {
        cmd = cmd + " --x32"
    }
    batWithEcho(cmd)
}

void shWithEcho(String command) {
    echo "[$STAGE_NAME]"+ sh (script: command, returnStdout: true)
}

void batWithEcho(String command) {
    echo "[$STAGE_NAME]"+ bat (script: command, returnStdout: true)
}

def buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, IS_RELEASE) {
    def pairs = [:]
    for (j in PLATFORMS) {
        for (k in PY_VERSIONS) {
            for (l in PY_ARCHES) {
                def platform = j
                def pyversion = k
                def arch = l

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
                        def win_arch=[x86:'Win32',x64:'Win64'][arch]
                        def plat_build_dir="${WORKSPACE}/build_${platform}_${pyversion}_${arch}"
                        def libcouchbase_build_dir="${plat_build_dir}/libcouchbase"
                        def dist_dir="${plat_build_dir}/dist"
                        def libcouchbase_checkout="${WORKSPACE}/libcouchbase"

                        if (platform.contains("windows")) {
                            envStr = ["win_arch=${win_arch}","PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH", "LCB_PATH=${libcouchbase_checkout}", "LCB_BUILD=${libcouchbase_build_dir}", "LCB_LIB=${libcouchbase_build_dir}/lib", "LCB_INC=${libcouchbase_checkout}/include;${libcouchbase_build_dir}/generated","dist_dir=${dist_dir}"]
                        } else {
                            envStr = ["PYCBC_VALGRIND=${PYCBC_VALGRIND}","PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "libcouchbase_build_dir=${libcouchbase_build_dir}","LCB_PATH=${libcouchbase_checkout}", "LCB_BUILD=${libcouchbase_build_dir}", "LCB_LIB=${libcouchbase_build_dir}/lib", "LCB_INC=${libcouchbase_checkout}/include:${libcouchbase_build_dir}/generated", "dist_dir=${dist_dir}","LD_LIBRARY_PATH=${libcouchbase_build_dir}/lib:\$LD_LIBRARY_PATH"]
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
                                            installPythonDows("windows", "${pyversion}", "${pyshort}", "python", "${arch}")
                                        }

                                        batWithEcho("python --version")
                                        batWithEcho("pip --version")

                                        batWithEcho("git clone http://review.couchbase.org/p/libcouchbase ${LCB_PATH}")
                                        dir("${LCB_PATH}") {
                                            batWithEcho("git checkout ${LCB_VERSION}")
                                        }
                                        
                                        dir("${libcouchbase_build_dir}") {
                                            if (IS_RELEASE == "true") {
                                                batWithEcho("""
                                                    cmake -G "Visual Studio 14 2015" -A ${win_arch} -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ${LCB_PATH}
                                                    cmake --build .
                                                """)
                                            } else {
                                                // TODO: I'VE TIED THIS TO VS 14 2015, IS THAT CORRECT?
                                                batWithEcho("""
                                                    cmake -G "Visual Studio 14 2015" -A ${win_arch} -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ${LCB_PATH}
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
                                            batWithEcho("copy ${libcouchbase_build_dir}\\bin\\RelWithDebInfo\\libcouchbase.dll couchbase\\libcouchbase.dll")
                                            batWithEcho("python setup.py build_ext --inplace --library-dirs ${libcouchbase_build_dir}\\lib\\RelWithDebInfo --include-dirs ${LCB_PATH}\\include;${libcouchbase_build_dir}\\generated install")
                                            batWithEcho("pip install wheel")
                                            batWithEcho("python setup.py bdist_wheel --dist-dir ${dist_dir}")
                                            batWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                                        }
                                        //archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true, onlyIfSuccessful: false
                                        //archiveArtifacts artifacts: '${WORKSPACE}\\dist', fingerprint: true, onlyIfSuccessful: false
                                    } else {
                                        shWithEcho('env')
                                        installPython("${platform}", "${pyversion}", "${pyshort}", "deps", "x64")

                                        shWithEcho("python --version")
                                        shWithEcho("pip --version")

                                        shWithEcho("git clone http://review.couchbase.org/libcouchbase $LCB_PATH")
                                        dir("${LCB_PATH}"){
                                            shWithEcho("git checkout ${LCB_VERSION}")
                                        }
                                        dir("${libcouchbase_build_dir}") {
                                            if (IS_RELEASE == "true") {
                                                shWithEcho("cmake ${LCB_PATH}")
                                            } else {
                                                shWithEcho("cmake ${LCB_PATH} -DCMAKE_BUILD_TYPE=DEBUG")
                                            }
                                            shWithEcho("make")
                                        }

                                        dir("couchbase-python-client") {
                                            shWithEcho("pip install cython")
                                            shWithEcho("python setup.py build_ext --inplace --library-dirs ${LCB_LIB} --include-dirs ${LCB_INC}")
                                            shWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                                        }
                                    }
                                    dir("${dist_dir"})
                                    {
                                    shWithEcho("""echo stashing dist  ${dist_dir}
                                    ls -al .""")
                                        stash includes: '.', name: "dist-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    }
                                    shWithEcho("""echo stashing libcouchbase ${libcouchbase_build_dir}
                                    ls -al ${libcouchbase_build_dir}""")
                                    stash includes: '${libcouchbase_build_dir}/', name: "lcb-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    shWithEcho("""echo stashing couchbase-python-client
                                    ls -al couchbase-python-client""")
                                    stash includes: 'couchbase-python-client/', name: "couchbase-python-client-build-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                }
                            }
                            stage("test ${platform}_${pyversion}_${arch}") {
                                timestamps {
                                    unstash "couchbase-python-client-build-${platform}-${pyversion}-${arch}"
                                    unstash "dist-${platform}-${pyversion}-${arch}"
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

    parallel pairs
}