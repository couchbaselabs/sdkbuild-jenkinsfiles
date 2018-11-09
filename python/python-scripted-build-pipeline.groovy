def PLATFORMS = [ "centos7", "windows-2012" ]
def DEFAULT_PLATFORM = PLATFORMS[0]
def PY_VERSIONS = [ "2.7.15", "3.7.0" ] // 3.7.0 is failing tests
def PY_ARCHES = [ "x64", "x86" ]
def DEFAULT_PY_VERSION = PY_ARCHES[0]
def DEFAULT_VERSION_SHORT=DEFAULT_PY_VERSION.tokenize(".")[0] + "." + DEFAULT_PY_VERSION.tokenize(".")[1]
def DEFAULT_PY_ARCH = PY_ARCHES[0]

pipeline {
    agent none
    stages {
        stage("job valid?") {
            when {
                expression {
                    return _INTERNAL_OK_.toBoolean() != true
                }
            }
            steps {
                error("Exiting early as not valid run")
            }
        }
        stage("prepare and validate") {
            agent { label "${DEFAULT_PLATFORM}" }
            steps {
                cleanWs()
                shWithEcho("env")

                dir("couchbase-python-client") {
                    checkout([$class: "GitSCM", branches: [[name: "$SHA"]], userRemoteConfigs: [[refspec: "$GERRIT_REFSPEC", url: "$REPO", poll: false]]])
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
                
                stash includes: "couchbase-python-client/", name: "couchbase-python-client", useDefaultExcludes: false
            }
        }
        stage("build") {
            agent { label "master" }
            steps {
                buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, "${PYCBC_VALGRIND}", "${PYCBC_DEBUG_SYMBOLS}", "${IS_RELEASE}")
            }
        }
        stage("package") {
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
                stash includes: "couchbase-python-client/", name: "couchbase-python-client-package", useDefaultExcludes: false
            }
            post {
                always {
                    archiveArtifacts artifacts: "couchbase-python-client/", fingerprint: true
                }
            }
        }
        stage("test-integration-server") {
            agent { label "ubuntu14||ubuntu16||centos6||centos7" }
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
        stage("quality") {
            agent { label "ubuntu14||ubuntu16||centos6||centos7" }
            when {
                expression 
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false } 
            }
            steps {
                cleanWs()
                // TODO: SITUATIONAL TESTING JOB WILL BE HOOKED HERE
            }
        }
        stage("snapshot") {
            agent { label "ubuntu14||ubuntu16||centos6||centos7" }
            when {
                expression 
                    {  return IS_RELEASE.toBoolean() == false &amp;&amp; IS_GERRIT_TRIGGER.toBoolean() == false } 
            }
            steps {
                cleanWs()
                // TODO: Upload build artefacts to snapshot server here
            }
        }
        stage("approval") {
            agent none
            when { 
                expression 
                    {  return IS_RELEASE.toBoolean() == true } 
            }
            steps {
                input "Publish?"
            }
        }
        stage("publish") {
            agent { label "ubuntu14||ubuntu16||centos6||centos7" }
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
                    archiveArtifacts artifacts: "couchbase-python-client/", fingerprint: true
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

                if (platform.contains("windows") &amp;&amp; (pyversion.contains("2.7"))) {
                    continue
                }
                
                if (!platform.contains("windows") &amp;&amp; arch == "x86") {
                    continue
                }
    
                pairs[platform + "_" + pyversion + "_" + arch]= {
                    node(platform) {
                        def envStr = []
                        def pyshort=pyversion.tokenize(".")[0] + "." + pyversion.tokenize(".")[1]
                        if (platform.contains("windows")) {
                            envStr = ["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH"]//, "LCB_PATH=${WORKSPACE}\\libcouchbase", "LCB_BUILD=${WORKSPACE}\\libcouchbase\\build", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated", "LD_LIBRARY_PATH=${WORKSPACE}\\libcouchbase\\build\\lib;\$LD_LIBRARY_PATH"]
                        } else {
                            envStr = ["PYCBC_VALGRIND=${PYCBC_VALGRIND}","PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase", "LCB_BUILD=${WORKSPACE}/libcouchbase/build", "LCB_LIB=${WORKSPACE}/libcouchbase/build/lib", "LCB_INC=${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated", "LD_LIBRARY_PATH=${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH"]
                        }
                        withEnv(envStr) {
                            stage("build ${platform}_${pyversion}_${arch}") {
                                timestamps {
                                    cleanWs()
                                    unstash "couchbase-python-client"
    
                                    // TODO: CHECK THIS ALL LOOKS GOOD
                                    if (platform.contains("windows")) {
                                        batWithEcho("SET")
                                        dir("deps") {
                                            installPythonDows("windows", "${pyversion}", "${pyshort}", "python", "${arch}")
                                        }
    
                                        batWithEcho("python --version")
                                        batWithEcho("pip --version")
                                        
                                        batWithEcho("git clone http://review.couchbase.org/p/libcouchbase ${WORKSPACE}\\libcouchbase")
                                        dir("libcouchbase") {
                                            batWithEcho("git checkout ${LCB_VERSION}")
                                        }
                                        dir("build") {
                                            if (IS_RELEASE == "true") {
                                                batWithEcho("""
                                                    cmake ..\\libcouchbase -DLCB_NO_SSL=1
                                                    cmake --build .
                                                """)
                                            } else {
                                                // TODO: I"VE TIED THIS TO VS 14 2015, IS THAT CORRECT?
                                                batWithEcho("""
                                                    cmake -G"Visual Studio 14 2015 Win64" -DLCB_NO_MOCK=1 -DLCB_NO_SSL=1 ..\\libcouchbase
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
                                            batWithEcho("python setup.py build_ext --inplace --library-dirs ${WORKSPACE}\\build\\lib --include-dirs ${WORKSPACE}\\libcouchbase\\include:${WORKSPACE}\\build\\generated")
                                            batWithEcho("python setup.py sdist --dist-dir ${WORKSPACE}\\dist")
                                        }
                                    } else {
                                        shWithEcho("env")
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
                                            shWithEcho("python setup.py sdist --dist-dir ${WORKSPACE}/dist")
                                        }
                                    }

                                    stash includes: "dist/", name: "dist-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    stash includes: "libcouchbase/", name: "lcb-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                    stash includes: "couchbase-python-client/", name: "couchbase-python-client-build-${platform}-${pyversion}-${arch}", useDefaultExcludes: false
                                }
                            }
                            stage("test ${platform}_${pyversion}_${arch}") {
                                timestamps {
                                    // TODO: IF YOU HAVE INTEGRATION TESTS THAT RUN AGAINST THE MOCK DO THAT HERE
                                    // USING THE PACKAGE(S) CREATED ABOVE
                                    try {
                                        if (platform.contains("windows")) {
                                            dir("couchbase-python-client") {
                                                batWithEcho("""
                                                    echo from ConfigParser import ConfigParser &gt; "updateTests.py"
                                                    echo import os &gt; "updateTests.py"
                                                    echo fp = open("tests.ini.sample", "r") &gt;&gt; "updateTests.py"
                                                    echo template = ConfigParser() &gt;&gt; "updateTests.py"
                                                    echo template.readfp(fp) &gt;&gt; "updateTests.py"
                                                    echo template.set("realserver", "enabled", "False") &gt;&gt; "updateTests.py"
                                                    echo if os.path.exists("tests.ini"): &gt;&gt; "updateTests.py"
                                                    echo     raise Exception("tests.ini already exists") &gt;&gt; "updateTests.py"
                                                    echo with open("tests.ini", "w") as fp: &gt;&gt; "updateTests.py"
                                                    echo     template.write(fp) &gt;&gt; "updateTests.py"
                                                """)
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
                                                shWithEcho("mkdir deps &amp;&amp; mkdir deps/valgrind")
                                                dir("valgrind-3.13.0") {
                                                    shWithEcho("./configure --prefix=${WORKSPACE}/deps/valgrind")
                                                    shWithEcho("make &amp;&amp; make install")
                                                }
                                            }
            
                                            dir("couchbase-python-client") {
                                                shWithEcho("pip install configparser")
                                                shWithEcho("""
                                                    cat &gt; updateTests.py &lt;&lt;EOF
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
                                                """)
                                                shWithEcho("python updateTests.py")
                                                shWithEcho("cat dev_requirements.txt | xargs -n 1 pip install")
                                                
                                                if (PYCBC_VALGRIND != "") {
                                                    shWithEcho("""
                                                        export VALGRIND_REPORT_DIR="build/valgrind/${PYCBC_VALGRIND}"
                                                        mkdir -p \$VALGRIND_REPORT_DIR
                                                        valgrind --suppressions=jenkins/suppressions.txt --gen-suppressions=all --track-origins=yes --leak-check=full --xml=yes --xml-file=\$VALGRIND_REPORT_DIR/valgrind.xml --show-reachable=yes `which python` `which nosetests` -v "${PYCBC_VALGRIND}" &gt; build/valgrind.txt""")
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
                                                    echo "run `which nosetests` -v --with-xunit" &gt; "\$TMPCMDS"
                                                    echo "bt" &gt;&gt;"\$TMPCMDS"
                                                    echo "py-bt" &gt;&gt;"\$TMPCMDS"
                                                    echo "quit" &gt;&gt;"\$TMPCMDS"
                                                    gdb -batch -x "\$TMPCMDS" `which python`""")
                                                }
                                            }
                                        }
                                    } catch (Exception e) {
                                        echo "Caught an error"
                                        throw e
                                    } finally {
                                        junit "couchbase-python-client/nosetests.xml"
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