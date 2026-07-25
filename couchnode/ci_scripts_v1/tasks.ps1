#!/usr/bin/env pwsh
#
# tasks.ps1 — Windows task executors for the Couchbase Node.js SDK (couchnode).
# Mirrors tasks.sh stage-for-stage; see that file's header for the shared design.
#
# Windows-specific deviations from tasks.sh, both ground-truthed against the legacy
# pipeline (scripted-build-pipeline.groovy) and the real couchnode scripts, not
# guessed:
#   - No strip toolchain (objcopy/xcrun) assumed on Windows. The debug artifact is the
#     compiler-emitted .pdb, copied as-is (ground-truthed: legacy's windows branch of
#     the "parse prebuild" stage just does `copy couchbase_impl.pdb ...prebuildsDebug\`,
#     never a strip step).
#   - The legacy pipeline computes `buildType = (BUILD_TYPE != "Debug") ? "Release" :
#     BUILD_TYPE` on Windows (a RelWithDebInfo config default gets forced to Release)
#     AND deliberately never exports CN_BUILD_CONFIG on Windows at all — cmake-js's own
#     default on the Visual Studio (multi-config) generator already lands in a
#     build/Release folder, so this only affects where we go looking for the compiled
#     .node afterward, never what gets passed to the build.

$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ENGINE = Join-Path $SCRIPT_DIR 'engine.js'
$NODE_BIN = if ($env:CBCI_NODE) { $env:CBCI_NODE } else { 'node' }
$NPM_BIN = if ($env:CBCI_NPM) { $env:CBCI_NPM } else { 'npm' }
$PROJECT_ROOT = if ($env:CBCI_PROJECT_ROOT) { $env:CBCI_PROJECT_ROOT } else { (Get-Location).Path }

function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    Write-Host "[$ts] [tasks] $msg"
}
function Die([string]$msg) {
    Write-Error "[tasks] ERROR: $msg"
    exit 1
}
function Invoke-Checked([string]$exe, [string[]]$exeArgs) {
    & $exe @exeArgs
    if ($LASTEXITCODE -ne 0) { Die "'$exe $($exeArgs -join ' ')' exited $LASTEXITCODE" }
}

# Parse a space-joined `KEY=VALUE KEY2=VALUE2` line (engine.js's emitPairs format)
# into the current process environment.
function Import-EnvPairs([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    foreach ($pair in ($line -split ' ')) {
        if ($pair -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}
# Parse newline-separated `KEY=VALUE` lines (engine.js's emitLines format).
function Import-EnvLines([string[]]$lines) {
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

function Node-Platform() { (& $NODE_BIN -p 'process.platform').Trim() }
function Node-Arch() { (& $NODE_BIN -p 'process.arch').Trim() }
function Node-Major() {
    # split out from the cast: `[int](...).Trim()` is ambiguous in PowerShell (the cast
    # can bind before .Trim() runs, calling .Trim() on an int) — do it in two steps.
    $v = (& $NODE_BIN -p 'process.versions.node.split(".")[0]').Trim()
    return [int]$v
}
function Pkg-Version() {
    $pkgPath = (Join-Path $PROJECT_ROOT 'package.json') -replace '\\', '/'
    (& $NODE_BIN -p "require('$pkgPath').version").Trim()
}

# --- stages --------------------------------------------------------------

function Task-DisplayInfo {
    $projEnv = & $NODE_BIN $ENGINE project-env
    Import-EnvPairs $projEnv
    Log "project=COUCHNODE prefix=$env:CBCI_PROJECT_PREFIX config_override=$env:CBCI_CONFIG_OVERRIDE"
    Invoke-Checked $NODE_BIN @($ENGINE, 'validate-config')
}

function Task-Lint {
    Set-Location $PROJECT_ROOT
    Log 'installing dependencies (npm ci --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('ci', '--ignore-scripts')
    Log 'running eslint'
    Invoke-Checked $NPM_BIN @('run', 'lint')
}

function Task-Sdist {
    Set-Location $PROJECT_ROOT

    Log 'installing dependencies (npm ci --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('ci', '--ignore-scripts')

    if (-not (Test-Path 'deps/couchbase-cxx-client/CMakeLists.txt')) {
        Log 'initializing couchbase-cxx-client submodule'
        Invoke-Checked 'git' @('submodule', 'update', '--init', '--recursive', 'deps/couchbase-cxx-client')
    }

    $buildEnv = & $NODE_BIN $ENGINE build-env sdist
    Log "sdist build-env: $buildEnv"
    Import-EnvPairs $buildEnv

    Log 'configuring C++ core + baking CPM cache (deps/couchbase-cxx-cache)'
    # --configure is unconditional; --set-cpm-cache must stay conditional on
    # CN_SET_CPM_CACHE (from build.set_cpm_cache) rather than hardcoded, or the config
    # knob would be unenforceable — see tasks.sh's Task-Sdist for the full reasoning.
    $prebuildArgs = @('run', 'prebuild', '--', '--configure')
    if ($env:CN_SET_CPM_CACHE -eq 'ON' -or -not $env:CN_SET_CPM_CACHE) {
        $prebuildArgs += '--set-cpm-cache'
    }
    Invoke-Checked $NPM_BIN $prebuildArgs

    Log 'packing source distribution (npm pack)'
    Invoke-Checked $NPM_BIN @('pack')
    Log 'dist contents:'
    Get-ChildItem *.tgz | Format-Table -AutoSize
}

# Copy the .pdb debug symbols (no strip on Windows — ground-truthed, see file header),
# then rename the release binary into place under prebuilds/.
function Task-PrebuildRepair([string]$built, [string]$filename) {
    if (-not (Test-Path $built)) { Die "prebuild-repair: built binary not found: $built" }
    New-Item -ItemType Directory -Force -Path 'prebuilds', 'prebuildsDebug' | Out-Null

    $target = "prebuilds/$filename.node"
    Copy-Item $built $target -Force

    $builtDir = Split-Path -Parent $built
    $pdb = Join-Path $builtDir 'couchbase_impl.pdb'
    if (Test-Path $pdb) {
        Copy-Item $pdb "prebuildsDebug/$filename-debug.pdb" -Force
        Log "prebuild-repair: copied debug symbols -> prebuildsDebug/$filename-debug.pdb"
    } else {
        Log "WARNING: prebuild-repair: no .pdb found next to $built (Debug/RelWithDebInfo config?) — no debug artifact produced"
    }
    Log "prebuild-repair: $filename.node ready (prebuilds/)"
}

function Task-Prebuild {
    Set-Location $PROJECT_ROOT

    # Self-sufficient build FROM the packed sdist tarball — see tasks.sh's
    # task_prebuild for the full reasoning (package-lock.json isn't packed so this
    # must be `npm install` not `npm ci`; --ignore-scripts skips install.js building
    # against the ambient runtime before we set the real target).
    $sdistTgz = Get-ChildItem './*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sdistTgz) { Die "prebuild: no *.tgz found under $PROJECT_ROOT (unstash the sdist first?)" }
    Log "prebuild: unpacking $($sdistTgz.Name)"
    Invoke-Checked 'tar' @('-xzf', $sdistTgz.FullName, '--strip-components=1')
    Log 'prebuild: restoring devDependencies (npm install --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('install', '--ignore-scripts')

    $buildEnv = & $NODE_BIN $ENGINE build-env prebuild
    Log "prebuild build-env: $buildEnv"
    Import-EnvPairs $buildEnv
    # Capture the CONFIGURED build type before clearing it: still needed below to
    # decide the Debug/Release output-folder lookup, even though (ground-truthed) the
    # legacy pipeline never exports CN_BUILD_CONFIG itself on Windows — cmake-js's own
    # Visual Studio (multi-config) generator default already lands in build/Release.
    $configuredBuildType = if ($env:CN_BUILD_CONFIG) { $env:CN_BUILD_CONFIG } else { 'RelWithDebInfo' }
    [Environment]::SetEnvironmentVariable('CN_BUILD_CONFIG', $null, 'Process')

    $selectEnv = & $NODE_BIN $ENGINE prebuild-select-env
    Log "prebuild select-env: $($selectEnv -join '; ')"
    Import-EnvLines $selectEnv

    $runtime = if ($env:CBCI_BUILD_RUNTIME) { $env:CBCI_BUILD_RUNTIME } else { 'node' }
    if ($runtime -eq 'electron' -and -not $env:CBCI_BUILD_ELECTRON_VERSION) {
        Die 'prebuild: runtime=electron requires CBCI_BUILD_ELECTRON_VERSION (set by the adapter per job)'
    }

    Log "building (npm run prebuild) runtime=$runtime version=$($env:CN_PREBUILD_RUNTIME_VERSION)"
    Invoke-Checked $NPM_BIN @('run', 'prebuild')

    # Ground-truthed Windows quirk: RelWithDebInfo (or anything but Debug) is forced to
    # the Release output folder — see file header.
    $buildConfig = if ($configuredBuildType -eq 'Debug') { 'Debug' } else { 'Release' }
    $built = "build/$buildConfig/couchbase_impl.node"
    if (-not (Test-Path $built)) { Die "prebuild: expected binary not found: $built" }

    $version = Pkg-Version
    $nodePlatform = Node-Platform
    $nodeArch = Node-Arch
    if ($runtime -eq 'electron') {
        $kind = 'electron'; $abi = $env:CBCI_BUILD_ELECTRON_VERSION
        $sslSuffix = 'boringssl'
    } else {
        $kind = 'napi'; $abi = '6'
        if ($env:CN_USE_OPENSSL -eq 'ON') {
            $sslSuffix = if ((Node-Major) -ge 18) { 'openssl3' } else { 'openssl1' }
        } else {
            $sslSuffix = 'boringssl'
        }
    }
    $filename = "couchbase-v$version-$kind-v$abi-$nodePlatform-$nodeArch-$sslSuffix"

    Task-PrebuildRepair $built $filename
    Log 'prebuild: release:'; Get-ChildItem prebuilds | Format-Table -AutoSize
    Log 'prebuild: debug:';   Get-ChildItem prebuildsDebug -ErrorAction SilentlyContinue | Format-Table -AutoSize
}

function Invoke-ValidateOne([string]$itype, [string]$sdistTgz) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Log "validate: install_type=$itype in $tmp"
    Push-Location $tmp
    try {
        Invoke-Checked $NPM_BIN @('init', '-y')
        if ($itype -eq 'prebuild') {
            $prebuildDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Force -Path $prebuildDir | Out-Null
            $prebuilt = Get-ChildItem (Join-Path $PROJECT_ROOT 'prebuilds') -Filter *.node -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $prebuilt) { Die "validate: no prebuild found under $PROJECT_ROOT/prebuilds (build it first?)" }
            Copy-Item $prebuilt.FullName $prebuildDir
            $env:npm_config_couchbase_local_prebuilds = $prebuildDir
            try { Invoke-Checked $NPM_BIN @('install', $sdistTgz) }
            finally { Remove-Item Env:\npm_config_couchbase_local_prebuilds; Remove-Item -Recurse -Force $prebuildDir }
        } elseif ($itype -eq 'sdist') {
            Invoke-Checked $NPM_BIN @('install', $sdistTgz)
        } else {
            Die "validate: unknown install_type: $itype (prebuild|sdist)"
        }
        $importName = $env:CBCI_VALIDATE_IMPORT
        & $NODE_BIN -e "
const pkg = require(process.env.CBCI_VALIDATE_IMPORT);
if (typeof pkg.connect !== 'function') { console.error('[validate] couchbase module missing connect()'); process.exit(1); }
console.log('[validate] required ' + process.env.CBCI_VALIDATE_IMPORT + ' OK, connect() present');
"
        if ($LASTEXITCODE -ne 0) { Die "validate: smoke check failed for $itype" }
    } finally {
        Pop-Location
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Task-Validate {
    Set-Location $PROJECT_ROOT
    $out = & $NODE_BIN $ENGINE validate-env
    Import-EnvPairs $out
    if ($env:CBCI_INSTALL_TYPE) { $env:CBCI_VALIDATE_INSTALL_TYPES = $env:CBCI_INSTALL_TYPE }

    $sdistTgz = Get-ChildItem (Join-Path $PROJECT_ROOT '*.tgz') -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sdistTgz) { Die "validate: no *.tgz found under $PROJECT_ROOT (build sdist first?)" }

    foreach ($itype in ($env:CBCI_VALIDATE_INSTALL_TYPES -split ',')) {
        Invoke-ValidateOne $itype $sdistTgz.FullName
        Log "validate: $itype OK"
    }
    Log "validate: all install types passed ($env:CBCI_VALIDATE_INSTALL_TYPES)"
}

function Task-Test {
    Set-Location $PROJECT_ROOT

    $requiresJava = (& $NODE_BIN $ENGINE requires-java).Trim()
    if ($requiresJava -eq 'true') {
        if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
            Die "test: ci-config requires java (CouchbaseMock.jar backend) but 'java' is not on PATH"
        }
    }

    Log 'installing dependencies (npm ci)'
    Invoke-Checked $NPM_BIN @('ci')

    $cmds = & $NODE_BIN $ENGINE test-cmds
    if (-not $cmds) { Die 'test: no test commands configured' }

    foreach ($cmd in $cmds) {
        Log "test: run: $cmd"
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) { Die "test: mocha failed (rc=$LASTEXITCODE)" }
    }
    Log 'test: OK'
}

function Task-Package {
    Set-Location $PROJECT_ROOT
    $pkgName = (& $NODE_BIN -p "require('./package.json').name").Trim()
    $version = Pkg-Version

    if (-not $env:CBCI_BUILD_PLATFORM) { Die 'package: CBCI_BUILD_PLATFORM required' }
    if (-not $env:CBCI_BUILD_ARCH) { Die 'package: CBCI_BUILD_ARCH required' }
    $platform = $env:CBCI_BUILD_PLATFORM
    $arch = $env:CBCI_BUILD_ARCH
    $runtime = if ($env:CBCI_BUILD_RUNTIME) { $env:CBCI_BUILD_RUNTIME } else { 'node' }
    $pkgRuntime = if ($runtime -eq 'node') { 'napi' } else { 'electron' }

    $subname = "$pkgName-$platform-$arch-$pkgRuntime"
    $outDir = "platform-packages/$subname"
    Remove-Item -Recurse -Force $outDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path "$outDir/prebuilds" | Out-Null

    $prebuild = Get-ChildItem 'prebuilds' -Filter *.node -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $prebuild) { Die 'package: no prebuild found under prebuilds/ (build it first?)' }
    Copy-Item $prebuild.FullName "$outDir/prebuilds/"

    $pkgJson = @{
        name = "@$pkgName/$subname"
        version = $version
        description = "Prebuilt $pkgName binary for $platform/$arch ($pkgRuntime)"
        os = @($platform)
        cpu = @($arch)
        files = @('prebuilds/')
    } | ConvertTo-Json
    Set-Content -Path "$outDir/package.json" -Value $pkgJson

    Log "package: platform package ready at $outDir"
    Get-ChildItem "$outDir/prebuilds" | Format-Table -AutoSize
}

# --- dispatch ----------------------------------------------------------------

function Main([string[]]$argv) {
    if ($argv.Count -lt 1) { Die 'usage: tasks.ps1 <stage> [args...]' }
    $stage = $argv[0]
    $rest = if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] } else { @() }

    if ($env:CBCI_LOG_FILE -and -not $env:CBCI_LOG_TEEING -and $stage -notlike '_*') {
        $logDir = Split-Path -Parent $env:CBCI_LOG_FILE
        if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $env:CBCI_LOG_TEEING = '1'
        & pwsh -File $PSCommandPath @argv 2>&1 | Tee-Object -FilePath $env:CBCI_LOG_FILE
        exit $LASTEXITCODE
    }

    switch ($stage) {
        'display-info' { Task-DisplayInfo @rest }
        'lint'         { Task-Lint @rest }
        'sdist'        { Task-Sdist @rest }
        'prebuild'     { Task-Prebuild @rest }
        'validate'     { Task-Validate @rest }
        'test'         { Task-Test @rest }
        'package'      { Task-Package @rest }
        '_prebuild_repair' { Task-PrebuildRepair @rest }
        default { Die "unknown stage: $stage" }
    }
}

Main $args
