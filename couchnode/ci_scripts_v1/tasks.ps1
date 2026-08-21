#!/usr/bin/env pwsh
#
# tasks.ps1 - Windows task executors for the Couchbase Node.js SDK (couchnode).
# Mirrors tasks.sh stage-for-stage; see that file's header for the shared design.
#
# Two Windows-specific deviations from tasks.sh:
#   - No strip toolchain (objcopy/xcrun) is assumed on Windows. The debug artifact is the
#     compiler-emitted .pdb, copied as-is, with no strip step.
#   - CN_BUILD_CONFIG is deliberately NOT exported on Windows. cmake-js's default on the
#     Visual Studio (multi-config) generator already lands in build/Release, so the
#     configured build type only decides where to look for the compiled .node afterward,
#     never what gets passed to the build.

# Force TLS 1.2 on PowerShell 5.1 / .NET Framework on older Windows Server agents
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = 'Stop'

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ENGINE = Join-Path $SCRIPT_DIR 'engine.mjs'
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

# Parse a space-joined `KEY=VALUE KEY2=VALUE2` line (engine.mjs's emitPairs format)
# into the current process environment.
function Import-EnvPairs([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    foreach ($pair in ($line -split ' ')) {
        if ($pair -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}
# Parse newline-separated `KEY=VALUE` lines (engine.mjs's emitLines format).
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
    # can bind before .Trim() runs, calling .Trim() on an int) - do it in two steps.
    $v = (& $NODE_BIN -p 'process.versions.node.split(".")[0]').Trim()
    return [int]$v
}
function Pkg-Version() {
    $pkgPath = (Join-Path $PROJECT_ROOT 'package.json') -replace '\\', '/'
    (& $NODE_BIN -p "require('$pkgPath').version").Trim()
}

function Get-TarExe {
    # System32\tar.exe is Windows native bsdtar (Windows 10 / Server 2019+).
    # Prefer it explicitly over MSYS/Git tar to avoid MSYS gzip/remote-host path issues.
    if ($env:SystemRoot) {
        $sys32Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (Test-Path $sys32Tar) { return $sys32Tar }
    }
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) { return 'tar.exe' }
    if (Get-Command tar -ErrorAction SilentlyContinue) { return 'tar' }
    $gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
    if (Test-Path $gitTar) { return $gitTar }
    $gitTarX86 = 'C:\Program Files (x86)\Git\usr\bin\tar.exe'
    if (Test-Path $gitTarX86) { return $gitTarX86 }
    return $null
}

function Unpack-Tarball([string]$tgzPath) {
    # Ensure Git\usr\bin is on PATH if present so MSYS tar (if used) can locate gzip.exe
    $gitUsrBin = 'C:\Program Files\Git\usr\bin'
    if (Test-Path $gitUsrBin) {
        if (($env:PATH -split ';') -notcontains $gitUsrBin) {
            $env:PATH = "$gitUsrBin;$env:PATH"
        }
    }
    $gitUsrBinX86 = 'C:\Program Files (x86)\Git\usr\bin'
    if (Test-Path $gitUsrBinX86) {
        if (($env:PATH -split ';') -notcontains $gitUsrBinX86) {
            $env:PATH = "$gitUsrBinX86;$env:PATH"
        }
    }

    $tarBin = Get-TarExe
    if ($tarBin) {
        $relPath = Resolve-Path -Relative $tgzPath -ErrorAction SilentlyContinue
        $tarFile = if ($relPath) { $relPath } else { $tgzPath }
        Log "unpacking $tarFile using $tarBin"
        & $tarBin --force-local -xzf $tarFile --strip-components=1
        if ($LASTEXITCODE -eq 0) { return }
        Log "WARNING: $tarBin exited $LASTEXITCODE; trying node fallback"
    }

    Log "Unpacking via node fallback..."
    & $NODE_BIN -e "
const fs = require('fs');
const path = require('path');
const execDir = path.dirname(process.execPath);
const candidates = [
    path.join(execDir, 'node_modules/npm/node_modules/tar'),
    path.join(execDir, '../lib/node_modules/npm/node_modules/tar'),
    path.join(execDir, '../node_modules/npm/node_modules/tar')
];
let npmTar = candidates.find(c => fs.existsSync(c));
if (npmTar) {
    require(npmTar).x({ file: process.argv[1], strip: 1, sync: true });
} else {
    console.error('ERROR: Cannot locate tar.exe or npm bundled tar module');
    process.exit(1);
}
" $tgzPath
    if ($LASTEXITCODE -ne 0) { Die "failed to unpack $tgzPath" }
}

# Longest $PROJECT_ROOT that MSVC can build couchnode underneath. Windows caps a path at
# 260 chars INCLUDING the terminating NUL, so 259 is the longest usable string, and cl.exe
# has no long-path support for the files it generates itself. Past the limit it reports
#     fatal error C1083: Cannot open compiler generated file: '': Invalid argument
# with an EMPTY filename, blamed on whichever .cxx it was compiling, so the failure reads
# as a compiler or source problem rather than a path-length one. It also bites only the
# single deepest object path in the tree, so a build stays green until one filename tips it
# over.
#
# Derivation. cmake-js builds into $PROJECT_ROOT\build (6 chars) using the Visual Studio
# multi-config generator, which lands a target's intermediates in
# <target-binary-dir>\<target>.dir\<Config>\. The deepest of them belongs to the C++ core:
#     \deps\couchbase-cxx-client\couchbase_cxx_client_static_intermediate.dir\Release
#     \core\impl\transaction_get_multi_replicas_from_preferred_server_group_spec.obj
# which is 157 chars, so the budget is 259 - 6 - 157 = 96.
#
# Note the layout differs from the Makefile/Ninja one (no \CMakeFiles component, and
# \Release sits under .dir rather than being appended to the build root), so this number
# is NOT transferable to or from a generator-agnostic measurement. Re-measure by finding
# the longest .obj under build\deps\couchbase-cxx-client after a Windows build and
# subtracting $PROJECT_ROOT.
#
# Sanity check on the number: the equivalent guard on the Python SDK allows 80 chars of
# workspace, this one allows 86, and observed Jenkins Windows workspaces run 54 to 68. The
# budget has headroom against the agents that already build under the stricter limit.
$ProjectRootMaxLen = 96

# Fail BEFORE the compile rather than 40 minutes into it with C1083 and no filename.
#
# Windows only, and not merely because that is where CI builds: MAX_PATH is a Win32 limit,
# so on a POSIX host (pwsh runs there too) this would reject a perfectly buildable deep
# checkout. $env:OS rather than $IsWindows, which does not exist in PowerShell 5.1.
#
# Unlike the Python SDK's equivalent there is no build-temp variable to redirect: cmake-js
# fixes the build tree at $PROJECT_ROOT\build, so the only remedy is a shorter path, which
# on Jenkins means a shorter workspace. CBCI_ALLOW_LONG_BUILD_PATH exists to test whether
# the budget above is itself wrong, not for routine use.
function Assert-BuildPathFits([string]$root) {
    if (-not $root) { return }
    if ($env:OS -ne "Windows_NT") { return }
    if ($root.Length -le $ProjectRootMaxLen) {
        Log "prebuild: project root path is $($root.Length)/$ProjectRootMaxLen chars"
        return
    }
    $over = $root.Length - $ProjectRootMaxLen
    $msg = ("prebuild: project root path is $($root.Length) chars, $over over the " +
            "$ProjectRootMaxLen-char MAX_PATH budget: $root. MSVC does not fail on this path " +
            "itself, it fails mid-compile with C1083 (cannot open compiler generated file) and " +
            "an EMPTY filename, on whichever object path is deepest. Use a shorter workspace, " +
            "or move the checkout nearer the drive root.")
    if ($env:CBCI_ALLOW_LONG_BUILD_PATH -eq "true") {
        Log "WARNING: $msg (continuing, CBCI_ALLOW_LONG_BUILD_PATH=true)"
        return
    }
    Die $msg
}

# --- build-info: the Windows half of the record tasks.sh writes elsewhere -----
#
# Same file format, same unit key, same directory, so build-info-pack (tasks.sh, run on the
# aggregating linux agent) reads a Windows record without knowing it wrote one. The keys
# consumed by that summary are unit, platform, runtime, compiler and windows_sdk; the rest
# is read by whoever is investigating.

function BuildInfo-Dir { Join-Path $PROJECT_ROOT 'buildInfo' }

function Sha256-Of([string]$path) {
    try {
        return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
    } catch {
        return 'unknown'
    }
}

# First line of a native tool's output, or 'unknown'. Piped through Out-String rather than
# returned directly: a bare `& $exe` inside a function writes to the FUNCTION'S output
# stream, so its lines would be prepended to whatever the caller expected back.
function First-Line([string]$exe, [string[]]$exeArgs) {
    try {
        $out = (& $exe @exeArgs 2>&1 | Out-String)
        if (-not $out) { return 'unknown' }
        $line = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($line) { return $line.Trim() } else { return 'unknown' }
    } catch {
        return 'unknown'
    }
}

function Or-Unknown($v) { if ($v) { return $v } else { return 'unknown' } }

# First non-empty of its arguments, or 'unknown'. Exists so a record field can prefer the
# adapter's neutral CBCI_BUILD_* channel and still resolve from a local developer shell.
function First-Set([string[]]$values) {
    foreach ($v in $values) { if ($v) { return $v.Trim() } }
    return 'unknown'
}

# cl.exe's banner goes to STDERR. Windows PowerShell 5.1, which is what the pipeline invokes,
# promotes a redirected native stderr into a terminating error under the 'Stop' preference set
# at the top of this file, so a `2>&1` capture of it never returns the banner at all: the catch
# reports "unknown". PowerShell 7 does not behave that way, which is why this reads correctly
# from a developer shell and never from CI. cmd merges the streams before PowerShell sees them
# either way. Worth having next to msvc_toolset: this is the only field naming the compiler
# BINARY that ran rather than the toolchain directory it was selected from.
function Cl-Banner {
    try {
        # Guarded, so a cl that is not on PATH yields "unknown" rather than cmd's
        # "not recognized" text sitting in the field.
        if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { return 'unknown' }
        # Function-scoped, so it does not leak to the caller. Relaxed for the same reason the
        # call goes through cmd: cl exits non-zero when invoked with no arguments, and that
        # must not discard the banner it already printed.
        $ErrorActionPreference = 'Continue'
        $line = (& cmd /c 'cl 2>&1') | Where-Object { $_.ToString().Trim() } | Select-Object -First 1
        if ($line) { return $line.ToString().Trim() } else { return 'unknown' }
    } catch {
        return 'unknown'
    }
}

# The MSVC toolchain, which no SHA in this record pins. vcvarsall.bat is what selects it, and
# it runs in the ADAPTER, not here, so these read the neutral channel first: only
# WindowsSDKVersion is forwarded into the build shell under its real name, and the rest would
# otherwise all record "unknown" under CI. The real vcvars variables stay as the fallback for a
# local run inside a developer shell. WindowsSDKVersion arrives with a trailing backslash; it is
# trimmed so two agents can be compared as strings.
function Emit-WindowsToolchain {
    $sdk = $env:WindowsSDKVersion
    if ($sdk) { $sdk = $sdk.TrimEnd('\') }
    "msvc_toolset=$(First-Set @($env:CBCI_BUILD_MSVC_TOOLSET, $env:VCToolsVersion))"
    # Which Visual Studio, spelled out. The toolset above is a directory version (14.29 vs
    # 14.30); this is the number the agent was provisioned by, and the two matter separately
    # because the adapter picks its VS by AGENT NAME.
    "vs_version=$(First-Set @($env:CBCI_BUILD_VS_VERSION, $env:VSCMD_VER))"
    "windows_sdk=$(Or-Unknown $sdk)"
    "vs_install=$(First-Set @($env:CBCI_BUILD_VS_INSTALL, $env:VSINSTALLDIR))"
    "vc_target_arch=$(First-Set @($env:CBCI_BUILD_VS_TGT_ARCH, $env:VSCMD_ARG_TGT_ARCH))"
    # Recorded under the same key the other platforms use for their compiler so the summary
    # has one column.
    "compiler=$(Cl-Banner)"
    "cmake=$(First-Line 'cmake' @('--version'))"
    "runner_os=$(Or-Unknown ([System.Environment]::OSVersion.Version.ToString()))"
    "host_arch=$(Or-Unknown $env:PROCESSOR_ARCHITECTURE)"
}

# Facts shared with the tasks.sh records. CI identity arrives ONLY through the neutral
# CBCI_BUILD_* channel the adapter sets, so this file speaks no CI's vocabulary; the agent
# falls back to the hostname, which keeps the most investigation-critical field correct even
# from a bare local run.
function Emit-CommonIdentity {
    $agent = if ($env:CBCI_BUILD_AGENT) { $env:CBCI_BUILD_AGENT } else { $env:COMPUTERNAME }
    "agent=$(Or-Unknown $agent)"
    "build=$(Or-Unknown $env:CBCI_BUILD_REF)"
    "runner_image=$(Or-Unknown $env:CBCI_BUILD_IMAGE)"
    "node=$(First-Line $NODE_BIN @('-p', 'process.versions.node'))"
    "npm=$(First-Line $NPM_BIN @('--version'))"
    # CBCI_SHA rather than git: the prebuild stage builds from the packed sdist, which
    # carries no git metadata. The C++ core sha is recorded by the sdist stage, which runs
    # where the checkout still exists, and the summary takes it from there.
    "sdk_sha=$(Or-Unknown $env:CBCI_SHA)"
    "cxx_client_sha=unknown"
}

# The prebuilds this unit produced, with hashes, so a binary pulled out of a published
# platform package can be matched back to the record of what built it.
function Emit-PrebuildIdentity {
    $bins = @(Get-ChildItem -Path (Join-Path $PROJECT_ROOT 'prebuilds') -Filter '*.node' `
                            -File -ErrorAction SilentlyContinue | Sort-Object Name)
    "prebuild_count=$($bins.Count)"
    $i = 0
    foreach ($b in $bins) {
        $i++
        "prebuild_$i=$($b.Name)"
        "prebuild_${i}_sha256=$(Sha256-Of $b.FullName)"
    }
}

# Records ONE prebuild unit as buildInfo/<unit>.txt, where <unit> is the prebuild name
# minus its version and is passed in by the caller. See tasks.sh's _build_info_unit for why
# it is derived from the artifact name rather than from (platform, arch, runtime).
function Write-BuildInfo([string]$unit) {
    if (-not $unit) { Die 'build-info: Write-BuildInfo needs a unit name' }
    $platform = if ($env:CBCI_BUILD_PLATFORM) { $env:CBCI_BUILD_PLATFORM } else { 'windows' }
    $arch = if ($env:CBCI_BUILD_ARCH) { $env:CBCI_BUILD_ARCH } else { (Node-Arch) }
    $runtime = if ($env:CBCI_BUILD_RUNTIME) { $env:CBCI_BUILD_RUNTIME } else { 'node' }

    $runtimeVersion = if ($runtime -eq 'electron') {
        $env:CBCI_BUILD_ELECTRON_VERSION
    } else {
        $env:CBCI_BUILD_NODE_VERSION
    }
    $napi = if ($runtime -eq 'node') {
        if ($env:CN_NAPI_VERSION) { $env:CN_NAPI_VERSION } else { '6' }
    } else { 'n/a' }
    $ssl = if ($env:CN_USE_OPENSSL -eq 'ON') { 'openssl' } else { 'boringssl' }

    $dir = BuildInfo-Dir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $info = Join-Path $dir "$unit.txt"

    $lines = @(
        "unit=$unit"
        "platform=$platform"
        "arch=$arch"
        "runtime=$runtime"
        "runtime_version=$(Or-Unknown $runtimeVersion)"
        "napi_version=$napi"
        "ssl=$ssl"
        # CN_BUILD_CONFIG is cleared before the build on Windows (see the file header), so
        # the CONFIGURED value is passed in rather than read back out of the environment.
        "build_type=$(Or-Unknown $env:CBCI_BUILD_TYPE)"
        "package_version=$(Pkg-Version)"
    )
    $lines += Emit-CommonIdentity
    $lines += Emit-WindowsToolchain
    $lines += Emit-PrebuildIdentity

    # -Encoding ascii, not the PowerShell 5.1 default: that default is UTF-16LE with a BOM,
    # which the linux agent's sed/grep read as binary when it packs and summarises these.
    Set-Content -Path $info -Value $lines -Encoding ascii
    foreach ($l in $lines) { Log "  build-info: $l" }
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
    # knob would be unenforceable - see tasks.sh's Task-Sdist for the full reasoning.
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

# Copy the .pdb debug symbols (no strip on Windows - ground-truthed, see file header),
# then rename the release binary into place under prebuilds/.
# Its OWN directory, deliberately not a subdirectory of prebuildsDebug/. That directory is
# the publish payload: the aggregate stage copies every entry of it into dist_debug/ and the
# release job uploads every file there to a public bucket. Diagnostics belong in neither.
function RepairDiag-Dir { Join-Path $PROJECT_ROOT 'repairDiag' }

# Dump what is needed to tell "this config emits no PDB" apart from "the PDB was emitted
# somewhere this did not look". The prebuild stage stashes nothing when it fails, and even
# when it only warns the build tree is deleted at the start of the next run, so this is the
# one chance to record where the compiler actually put things.
#
# Best-effort throughout: a failure inside the dumper must not replace the caller's error.
function Write-RepairDiag([string]$stem, [string]$built, [string]$reason) {
    try {
        $dir = RepairDiag-Dir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $out = Join-Path $dir "$stem.repair-diag.txt"
        Log "writing repair diagnostics to $out"
        $lines = @(
            "=== prebuild-repair diagnostics: $stem",
            "reason=$reason",
            "--- config",
            "built=$built",
            "configured_build_type=$(Or-Unknown $env:CBCI_BUILD_TYPE)",
            "cn_build_config=$(Or-Unknown $env:CN_BUILD_CONFIG)",
            "vc_tools=$(First-Set @($env:CBCI_BUILD_MSVC_TOOLSET, $env:VCToolsVersion))",
            "--- every .pdb under build/, wherever the generator put it"
        )
        # Recursive and unfiltered: the question this answers is whether the compiler emitted
        # a PDB at all, which a lookup beside the .node cannot distinguish from a PDB written
        # to a different config directory.
        $pdbs = @(Get-ChildItem -Path 'build' -Filter '*.pdb' -Recurse -File -ErrorAction SilentlyContinue)
        if ($pdbs.Count -eq 0) {
            $lines += '(none found)'
        } else {
            foreach ($p in $pdbs) { $lines += "$($p.Length)`t$($p.FullName)" }
        }
        $lines += '--- build/ tree, two levels'
        $lines += @(Get-ChildItem -Path 'build' -Depth 1 -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName })
        Set-Content -Path $out -Value $lines -Encoding ascii
    } catch {
        Log "WARNING: prebuild-repair: could not write diagnostics ($($_.Exception.Message))"
    }
}

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
        # Whether this is a failure depends on the config, so the rule is encoded rather than
        # assumed. Debug and RelWithDebInfo compile with /Zi and MUST leave a PDB, so a
        # missing one means the split broke and shipping would leave Windows with no symbols
        # at all. A plain Release build legitimately emits none, and that stays a warning.
        Write-RepairDiag -stem $filename -built $built -reason 'no .pdb beside the built binary'
        $cfg = $env:CBCI_BUILD_TYPE
        if ($cfg -eq 'RelWithDebInfo' -or $cfg -eq 'Debug') {
            Die ("prebuild-repair: no .pdb found next to $built, but the configured build type " +
                 "is $cfg, which compiles with /Zi and always emits one. The symbol split is " +
                 "broken, not merely absent: see repairDiag/$filename.repair-diag.txt for " +
                 "every .pdb the build actually produced.")
        }
        Log ("WARNING: prebuild-repair: no .pdb found next to $built and the configured build " +
             "type is '$(Or-Unknown $cfg)', which need not emit one - no debug artifact produced")
    }
    Log "prebuild-repair: $filename.node ready (prebuilds/)"
}

function Task-Prebuild {
    Set-Location $PROJECT_ROOT

    # Self-sufficient build FROM the packed sdist tarball - see tasks.sh's
    # task_prebuild for the full reasoning (package-lock.json isn't packed so this
    # must be `npm install` not `npm ci`; --ignore-scripts skips install.js building
    # against the ambient runtime before we set the real target).
    $sdistTgz = Get-ChildItem './*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sdistTgz) { Die "prebuild: no *.tgz found under $PROJECT_ROOT (unstash the sdist first?)" }
    Log "prebuild: unpacking $($sdistTgz.Name)"
    Unpack-Tarball $sdistTgz.FullName
    Log 'prebuild: restoring devDependencies (npm install --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('install', '--ignore-scripts')

    $buildEnv = & $NODE_BIN $ENGINE build-env prebuild
    Log "prebuild build-env: $buildEnv"
    Import-EnvPairs $buildEnv
    # Capture the CONFIGURED build type before clearing it: it still decides the
    # Debug/Release output-folder lookup below, even though CN_BUILD_CONFIG is never
    # exported on Windows. See the file header.
    $configuredBuildType = if ($env:CN_BUILD_CONFIG) { $env:CN_BUILD_CONFIG } else { 'RelWithDebInfo' }
    [Environment]::SetEnvironmentVariable('CN_BUILD_CONFIG', $null, 'Process')

    $selectEnv = & $NODE_BIN $ENGINE prebuild-select-env
    Log "prebuild select-env: $($selectEnv -join '; ')"
    Import-EnvLines $selectEnv

    $runtime = if ($env:CBCI_BUILD_RUNTIME) { $env:CBCI_BUILD_RUNTIME } else { 'node' }
    if ($runtime -eq 'electron' -and -not $env:CBCI_BUILD_ELECTRON_VERSION) {
        Die 'prebuild: runtime=electron requires CBCI_BUILD_ELECTRON_VERSION (set by the adapter per job)'
    }

    Assert-BuildPathFits $PROJECT_ROOT

    Log "building (npm run prebuild) runtime=$runtime version=$($env:CN_PREBUILD_RUNTIME_VERSION)"
    Invoke-Checked $NPM_BIN @('run', 'prebuild')

    # Ground-truthed Windows quirk: RelWithDebInfo (or anything but Debug) is forced to
    # the Release output folder - see file header.
    $buildConfig = if ($configuredBuildType -eq 'Debug') { 'Debug' } else { 'Release' }
    $built = "build/$buildConfig/couchbase_impl.node"
    if (-not (Test-Path $built)) {
        if (Test-Path "build/Release/couchbase_impl.node") {
            $built = "build/Release/couchbase_impl.node"
        } else {
            $found = Get-ChildItem -Path build -Filter 'couchbase_impl.node' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $built = $found.FullName }
        }
    }
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
    # The same components minus the version: unique per JOB, and stable across releases so
    # two builds of one version can be diffed. See tasks.sh's _build_info_unit.
    $unitKey = "$kind-v$abi-$nodePlatform-$nodeArch-$sslSuffix"

    # Set BEFORE the repair, not just for the record: the repair step needs it to decide
    # whether a missing .pdb is a broken split or a config that never emits one.
    # CN_BUILD_CONFIG was cleared above, so this is the only channel carrying it.
    $env:CBCI_BUILD_TYPE = $configuredBuildType

    Task-PrebuildRepair $built $filename
    # After the split, so the hashes recorded are the ones that ship.
    Write-BuildInfo $unitKey
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
        # Registry mode (release-verify): install the PUBLISHED package by name, so what is
        # exercised is what a consumer actually gets. The install types keep their meaning:
        # 'prebuild' lets npm resolve the optionalDependencies, '--omit=optional' withholds
        # them and forces the from-source fallback.
        if ($env:CBCI_PACKAGING_INDEX) {
            if (-not $env:CBCI_VERSION) { Die "validate: CBCI_VERSION required when CBCI_PACKAGING_INDEX is set" }
            $spec = "$($env:CBCI_VALIDATE_PACKAGE_NAME)@$($env:CBCI_VERSION)"
            if ($itype -eq 'prebuild') {
                Invoke-Checked $NPM_BIN @('install', '--save', $spec)
            } elseif ($itype -eq 'sdist') {
                Invoke-Checked $NPM_BIN @('install', '--save', '--omit=optional', $spec)
            } else {
                Die "validate: unknown install_type: $itype (prebuild|sdist)"
            }
            # Join-String is absent on PowerShell 5.1, so the listing is collapsed with -join.
            $listing = (& $NPM_BIN @('list', '--depth=1') 2>&1) -join "`n"
            Write-Host $listing
            # An --omit=optional install that still resolved a platform package would be
            # testing the prebuild path twice and reporting the source path as covered.
            if ($itype -eq 'sdist' -and $listing -match "@$($env:CBCI_VALIDATE_PACKAGE_NAME)/") {
                Die "validate: --omit=optional still pulled a platform package; the from-source path was not exercised"
            }
        } elseif ($itype -eq 'prebuild') {
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
        # LITERAL here-string (@' ... '@): nothing inside is expanded, so the JS may use $
        # and backticks freely. Mirrors tasks.sh's _validate_smoke_js - keep the two in step.
        # On failure it names the cause instead of leaving you with the SDK's own message,
        # which reports only what the loader WANTED: resolvePrebuild() throws "Could not find
        # native build for platform=..., arch=..., runtime=..., sslType=..." after swallowing
        # the real error, and never says what was actually present. A failed validate never
        # reaches archiving, so this in-process look is the only one anyone gets.
        $smokeScript = @'
const fs = require('fs');
const path = require('path');

function dumpAddons() {
  const facts = [`node ${process.versions.node}`, `Node-API ${process.versions.napi}`,
    `${process.platform}/${process.arch}`, `ssl=${process.env.CBCI_VALIDATE_SSL || '?'}`];
  console.error(`[validate] load failed on ${facts.join(', ')}`);

  const found = [];
  const walk = (dir) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.node')) found.push(p);
    }
  };
  walk('node_modules');

  if (!found.length) {
    console.error('[validate]   shipped: NO .node addon anywhere under node_modules/ '
      + '(the prebuild never landed, or a source build was expected and did not produce one)');
    return;
  }
  // The loader matches on the FILENAME's tokens, so the name is the diagnosis:
  //   couchbase-v<pkg>-<runtime>-v<abi>-<platform>-<arch>-<ssl>.node
  // A mismatch in any one of them (openssl3 vs boringssl, arch) presents as "no native
  // build found", identical to nothing having shipped at all.
  for (const p of found) console.error(`[validate]   shipped: ${p}`);
}

const mod = process.env.CBCI_VALIDATE_IMPORT;
try {
  const pkg = require(mod);
  if (typeof pkg.connect !== 'function') {
    console.error('[validate] couchbase module missing connect()');
    process.exit(1);
  }
  console.log(`[validate] required ${mod} OK, connect() present`);
} catch (err) {
  dumpAddons();
  throw err;
}
'@
        & $NODE_BIN -e $smokeScript
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

    # Registry mode installs by name from the index, so there is no local artifact to find.
    $sdistPath = ''
    if (-not $env:CBCI_PACKAGING_INDEX) {
        $sdistTgz = Get-ChildItem (Join-Path $PROJECT_ROOT '*.tgz') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sdistTgz) { Die "validate: no *.tgz found under $PROJECT_ROOT (build sdist first?)" }
        $sdistPath = $sdistTgz.FullName
    } else {
        Log "validate: registry mode, index=$($env:CBCI_PACKAGING_INDEX) version=$($env:CBCI_VERSION)"
    }

    foreach ($itype in ($env:CBCI_VALIDATE_INSTALL_TYPES -split ',')) {
        Invoke-ValidateOne $itype $sdistPath
        Log "validate: $itype OK"
    }
    Log "validate: all install types passed ($env:CBCI_VALIDATE_INSTALL_TYPES)"
}

# --- test: NOTHING IS COMPILED HERE - `test` consumes the prebuild the `prebuild` stage
# already produced, same contract as `validate`. See tasks.sh's task_test header for the
# full rationale; the mechanism is identical:
# .npmrc couchbase_local_prebuilds -> `npm ci --ignore-scripts` -> `npm run install`,
# with a post-condition check because scripts/install.js SILENTLY falls back to
# prebuilds.buildBinary() when it cannot resolve a prebuild.
function Task-Test {
    Set-Location $PROJECT_ROOT

    if ($env:CBCI_TEST_HOST -and -not $env:CNCSTR) {
        $env:CNCSTR = "couchbase://$env:CBCI_TEST_HOST"
        if (-not $env:CNUSER) { $env:CNUSER = 'Administrator' }
        if (-not $env:CNPASS) { $env:CNPASS = 'password' }
    }

    if ($env:CBCI_TEST_CLUSTER -ne 'realserver' -and -not $env:CNCSTR) {
        $requiresJava = (& $NODE_BIN $ENGINE requires-java).Trim()
        if ($requiresJava -eq 'true') {
            if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
                Die "test: ci-config requires java (CouchbaseMock.jar backend) but 'java' is not on PATH"
            }
        }
    }

    $prebuildDir = Join-Path $PROJECT_ROOT 'prebuilds'
    if (-not (Test-Path $prebuildDir)) {
        Die "test: no prebuilds/ under $PROJECT_ROOT - the prebuild stage must run (or its artifact be copied) first"
    }
    # Defense-in-depth: remove non-Win32 prebuilds if multiple platform artifacts were copied
    Get-ChildItem $prebuildDir -Filter *.node -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notmatch '-win32-') {
            Log "test: removing non-Windows prebuild $($_.Name) from prebuilds/"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-ChildItem $prebuildDir -Filter *.node -ErrorAction SilentlyContinue)) {
        Die 'test: prebuilds/ exists but holds no *.node - nothing for scripts/install.js to resolve'
    }
    Log "test: using local prebuilds from $prebuildDir (no compilation)"
    # npm re-exports .npmrc keys to lifecycle scripts as npm_config_* - which is the name
    # scripts/install.js's getLocalPrebuild() reads. Must be set for `npm run install`.
    # Replace rather than append: the vendor may retry `test` in the SAME workspace, and a
    # blind append would stack a duplicate key every attempt.
    # NOTE: @(...) around BOTH the assignment and the concatenation is load-bearing.
    # PowerShell unwraps a single-element array on assignment, so a one-line .npmrc would
    # make $kept a plain String - and `$kept + "..."` would then be STRING concatenation,
    # writing one corrupt line (merging any pre-existing key, e.g. registry=, into ours).
    $npmrc = Join-Path $PROJECT_ROOT '.npmrc'
    $kept = @()
    if (Test-Path $npmrc) {
        $kept = @(Get-Content $npmrc | Where-Object { $_ -notmatch '^couchbase_local_prebuilds=' })
    }
    Set-Content -Path $npmrc -Value (@($kept) + "couchbase_local_prebuilds=$prebuildDir")

    Log 'installing dependencies (npm ci --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('ci', '--ignore-scripts')

    Log 'installing mocha-multi-reporters for test reporting'
    try { & $NPM_BIN install --no-save mocha-multi-reporters } catch { Log 'WARNING: failed to install mocha-multi-reporters' }

    Log 'installing the prebuilt binary (npm run install)'
    Invoke-Checked $NPM_BIN @('run', 'install')
    $installed = Get-ChildItem (Join-Path $PROJECT_ROOT 'build\Release') -Filter *.node -ErrorAction SilentlyContinue
    if (-not $installed) {
        Die "test: no *.node in build\Release after 'npm run install' - the prebuild was not resolved"
    }
    Log 'test: prebuild installed:'; $installed | Format-Table -AutoSize

    if ($env:CBCI_JUNIT_DIR) {
        New-Item -ItemType Directory -Force -Path $env:CBCI_JUNIT_DIR | Out-Null
    }

    $cmds = & $NODE_BIN $ENGINE test-cmds
    if (-not $cmds) { Die 'test: no test commands configured' }

    foreach ($cmd in $cmds) {
        $runCmd = $cmd
        if (($cmd -like '*npm run test*' -or $cmd -like '*mocha*') -and $cmd -notlike '*-R*' -and $cmd -notlike '*--reporter*') {
            $runCmd = "$cmd -- -R mocha-multi-reporters"
        }
        Log "test: run: $runCmd"
        Invoke-Expression $runCmd
        if ($LASTEXITCODE -ne 0) { Die "test: mocha failed (rc=$LASTEXITCODE)" }
    }

    if ((Test-Path 'xunit.xml') -and $env:CBCI_JUNIT_DIR) {
        Move-Item 'xunit.xml' (Join-Path $env:CBCI_JUNIT_DIR 'xunit.xml') -Force
        Log "test: moved xunit.xml -> $env:CBCI_JUNIT_DIR/xunit.xml"
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
        $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        & $psExe -ExecutionPolicy Bypass -File $PSCommandPath @argv 2>&1 | Tee-Object -FilePath $env:CBCI_LOG_FILE
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
