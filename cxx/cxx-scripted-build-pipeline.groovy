def CMAKE_VERSION = "3.31.8"

def CBDINOCLUSTER_VERSION = "v0.0.113"
// SHA-256 per release asset, taken verbatim from
// https://github.com/couchbaselabs/cbdinocluster/releases/tag/v0.0.113.
// When bumping CBDINOCLUSTER_VERSION, refresh every entry here in the same commit
// — the digest verification in ensureCbdinocluster() depends on this map being honest.
def CBDINOCLUSTER_SHA256 = [
    "cbdinocluster-darwin-amd64"     : "e6252fdbb37915a41671a4849ab61a2519b3d37b489cf3707ff624a1a7a7ea8c",
    "cbdinocluster-darwin-arm64"     : "e961675555e7f73133c60259656aac15183c9b39d540ac5c9b8323a12311f8a5",
    "cbdinocluster-linux-amd64"      : "f0e15302baceb0880c58a413adbe785b85de8d88c7f44c3213a956f0a98354dd",
    "cbdinocluster-linux-arm64"      : "5a8cf101b8bd946cd3791d585d0ecc6d85d3533c767b2c655148d0654f28b51d",
    "cbdinocluster-windows-amd64.exe": "b72381f826abfaad09887aaabc1940a591fe75356934336823eed70bcce48662",
    "cbdinocluster-windows-arm64.exe": "b86ea9ff4341bb17402b7ed99a298f27907489ae8a1145869bb9ffcfef491e99",
]
def PLATFORMS = [
    "rockylinux9",
    "macos", // sonoma
    "m1",  // sequoia
    "alpine3.21",
    "msvc-2022",
    "qe-rhel9-arm64",
    "qe-ubuntu24-amd64",
    "qe-ubuntu24-arm64"
]
def CB_VERSIONS = [
    "71release": [tag: "7.1-release"],
    "72stable": [tag: "7.2-stable"],
    "76stable": [tag: "7.6-stable"],
    "80stable": [tag: "8.0-stable"]
]

// no 7.0.4 release for community
if (USE_CE.toBoolean()) {
    CB_VERSIONS["70release"] = [tag: "7.0.2", label: "7.0-release"]
} else {
    CB_VERSIONS["70release"] = [tag: "7.0-release"]
}
def COMBINATION_PLATFORM = "rockylinux9"


def checkout() {
    dir("couchbase-cxx-client") {
        checkout([
            $class: "GitSCM",
            branches: [[name: "$SHA"]],
            userRemoteConfigs: [[url: "$REPO", refspec: "$REFSPEC"]],
            extensions: [[
                $class: "SubmoduleOption",
                disableSubmodules: false,
                parentCredentials: false,
                recursiveSubmodules: true,
                reference: "",
                trackingSubmodules: false
            ]]
        ])
    }
}


// Pin cbdinocluster on the current agent to CBDINOCLUSTER_VERSION. Detects OS/arch,
// selects the matching release asset, downloads from GitHub Releases, verifies SHA-256
// against CBDINOCLUSTER_SHA256, and installs to ~/bin (%USERPROFILE%\bin on Windows).
// Idempotent — re-runs are no-ops when the binary already matches the pinned version.
// Conceptually this belongs near DynamicCluster (it's the tool that allocates clusters),
// but keeping it as a top-level def avoids the CPS-vs-class-method awkwardness of
// calling `sh`/`powershell`/`env` from inside a Groovy class in a scripted Jenkinsfile.
def ensureCbdinocluster() {
    def asset
    if (isUnix()) {
        def osLower = sh(returnStdout: true, script: 'uname -s').trim().toLowerCase()
        def archRaw = sh(returnStdout: true, script: 'uname -m').trim()
        def osName = (osLower == "darwin") ? "darwin" : "linux"
        def arch
        if (archRaw == "x86_64" || archRaw == "amd64") {
            arch = "amd64"
        } else if (archRaw == "aarch64" || archRaw == "arm64") {
            arch = "arm64"
        } else {
            error("ensureCbdinocluster: unsupported architecture '${archRaw}'")
        }
        asset = "cbdinocluster-${osName}-${arch}"
    } else {
        def archRaw = powershell(returnStdout: true, script: 'Write-Output $env:PROCESSOR_ARCHITECTURE').trim()
        def arch = archRaw.toUpperCase().contains("ARM") ? "arm64" : "amd64"
        asset = "cbdinocluster-windows-${arch}.exe"
    }
    def expectedSha = CBDINOCLUSTER_SHA256[asset]
    if (!expectedSha) {
        error("ensureCbdinocluster: no sha256 known for asset '${asset}' (refresh CBDINOCLUSTER_SHA256?)")
    }
    def url = "https://github.com/couchbaselabs/cbdinocluster/releases/download/${CBDINOCLUSTER_VERSION}/${asset}"

    if (isUnix()) {
        sh """
            set -euo pipefail
            mkdir -p "\$HOME/bin"
            target="\$HOME/bin/cbdinocluster"
            current=""
            if [ -x "\$target" ]; then
                current=\$("\$target" version 2>/dev/null | head -1)
            fi
            if [ "\$current" = "${CBDINOCLUSTER_VERSION}" ]; then
                echo "cbdinocluster ${CBDINOCLUSTER_VERSION} already installed at \$target"
            else
                echo "Installing cbdinocluster ${CBDINOCLUSTER_VERSION} (was: '\$current')"
                tmp=\$(mktemp)
                trap 'rm -f "\$tmp"' EXIT
                curl -fsSL "${url}" -o "\$tmp"
                actual=\$(sha256sum "\$tmp" | awk '{print \$1}')
                if [ "\$actual" != "${expectedSha}" ]; then
                    echo "ERROR: sha256 mismatch for ${asset}" >&2
                    echo "       expected ${expectedSha}" >&2
                    echo "       got      \$actual" >&2
                    exit 1
                fi
                chmod +x "\$tmp"
                mv "\$tmp" "\$target"
            fi
            "\$target" version
        """
        env.PATH = "${env.HOME}/bin:${env.PATH}"
    } else {
        powershell """
            \$ErrorActionPreference = 'Stop'
            \$dir = Join-Path \$env:USERPROFILE 'bin'
            New-Item -ItemType Directory -Force -Path \$dir | Out-Null
            \$target = Join-Path \$dir 'cbdinocluster.exe'
            \$current = ''
            if (Test-Path \$target) {
                \$current = (& \$target version 2>\$null) | Select-Object -First 1
            }
            if (\$current -eq '${CBDINOCLUSTER_VERSION}') {
                Write-Host "cbdinocluster ${CBDINOCLUSTER_VERSION} already installed at \$target"
            } else {
                Write-Host "Installing cbdinocluster ${CBDINOCLUSTER_VERSION} (was: '\$current')"
                \$tmp = New-TemporaryFile
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri '${url}' -OutFile \$tmp.FullName
                    \$actual = (Get-FileHash -Algorithm SHA256 \$tmp.FullName).Hash.ToLower()
                    if (\$actual -ne '${expectedSha}') {
                        throw "sha256 mismatch for ${asset}: expected ${expectedSha}, got \$actual"
                    }
                    Move-Item -Force \$tmp.FullName \$target
                } finally {
                    if (Test-Path \$tmp.FullName) { Remove-Item -Force \$tmp.FullName }
                }
            }
            & \$target version
        """
        env.PATH = "${env.USERPROFILE}\\bin;${env.PATH}"
    }
}


stage("prepare and validate") {
    node("sdkqe-$COMBINATION_PLATFORM") {
        script {
            buildName([
                BUILD_NUMBER,
                PR_ID == "" ? null : "pr${PR_ID}",
                // STORAGE_BACKEND,
                USE_TLS ? "tls" : null,
                USE_CERT_AUTH ? "cert" : null,
            ].findAll { it != null }.join("-"))
        }
        cleanWs()

        stage("environment") {
            sh '''
                set +e
                echo "===== OS / kernel ====="
                uname -a
                if [ -f /etc/os-release ]; then cat /etc/os-release; fi
                echo
                echo "===== CPU / memory / disk ====="
                echo "cores: $(nproc 2>/dev/null)"
                free -h 2>/dev/null
                df -h . 2>/dev/null
                echo
                echo "===== Toolchain versions ====="
                gcc --version       2>/dev/null | head -1
                g++ --version       2>/dev/null | head -1
                clang --version     2>/dev/null | head -1
                cmake --version     2>/dev/null | head -1
                ninja --version     2>/dev/null
                git --version       2>/dev/null
                python3 --version   2>/dev/null
                openssl version     2>/dev/null
                cbdinocluster version 2>/dev/null
                docker --version    2>/dev/null
                exit 0
            '''
        }

        checkout()

        stage("source tarball") {
            // Build the production source tarball via the cxx-client's own packaging_tarball
            // cmake target. The tarball is `git ls-files --recurse-submodules` plus a vendored
            // CPM third_party_cache (BoringSSL et al.), reproducibly archived. Distributing
            // this between stages — instead of the raw checkout — has two payoffs:
            //   1) the stash carries no .git, no IDE metadata, and no developer-state files,
            //      so we don't need an excludes list;
            //   2) every downstream build runs against exactly the artifact users will receive,
            //      which catches "tarball is missing a file" regressions in CI rather than in
            //      the wild.
            // The prepare-and-validate node is sdkqe-rockylinux9, whose dnf-installed cmake
            // (3.26.x) clears the cxx-client's cmake_minimum_required(3.19).
            dir("couchbase-cxx-client") {
                sh "cmake -B ./build -S . -DCOUCHBASE_CXX_CLIENT_INSTALL=ON"
                sh "cmake --build build --target packaging_tarball"
            }
            // Flatten the tarball path so the stash and downstream extraction are platform-trivial.
            sh "cp couchbase-cxx-client/build/packaging/couchbase-cxx-client-*.tar.gz tarball.tar.gz"
        }

        stash includes: "tarball.tar.gz", name: "tarball"
    }
}


stage("build") {
    def builds = [:]
    for (p in PLATFORMS) {
        def platform = p
        builds[platform] = {
            node(platform) {
                stage("prep") {
                    // Per-node toolchain report: what THIS build node actually has, not just what
                    // prepare-and-validate saw. Best-effort — missing tools never fail the stage.
                    // Goal: when a build breaks on one platform, the build log already records the
                    // exact gcc/clang/cmake (and cl.exe on Windows, where reachable) it ran with,
                    // so triage doesn't require agent-image archaeology.
                    if (platform == "msvc-2022") {
                        powershell '''
                            Write-Host "===== OS / kernel ====="
                            [System.Environment]::OSVersion.ToString()
                            "machine $([System.Environment]::MachineName) ($([System.Environment]::ProcessorCount) cpus)"
                            Write-Host ""
                            Write-Host "===== Toolchain versions ====="
                            & cmake --version 2>&1 | Select-Object -First 1
                            & git --version 2>&1
                            "PowerShell $($PSVersionTable.PSVersion)"
                            $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
                            if ($cl) {
                                "cl.exe at $($cl.Source)"
                                & cl.exe 2>&1 | Select-Object -First 1
                            } else {
                                "cl.exe not on PATH (cmake's VS generator sets it up at configure time)"
                            }
                        '''
                    } else {
                        sh '''
                            set +e
                            echo "===== OS / kernel ====="
                            uname -a
                            if [ -f /etc/os-release ]; then cat /etc/os-release; fi
                            if command -v sw_vers >/dev/null 2>&1; then sw_vers; fi
                            echo
                            echo "===== Toolchain versions ====="
                            gcc --version       2>/dev/null | head -1
                            g++ --version       2>/dev/null | head -1
                            clang --version     2>/dev/null | head -1
                            cmake --version     2>/dev/null | head -1
                            ninja --version     2>/dev/null
                            git --version       2>/dev/null
                            make --version      2>/dev/null | head -1
                            exit 0
                        '''
                    }
                    dir("ws_${platform}") {
                        deleteDir()
                        unstash "tarball"
                        // Extract the production tarball into couchbase-cxx-client/, stripping
                        // the versioned top-level directory (couchbase-cxx-client-${SEMVER}/).
                        // Windows 10/11 and Server 2019+ ship bsdtar at C:\Windows\System32\tar.exe,
                        // which handles -xzf and --strip-components identically to GNU tar.
                        if (platform == "msvc-2022") {
                            powershell '''
                                $ErrorActionPreference = 'Stop'
                                New-Item -ItemType Directory -Force -Path couchbase-cxx-client | Out-Null
                                tar -xzf tarball.tar.gz -C couchbase-cxx-client --strip-components=1
                                if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
                                Remove-Item tarball.tar.gz
                            '''
                        } else {
                            sh """
                                mkdir couchbase-cxx-client
                                tar -xzf tarball.tar.gz -C couchbase-cxx-client --strip-components=1
                                rm tarball.tar.gz
                            """
                        }
                    }
                }
                stage("build") {
                    def envs = ["CB_NUMBER_OF_JOBS=4"]
                    if (platform == "macos") {
                        envs.push("OPENSSL_ROOT_DIR=/usr/local/opt/openssl")
                    } else if (platform == "m1") {
                        envs.push("OPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl")
                    } else if (platform == "rockylinux9") {
                        envs.push("CB_CC=gcc")
                        envs.push("CB_CXX=g++")
                    }
                    def path = PATH
                    if (platform == "msvc-2022") {
                        // BoringSSL is statically linked (-DCOUCHBASE_CXX_CLIENT_STATIC_BORINGSSL=ON),
                        // so no separate OpenSSL install is required on Windows.
                        // TODO(TD-04): verify on the msvc-2022 agent that (a) winget is available
                        //              and (b) bypassing ./bin/build-tests in favor of a direct cmake
                        //              invocation still produces what the unit/integration test stages
                        //              expect under cmake-build-tests/. If winget isn't on the AMI,
                        //              fall back to choco or a direct download of the official archive
                        //              from cmake.org.
                        powershell """
                            \$ErrorActionPreference = 'Stop'
                            \$installed = \$false
                            if (Get-Command cmake -ErrorAction SilentlyContinue) {
                                if ((& cmake --version 2>\$null) -match 'version ${CMAKE_VERSION}') {
                                    \$installed = \$true
                                }
                            }
                            if (-not \$installed) {
                                winget install --exact --id Kitware.CMake --version ${CMAKE_VERSION} --silent --accept-package-agreements --accept-source-agreements --scope machine --disable-interactivity
                                if (\$LASTEXITCODE -ne 0) { throw "winget exit \$LASTEXITCODE" }
                            }
                        """
                        path = "C:\\Program Files\\CMake\\bin;" + path
                    } else if (platform == "macos" || platform == "m1") {
                        // macOS uses Homebrew's cmake. Fail loud if it's not installed — agents
                        // should be provisioned ahead of the build with `brew install cmake`, and
                        // a missing dep ought to abort here rather than be hidden by an
                        // opportunistic install. All Linux platforms — rockylinux9, alpine3.21,
                        // qe-rhel9-arm64, qe-ubuntu24-* — ship cmake ≥ 3.26 via their distro
                        // package managers (well above cxx-client's cmake_minimum_required(3.19)),
                        // so they fall through with no install at all.
                        sh '''
                            if ! brew list --versions cmake >/dev/null 2>&1; then
                                echo "ERROR: cmake is not installed via Homebrew on this agent." >&2
                                echo "       Provision the agent with: brew install cmake" >&2
                                exit 1
                            fi
                            echo "Using Homebrew cmake: $(brew list --versions cmake)"
                        '''
                        // Apple Silicon: /opt/homebrew/bin; Intel macOS: /usr/local/bin.
                        def brewBin = (platform == "m1") ? "/opt/homebrew/bin" : "/usr/local/bin"
                        path = "${brewBin}:" + path
                    }
                    echo("PATH=$path")
                    envs.push("PATH=$path")
                    withEnv(envs) {
                        dir("ws_${platform}/couchbase-cxx-client") {
                            if (platform == "msvc-2022") {
                                powershell '''
                                    cmake --version
                                    if ($LASTEXITCODE -ne 0) { throw "cmake --version failed ($LASTEXITCODE)" }
                                    git --version
                                    if ($LASTEXITCODE -ne 0) { throw "git --version failed ($LASTEXITCODE)" }
                                '''
                                dir("build") {
                                    powershell 'cmake -S .. -B . -DCOUCHBASE_CXX_CLIENT_STATIC_BORINGSSL=ON -DCMAKE_SYSTEM_VERSION=10.0.20348.0'
                                    powershell 'cmake --build . --parallel $env:CB_NUMBER_OF_JOBS'
                                }
                            } else {
                                sh("./bin/build-tests")
                            }
                        }
                    }
                    if (platform == COMBINATION_PLATFORM) {
                        // The workspace was hydrated from a clean tarball (see "source tarball"
                        // sub-stage in prepare-and-validate), so default excludes are safe — no
                        // .git, no IDE metadata, no stray dotfiles to strip out.
                        stash(includes: "ws_${platform}/", name: "${platform}_build")
                    }
                }
            }
        }
    }
    // failFast aborts in-flight platforms as soon as one fails, freeing those agents
    // for the next build instead of letting them grind to completion. The outer timeout
    // is the upper bound for the whole build matrix — if any branch hasn't finished by
    // then it's almost certainly hung (network stall on a CPM fetch, runaway compile),
    // and killing it surfaces the problem rather than burying it in agent-hours.
    builds.failFast = true
    timeout(unit: 'MINUTES', time: 60) {
        parallel(builds)
    }
}


class DynamicCluster {
    String id_ = null
    String version_ = null
    boolean useTLS = false
    boolean useCertAuth = false
    String certsDir = null
    String connstr = null
    String firstIp = null

    DynamicCluster(String version) {
        this.version_ = version
    }

    String clusterId() {
        return id_
    }

    // The connection string is populated once at allocate-time from
    // `cbdinocluster connstr [--tls|--no-tls]`, with the trust certificate
    // appended for TLS. Callers don't need to compose it from parts.
    String connectionString() {
        return connstr
    }

    String firstIP() {
        return firstIp
    }

    String version() {
        return version_.tokenize("_")[0]
    }

    int major() {
        return version().tokenize(".")[0] as Integer
    }

    int minor() {
        // e.g. 7.1-stable or 7.1.0 becomes 1
        return version().tokenize("-")[0].tokenize(".")[1] as Integer
    }

    String certPath() {
        if (useCertAuth) {
            return "$certsDir/client.pem"
        } else {
            return ""
        }
    }

    String keyPath() {
        if (useCertAuth) {
            return "$certsDir/client.key"
        } else {
            return ""
        }
    }
}


if (!SKIP_TESTS.toBoolean()) {
    node("sdkqe-$COMBINATION_PLATFORM") {
        timeout(unit: 'MINUTES', time: 10) {
            stage("unit tests") {
                unstash("${COMBINATION_PLATFORM}_build")
                withEnv([
                    "CTEST_OUTPUT_ON_FAILURE=1",
                    "TEST_LOG_LEVEL=trace"
                ]) {
                    dir("ws_${COMBINATION_PLATFORM}/couchbase-cxx-client") {
                        try {
                            sh("./bin/run-unit-tests")
                        } finally {
                            junit("cmake-build-tests/results.xml")
                        }
                    }
                }
            }
        }
    }

    stage("integration tests: tls=${USE_TLS}, cert_auth=${USE_CERT_AUTH}") {
        def cbverStages = [:]
        CB_VERSIONS.each { cb_version ->
            def v = cb_version.value
            def version = v["tag"]
            def label = version
            if (v["label"] != null) {
                label = v["label"]
            }
            cbverStages["${COMBINATION_PLATFORM}-${label}"] = {
                node("sdkqe-$COMBINATION_PLATFORM") {
                    def CLUSTER = new DynamicCluster(version)
                    try {
                        stage(label) {
                            deleteDir()

                            // Record the runner-local docker version, and ensure cbdinocluster is
                            // present at the pinned version (downloads + verifies SHA-256 if not).
                            // Cluster lifecycle is owned by these two binaries, so a flake here usually
                            // points at one of them — the version lines in the build log narrow it down
                            // immediately instead of leaving you guessing across agent images.
                            sh("docker --version")
                            ensureCbdinocluster()

                            // cbdinocluster topology and cert mode are declared up-front in YAML
                            // and consumed by `cbdinocluster alloc --def-file=...`. There's no
                            // post-alloc `setup` step the way cbdyncluster had.
                            def edition = USE_CE.toBoolean() ? "community-" : ""
                            def fullVersion = "${edition}${version}"
                            def primaryServices  = USE_CE.toBoolean() ? "[kv, index, n1ql, fts]" : "[kv, index, n1ql]"
                            def tertiaryServices = USE_CE.toBoolean() ? "[kv]"                  : "[kv, fts, cbas, eventing]"
                            CLUSTER.useTLS      = USE_TLS.toBoolean()
                            CLUSTER.useCertAuth = USE_CERT_AUTH.toBoolean()
                            CLUSTER.certsDir    = WORKSPACE
                            def useDinoCerts = CLUSTER.useTLS && CLUSTER.useCertAuth
                            writeFile file: "cluster.yaml", text: """\
nodes:
  - count: 1
    version: ${fullVersion}
    services: ${primaryServices}
  - count: 1
    version: ${fullVersion}
    services: [kv]
  - count: 1
    version: ${fullVersion}
    services: ${tertiaryServices}
docker:
  kv-memory: 2048
  fts-memory: 2048
  cbas-memory: 2048
  use-dino-certs: ${useDinoCerts}
expiry: 4h
"""

                            // init is idempotent; safe to re-run on any agent picking up this label.
                            sh("cbdinocluster -v init --auto")
                            CLUSTER.id_ = sh(script: "cbdinocluster -v alloc --def-file=cluster.yaml", returnStdout: true).trim()

                            // TODO(TD-07): cbdinocluster does not currently expose
                            //              --storage-backend on bucket creation; the docker
                            //              deployer hardcodes "couchstore"
                            //              (deployment/commondeploy/{agent,mgmtx}helper.go). The
                            //              previously-honored STORAGE_BACKEND job parameter is now
                            //              silently ignored. If magma testing matters here, add
                            //              the flag upstream in cbdinocluster, or fall back to a
                            //              direct REST call against
                            //              ${CLUSTER.firstIP()}:8091/pools/default/buckets.
                            sh("cbdinocluster buckets add ${CLUSTER.clusterId()} default --ram-quota-mb 256")

                            if (CLUSTER.useCertAuth) {
                                // Client cert auth uses cbdinocluster's global "dino" CA, which
                                // signs the per-user client cert returned by get-client-cert.
                                // The cluster trusts that CA because use-dino-certs:true is set
                                // in the def above. get-client-cert returns a single PEM bundle
                                // (cert + key); awk splits it into the two files the cxx tests
                                // expect at TEST_CERTIFICATE_PATH / TEST_KEY_PATH.
                                sh("""
                                    cbdinocluster certificates get-dino-ca > ${CLUSTER.certsDir}/ca.pem
                                    cbdinocluster certificates get-client-cert Administrator > ${CLUSTER.certsDir}/bundle.pem
                                    awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' ${CLUSTER.certsDir}/bundle.pem > ${CLUSTER.certsDir}/client.pem
                                    awk '/-----BEGIN[^-]*PRIVATE KEY-----/,/-----END[^-]*PRIVATE KEY-----/' ${CLUSTER.certsDir}/bundle.pem > ${CLUSTER.certsDir}/client.key
                                """)
                            } else if (CLUSTER.useTLS) {
                                sh("cbdinocluster certificates get-ca ${CLUSTER.clusterId()} > ${CLUSTER.certsDir}/ca.pem")
                            }

                            CLUSTER.firstIp = sh(script: "cbdinocluster ip ${CLUSTER.clusterId()}", returnStdout: true).trim()
                            def connFlag = CLUSTER.useTLS ? "--tls" : "--no-tls"
                            def rawConnstr = sh(script: "cbdinocluster connstr ${connFlag} ${CLUSTER.clusterId()}", returnStdout: true).trim()
                            if (CLUSTER.useTLS) {
                                rawConnstr += "?trust_certificate=${CLUSTER.certsDir}/ca.pem"
                            }
                            CLUSTER.connstr = rawConnstr

                            // TODO(TD-08): move the cbdinocluster Administrator:password (and
                            //              P@ssword1 in the capella block below) into Jenkins
                            //              credentials via
                            //              withCredentials([usernamePassword(credentialsId: '...', ...)]).
                            //              Hardcoded creds shouldn't live in pipeline source even
                            //              on internal clusters — they leak into the console log
                            //              via -x echo.
                            sh("curl -sS -u Administrator:password http://${CLUSTER.firstIP()}:8093/query/service -d 'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                        }
                        timeout(unit: 'MINUTES', time: 40) {
                            stage("test") {
                                unstash("${COMBINATION_PLATFORM}_build")
                                withEnv([
                                    "TEST_CONNECTION_STRING=${CLUSTER.connectionString()}",
                                    "CTEST_OUTPUT_ON_FAILURE=1",
                                    "TEST_LOG_LEVEL=trace",
                                    "TEST_USE_WAN_DEVELOPMENT_PROFILE=yes",
                                    "TEST_CERTIFICATE_PATH=${CLUSTER.certPath()}",
                                    "TEST_KEY_PATH=${CLUSTER.keyPath()}"
                                ]) {
                                    dir("ws_${COMBINATION_PLATFORM}/couchbase-cxx-client") {
                                        withEnv([
                                            "CB_STRICT_ENCRYPTION=${USE_TLS}",
                                            "CB_HOST=${CLUSTER.firstIP()}",
                                            "CB_TRAVEL_SAMPLE=true",
                                            "CB_FTS_QUOTA=2048", // See MB-64303
                                        ]) {
                                            sh("if [ -f ./bin/init-cluster ] ; then ./bin/init-cluster ; fi")
                                        }
                                        try {
                                            sh("./bin/run-integration-tests")
                                        } catch (e) {
                                            sh("mkdir -p server_logs_${label} && cbdinocluster collect-logs ${CLUSTER.clusterId()} server_logs_${label}")
                                            archiveArtifacts(artifacts: "server_logs_${label}/*.zip", allowEmptyArchive: true)
                                            throw e
                                        } finally {
                                            junit("cmake-build-tests/results.xml")
                                        }
                                    }
                                }
                            }
                        }
                    } finally {
                        stage("cleanup") {
                            sh("cbdinocluster rm ${CLUSTER.clusterId()}")
                        }
                    }
                }
            }
        }
        cbverStages["${COMBINATION_PLATFORM}-capella"] = {
            node("sdkqe-$COMBINATION_PLATFORM") {
                def CLUSTER = new DynamicCluster("capella")
                try {
                    stage("capella") {
                        deleteDir()

                        // Record runner-local docker version, and ensure cbdinocluster is present
                        // at the pinned version (downloads + verifies SHA-256 if not). Any flake
                        // here is attributable to a specific tooling version on the agent.
                        sh("docker --version")
                        ensureCbdinocluster()

                        // TODO(TD-09): cbdinocluster's cloud deployer needs Capella credentials in
                        //              the per-agent config (`cbdinocluster init` reads
                        //              --capella-user / --capella-pass / --capella-oid, or env
                        //              vars CBDC_CAPELLA_USER, CBDC_CAPELLA_PASS, CBDC_CAPELLA_OID).
                        //              cbdyncluster used to pull these from baked-in agent state.
                        //              Until the SDK build agents are provisioned with those creds
                        //              (Jenkins credentials → withCredentials → env), this stage
                        //              will fail at `init --auto`. Wrap with withCredentials(...)
                        //              once the credential IDs exist. Related: TD-08.
                        sh("cbdinocluster -v init --auto")

                        writeFile file: "cluster.yaml", text: """\
cloud:
  cloud-provider: aws
nodes:
  - count: 3
    services: [kv, index, n1ql, eventing, fts, cbas]
expiry: 4h
"""
                        CLUSTER.id_ = sh(script: "cbdinocluster -v alloc --deployer=cloud --def-file=cluster.yaml", returnStdout: true).trim()
                        sh("cbdinocluster buckets add ${CLUSTER.clusterId()} default --ram-quota-mb 256")
                        CLUSTER.firstIp = sh(script: "cbdinocluster ip ${CLUSTER.clusterId()}", returnStdout: true).trim()
                        sh("curl -k -sS -uAdministrator:P@ssword1 https://${CLUSTER.firstIP()}:18093/query/service -d'statement=CREATE PRIMARY INDEX ON default USING GSI' -d 'timeout=300s'")
                        CLUSTER.connstr = sh(script: "cbdinocluster connstr --tls ${CLUSTER.clusterId()}", returnStdout: true).trim()
                    }
                    timeout(unit: 'MINUTES', time: 40) {
                        stage("test") {
                            unstash("${COMBINATION_PLATFORM}_build")
                            withEnv([
                                "TEST_CONNECTION_STRING=${CLUSTER.connectionString()}",
                                "CTEST_OUTPUT_ON_FAILURE=1",
                                "TEST_LOG_LEVEL=trace",
                                "TEST_PASSWORD=P@ssword1",
                                "TEST_DEPLOYMENT_TYPE=capella"
                            ]) {
                                dir("ws_${COMBINATION_PLATFORM}/couchbase-cxx-client") {
                                    try {
                                        sh("./bin/run-integration-tests")
                                    } finally {
                                        junit("cmake-build-tests/results.xml")
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    stage("cleanup") {
                        sh("cbdinocluster rm ${CLUSTER.clusterId()}")
                    }
                }
            }
        }
        parallel(cbverStages)
    }
}
