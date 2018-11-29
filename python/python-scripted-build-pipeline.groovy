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
def SERVER_VERSIONS = "${SERVER_VERSIONS}".split(/\s+/) ?: [ "5.5.0", "6.0.0"] 
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
                    installReqs(PACKAGE_PLATFORM)
                    shWithEcho("python setup.py build_sphinx")
                    shWithEcho("mkdir dist")
                }
                shWithEcho("cp -r dist/* couchbase-python-client/dist/")
                stash includes: 'couchbase-python-client/', name: "couchbase-python-client-package", useDefaultExcludes: false
            }
            /* post {
                always {
                    archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true
                }
            } */
        }
        stage('test-integration-server') {
            agent { label 'qe-slave-linux1' }
            when {
                expression
                    {  return IS_GERRIT_TRIGGER.toBoolean() == false }
            }
            steps {
                doIntegration("${PACKAGE_PLATFORM}","${PACKAGE_PY_VERSION}", "${PACKAGE_PY_VERSION_SHORT}", "${PACKAGE_PY_ARCH}","${LCB_VERSION}", "${PYCBC_VALGRIND}","${PYCBC_DEBUG_SYMBOLS}",SERVER_VERSIONS)
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
/*             post {
                always {
                    archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true
                }
            } */
        }
    }
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

void installPython(String platform, String version, String pyshort, String path, String arch) {
    def cmd = "cbdep install python ${version} -d ${path}"
    if (arch == "x86") {
        cmd = cmd + " --x32"
    }
    def plat_class = null
    if (platform.contains("windows"))
    {
        //plat_class = Windows()
        batWithEcho(cmd)
    }
    else
    {
        //plat_class = Unix()
        shWithEcho(cmd)
    }
    //plat_class.shell(cmd)
}
​
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

def cmdWithEcho(platform, command, quiet)
{
    try{
        if (platform.contains("windows")){
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
    
    return platform.toLowerCase.contains("windows")
}
def installReqs(platform)
{
    dir("${WORKSPACE}/couchbase-python-client")
    {
        if (isWindows(platform)){
            batWithEcho("pip install -r dev_requirements.txt")
        }
        else
        {
            shWithEcho("cat dev_requirements.txt | xargs -n 1 pip install")
        }
    }
}

String prefixWorkspace(String path){
    return "${WORKSPACE}/${path}"
}
def addCombi(combis,PLATFORM,PY_VERSION,PY_ARCH)
{

    if (PLATFORM.contains("windows") && (PY_VERSION.contains("2.7"))) {
        return combis
    }

    if (!PLATFORM.contains("windows") && PY_ARCH == "x86") {
        return combis
    }

    echo "adding ${PLATFORM}/${PY_VERSION}/${PY_ARCH} to ${combis}"
    def plat = combis.get("${PLATFORM}",null)
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
        combis.put("${PLATFORM}",plat)
    }
    echo "added, got ${combis}"
    return combis
}

def getEnvStr( platform,  pyversion,  arch,  server_version, PYCBC_VALGRIND)
{
    PYCBC_DEBUG_LOG = "${PYCBC_DEBUG_LOG}" ?: ""
    LCB_LOGLEVEL = "${LCB_LOGLEVEL}" ?: ""
    
    common_vars=["LCB_LOGLEVEL=${LCB_LOGLEVEL}","PYCBC_DEBUG_LOG=${PYCBC_DEBUG_LOG}"]
    if (platform.contains("windows")) { 
        //batWithEcho("md ${dist_dir}")
        envStr = ["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH", "CB_SERVER_VERSION=${server_version}"]//, "LCB_PATH=${WORKSPACE}\\libcouchbase", "LCB_BUILD=${WORKSPACE}\\libcouchbase\\build", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated", "LD_LIBRARY_PATH=${WORKSPACE}\\libcouchbase\\build\\lib;\$LD_LIBRARY_PATH"]
    } else {
        //shWithEcho("mkdir -p ${dist_dir}")
        envStr = ["PYCBC_VALGRIND=${PYCBC_VALGRIND}","PATH=${WORKSPACE}/deps/python${pyversion}-amd64:${WORKSPACE}/deps/python${pyversion}-amd64/bin:${WORKSPACE}/deps/python${pyversion}:${WORKSPACE}/deps/python${pyversion}/bin:${WORKSPACE}/deps/valgrind/bin/:$PATH", "LCB_PATH=${WORKSPACE}/libcouchbase", "LCB_BUILD=${WORKSPACE}/libcouchbase/build", "LCB_LIB=${WORKSPACE}/libcouchbase/build/lib", "LCB_INC=${WORKSPACE}/libcouchbase/include:${WORKSPACE}/libcouchbase/build/generated", "LD_LIBRARY_PATH=${WORKSPACE}/libcouchbase/build/lib:\$LD_LIBRARY_PATH", "CB_SERVER_VERSION=${server_version}"]
    }
    return envStr+common_vars
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
def doTests(node_list, platform, pyversion, LCB_VERSION, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, SERVER_VERSION)
{
    timestamps {
        //if (!platform.contains("windows")){
        //    sh 'chmod -R u+w .git'
        //}
        // TODO: IF YOU HAVE INTEGRATION TESTS THAT RUN AGAINST THE MOCK DO THAT HERE
        // USING THE PACKAGE(S) CREATED ABOVE
        sep=getSep(platform)
        test_rel_path="${SERVER_VERSION}"
        test_full_path = "couchbase-python-client${sep}${test_rel_path}"
        test_rel_xunit_file="${test_rel_path}${sep}nosetests.xml"
        nosetests_args=" --with-xunit --xunit-file=${test_rel_xunit_file} -v"
        try {
            if (platform.contains("windows")) {
                dir("${WORKSPACE}\\couchbase-python-client") {
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
                    batWithEcho("nosetests ${nosetests_args}")
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
                first_ip = node_list[0].ip
                cbas_ip = getServiceIp(node_list,'cbas')
                dir("${WORKSPACE}/couchbase-python-client") {
                    shWithEcho("mkdir -p ${test_rel_path}")
                    shWithEcho("pip install configparser")
                    shWithEcho("""
                        cat > updateTests.py <<EOF
try:
    from configparser import ConfigParser
except:
    from ConfigParser import ConfigParser

import os
fp = open("tests.ini.sample", "r")
template = ConfigParser()
template.readfp(fp)
template.set("realserver", "enabled", "True")
template.set("mock", "enabled", "False")
template.set("realserver", "host", "${first_ip}")
template.set("realserver", "admin_username", "Administrator")
template.set("realserver", "admin_password", "password")
template.set("realserver", "bucket_password", "password")
try:
    template.add_section("analytics")
except e:
    print("got exception: {}".format(e))
    pass
template.set("analytics", "host", "${cbas_ip}")
with open("tests.ini", "w") as fp:
    template.write(fp)
    print("Wrote to file")
print("Done writing")
print("Wrote {}".format(template))
EOF
                    """)

                    
                    shWithEcho("python updateTests.py")
                    shWithEcho("ls -alrt")
                    shWithEcho("cat tests.ini")
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
                        shWithEcho("nosetests ${nosetests_args}")
                    } else {
                        shWithEcho("""
                        export TMPCMDS="${pyversion}_${LCB_VERSION}_cmds"
                        echo "trying to write to: ["
                        echo "\$TMPCMDS"
                        echo "]"
                        echo "run `which nosetests` ${nosetests_args}" > "\$TMPCMDS"
                        echo "bt" >>"\$TMPCMDS"
                        echo "py-bt" >>"\$TMPCMDS"
                        echo "quit" >>"\$TMPCMDS"
                        gdb -batch -x "\$TMPCMDS" `which python`""")
                    }
                }
            }
        } catch (Exception e) {
            echo "Caught an error in doTests: ${e}"
            throw e
        } finally {
            junit "couchbase-python-client/**/nosetests.xml"
            if (platform.contains("windows")){
                batWithEcho("rmdir /Q /S ${test_full_path}")
            }
            else{
                shWithEcho("rm -rf ${test_full_path}")
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
            if (platform.contains("Windows"))
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
            for (cluster in clusters_running.split('\n')){
                // May need to remove some if they're stuck.  -f forces, allows deleting cluster we didn't open
                if (cluster.contains("node_")){
                    continue
                }
                if (cluster.contains("qe-slave1"))
                {
                    cluster_id_tokens = cluster.trim().split(/\s+/)
                    if (cluster_id_tokens.size()>0)
                    {
                        cluster_id = cluster_id_tokens[0]
                        echo "killing cluster ${cluster_id}"
                        
                        shWithEcho("cbdyncluster rm ${cluster_id}")
                    }
                }                    
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

            // The transactions tests check for this environment property
            withEnv(envStr){
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
        if (platform.contains("windows"))
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

def installClient(platform, arch, dist_dir = null)
{
    script{
        cmdWithEcho(platform,"pip uninstall -y couchbase", true)
        if (platform.contains("windows")){
            batWithEcho("pip install --upgrade couchbase --no-index --find-links ${WORKSPACE}/dist")
        }
        else
        {
            dir("${WORKSPACE}/couchbase-python-client") {
                shWithEcho("pip install cython")
                cmdWithEcho(platform,"pip install cmake",true)
                buildLibCouchbase(platform, arch)
                shWithEcho("python setup.py build_ext --inplace --library-dirs ${LCB_LIB} --include-dirs ${LCB_INC} install")
                if (dist_dir)
                {
                    shWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                }
            }
        }
    }
}

def doIntegration(String platform, String pyversion, String pyshort, String arch, LCB_VERSION, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, SERVER_VERSIONS)
{
    cleanWs()
    unstash "couchbase-python-client"
    unstash "dist-${platform}-${pyversion}-${arch}"
    //unstash "lcb-${platform}-${pyversion}-${arch}"
    installPython("${platform}", "${pyversion}", "${pyshort}", "deps", "${arch}")
    envStr=getEnvStr(platform,pyversion,arch,"5.5.0", PYCBC_VALGRIND)
    withEnv(envStr)
    {
        installClient(platform, arch)
        installReqs(platform)
    }
    for (server_version in SERVER_VERSIONS)
    {
        envStr=getEnvStr(platform,pyversion,arch,server_version,PYCBC_VALGRIND)
        withEnv(envStr)
        {
            testAgainstServer(server_version, platform, envStr, {ip->doTests(ip,platform,pyversion,LCB_VERSION,PYCBC_VALGRIND,PYCBC_DEBUG_SYMBOLS,server_version)})
        }
    }
}

def getSep(platform){
    def sep = "/"
    if (platform.contains("windows")) {
        sep = "\\"
    }
    return sep
}
def buildsAndTests(PLATFORMS, PY_VERSIONS, PY_ARCHES, PYCBC_VALGRIND, PYCBC_DEBUG_SYMBOLS, IS_RELEASE, PACKAGE_PLATFORM, PACKAGE_PY_VERSION, PACKAGE_PY_ARCH, WIN_PY_DEFAULT_VERSION) {
    def pairs = [:] 
    
    def combis = [:]
    // as HashMap<String,Map>
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
    //    combis=addCombi(combis,PACKAGE_PLATFORM,PACKAGE_PY_VERSION,PACKAGE_PY_ARCH)
    }
    def PLATFORM_LIST=[]
    if (hasWindows && !hasWinDefaultPlat)
    {
        for (arch in PY_ARCHES)
        {
    //        combis=addCombi(combis,"windows",WIN_PY_DEFAULT_VERSION,arch)
        }
    }
    echo "Got combis ${combis}"
    for (j in PLATFORMS) {
        for (k in PY_VERSIONS) {
            for (l in PY_ARCHES) {
                def platform = j//.key
                def pyversion = k//.key
                def arch = l//.key
                if (platform.contains("windows") && (pyversion.contains("2.7"))) {
                    continue
                }

                if (!platform.contains("windows") && arch == "x86") {
                    continue
                }
                def label = platform
                if (platform =="windows")
                {
                    if (pyversion>="3.5"){
                        label="msvc-2015"
                    }
                    else if (pyversion>="3.3"){
                        label="msvc-2010"
                    }
                    else
                    {
                        continue
                    }
                }                
                echo "got ${platform} ${pyversion} ${arch}: launching with label ${label}"

                pairs[platform + "_" + pyversion + "_" + arch]= {
                    node(label) {
                        def envStr = []
                        def pyshort=pyversion.tokenize(".")[0] + "." + pyversion.tokenize(".")[1]
                        def win_arch=[x86:[],x64:['Win64']][arch]
                        def plat_build_dir_rel="build_${platform}_${pyversion}_${arch}"
                        def plat_build_dir="${WORKSPACE}/${plat_build_dir_rel}"
                        def sep = getSep(platform)
                        def libcouchbase_build_dir_rel="${plat_build_dir_rel}${sep}libcouchbase"
                        def libcouchbase_build_dir="${WORKSPACE}${sep}${libcouchbase_build_dir_rel}"
                        //def dist_dir_rel="${plat_build_dir_rel}${sep}dist"
                        def dist_dir_rel="dist"
                        def dist_dir="${WORKSPACE}${sep}${dist_dir_rel}"
                        def libcouchbase_checkout="${WORKSPACE}${sep}libcouchbase"
                        if (platform.contains("windows")) { 
                            envStr = ["PATH=${WORKSPACE}\\deps\\python\\python${pyversion}-amd64\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion}-amd64;${WORKSPACE}\\deps\\python\\python${pyversion}\\Scripts;${WORKSPACE}\\deps\\python\\python${pyversion};$PATH"]//, "LCB_PATH=${WORKSPACE}\\libcouchbase", "LCB_BUILD=${WORKSPACE}\\libcouchbase\\build", "LCB_LIB=${WORKSPACE}\\libcouchbase/build\\lib", "LCB_INC=${WORKSPACE}\\libcouchbase\\include;${WORKSPACE}\\libcouchbase/build\\generated", "LD_LIBRARY_PATH=${WORKSPACE}\\libcouchbase\\build\\lib;\$LD_LIBRARY_PATH"]
                        } else {
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
                                            batWithEcho("python setup.py bdist_wheel --dist-dir ${dist_dir}")
                                            batWithEcho("python setup.py sdist --dist-dir ${dist_dir}")
                                        }
                                        //archiveArtifacts artifacts: 'couchbase-python-client/', fingerprint: true, onlyIfSuccessful: false
                                        archiveArtifacts artifacts: "${dist_dir_rel}/*", fingerprint: true, onlyIfSuccessful: false
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
                                                installReqs(platform)
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
                                                installReqs(platform)

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
                                        echo "Caught an error in test bit: ${e}"
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
