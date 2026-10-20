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
# A cell whose Node is not the one it asked for still runs, but its results are for the
# Node it got. See tasks.sh's warn_node_mismatch.
function Warn-NodeMismatch([string]$stage) {
    $want = $env:CBCI_TEST_VERSION
    if (-not $want) { return }
    $have = (& $NODE_BIN -p 'process.versions.node').Trim()
    if ($have -eq $want) { return }
    $where = (Get-Command $NODE_BIN -ErrorAction SilentlyContinue).Source
    if (-not $where) { $where = $NODE_BIN }
    Log "WARNING: ${stage}: this cell asked for Node $want but is running Node $have ($where); its results are for $have"
}
function Pkg-Version() {
    $pkgPath = (Join-Path $PROJECT_ROOT 'package.json') -replace '\\', '/'
    (& $NODE_BIN -p "require('$pkgPath').version").Trim()
}

function Clear-NodeModules {
    # Clear node_modules before an npm install/ci writes a new one into this workspace.
    #
    # `npm ci` clears the directory itself, but it does that inside the same reify pass
    # that extracts the new tree. In a REUSED workspace where anything still holds a
    # handle (the search indexer, AV, or a stray node.exe from a previous build) a
    # directory removal fails while the extraction into it goes ahead, and npm reports the
    # result as a flood of `npm warn tar ENOENT: Cannot cd into node_modules\<pkg>` with
    # packages missing from the installed tree. Clearing it first means npm only ever
    # extracts onto empty ground, and a tree left by a different commit can never survive
    # into this build.
    $nm = Join-Path $PROJECT_ROOT 'node_modules'
    if (-not (Test-Path -LiteralPath $nm)) { return }
    Log 'clearing node_modules left in this workspace'
    Remove-Item -LiteralPath $nm -Recurse -Force -ErrorAction SilentlyContinue

    if ((Test-Path -LiteralPath $nm) -and (Get-Command robocopy -ErrorAction SilentlyContinue)) {
        # Remove-Item gives up at MAX_PATH, which a nested node_modules reaches on its own
        # in a workspace path that is already long. robocopy speaks the long-path API, so
        # mirroring an EMPTY directory over the tree empties what Remove-Item could not
        # reach. Its exit code is a bitmask where anything under 8 is success, and it is
        # not the stage result either way, so it is cleared rather than checked.
        $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('cbci-empty-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & robocopy $empty $nm /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        $global:LASTEXITCODE = 0
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $nm -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Best effort by design: if something still holds the tree we are no worse off than
    # npm's own removal, so warn and let the install proceed rather than failing here.
    if (Test-Path -LiteralPath $nm) {
        Log 'WARNING: node_modules could not be fully removed; expect npm tar ENOENT warnings below'
    }
}

# Every path the packed sdist must put on disk before `npm run prebuild` can configure.
#
# couchnode's CMakeLists.txt calls add_subdirectory(deps/couchbase-cxx-client)
# UNCONDITIONALLY, and this stage never clones or fetches the C++ core: it exists here
# only as a member of the tarball (package.json's `files` ships
# deps/couchbase-cxx-client/{CMakeLists.txt,cmake,core,couchbase,third_party} plus the
# baked deps/couchbase-cxx-cache). So a partial unpack does not fail at the unpack. It
# fails a minute later, after npm install, inside cmake-js as
#     add_subdirectory given source "deps/couchbase-cxx-client" which is not an
#     existing directory
# which reads as a broken package or a broken CMakeLists rather than a broken extraction.
$SDIST_REQUIRED = @(
    'package.json',
    'CMakeLists.txt',
    'scripts/buildPrebuild.js',
    'src',
    'deps/couchbase-cxx-client/CMakeLists.txt',
    'deps/couchbase-cxx-client/core',
    'deps/couchbase-cxx-client/couchbase',
    'deps/couchbase-cxx-cache/cpm'
)

function Get-MissingSdistPaths([string]$root) {
    return @($SDIST_REQUIRED | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
}

function Get-TarExe {
    # System32\tar.exe is Windows native bsdtar (Windows 10 / Server 2019+).
    # Prefer it explicitly over MSYS/Git tar to avoid MSYS gzip/remote-host path issues.
    #
    # Sysnative first, because under WOW64 (a 32-bit agent JVM -> 32-bit cmd -> 32-bit
    # powershell) the System32 probe below is redirected to SysWOW64, which carries no
    # tar.exe. The native bsdtar then looks absent on an agent that has it and the search
    # silently falls through to whatever tar.exe PATH fronts, which is a DIFFERENT
    # extractor on a fleet where Git for Windows is installed.
    if ($env:SystemRoot) {
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            $nativeTar = Join-Path $env:SystemRoot 'Sysnative\tar.exe'
            if (Test-Path $nativeTar) { return $nativeTar }
        }
        $sys32Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (Test-Path $sys32Tar) { return $sys32Tar }
    }
    # Resolved to a full path, never the bare name: the log has to name the binary that
    # actually ran, since which one PATH fronts varies across the fleet.
    foreach ($name in @('tar.exe', 'tar')) {
        $onPath = Get-Command $name -ErrorAction SilentlyContinue
        if ($onPath -and $onPath.Source) { return $onPath.Source }
    }
    $gitTar = 'C:\Program Files\Git\usr\bin\tar.exe'
    if (Test-Path $gitTar) { return $gitTar }
    $gitTarX86 = 'C:\Program Files (x86)\Git\usr\bin\tar.exe'
    if (Test-Path $gitTarX86) { return $gitTarX86 }
    return $null
}

function Unpack-Tarball([string]$tgzPath) {
    $dest = (Get-Location).Path
    $tarBin = Get-TarExe
    if ($tarBin) {
        # MSYS/Git tar shells out to gzip.exe, which only resolves with Git\usr\bin on
        # PATH. Prepended AFTER the search above so it can never decide WHICH tar wins.
        foreach ($gitUsrBin in @('C:\Program Files\Git\usr\bin', 'C:\Program Files (x86)\Git\usr\bin')) {
            if ((Test-Path $gitUsrBin) -and (($env:PATH -split ';') -notcontains $gitUsrBin)) {
                $env:PATH = "$gitUsrBin;$env:PATH"
            }
        }

        $relPath = Resolve-Path -Relative $tgzPath -ErrorAction SilentlyContinue
        $tarFile = if ($relPath) { $relPath } else { $tgzPath }
        Log "unpacking $tarFile using $tarBin"
        & $tarBin --force-local -xzf $tarFile --strip-components=1
        $tarExit = $LASTEXITCODE
        $missing = @(Get-MissingSdistPaths $dest)
        if ($tarExit -eq 0 -and $missing.Count -eq 0) { return }
        if ($tarExit -ne 0) {
            Log "WARNING: $tarBin exited $tarExit; trying node fallback"
        } else {
            # An exit code of 0 is not evidence the tree landed: ground truth from
            # windows-sdk-build-04 is a tar that reported success while
            # deps/couchbase-cxx-client never appeared. Re-extract with node's own tar
            # rather than trust it.
            Log ("WARNING: $tarBin exited 0 but left an incomplete tree under ${dest} " +
                 "(missing: $($missing -join ', ')); trying node fallback")
            # What DID land, so the next occurrence says whether the extractor dropped part
            # of the tarball or something emptied the workspace underneath it.
            Log "  top level after unpack: $(((Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Name) -join ', ')"
        }
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

    $missing = @(Get-MissingSdistPaths $dest)
    if ($missing.Count) {
        Die ("unpacked $tgzPath but the tree under ${dest} is STILL incomplete: missing " +
             "$($missing -join ', '). Every platform builds from this one tarball, so " +
             "suspect the workspace before the tarball: another process removing files " +
             "mid-stage, or a full disk.")
    }
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
    Clear-NodeModules
    Log 'installing dependencies (npm ci --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('ci', '--ignore-scripts')
    Log 'running eslint'
    Invoke-Checked $NPM_BIN @('run', 'lint')
}

function Task-Sdist {
    Set-Location $PROJECT_ROOT

    Clear-NodeModules
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
    Clear-NodeModules
    # --legacy-peer-deps: see tasks.sh's task_prebuild (lock-file-less npm crashes on vitest's peer set).
    Log 'prebuild: restoring devDependencies (npm install --ignore-scripts --legacy-peer-deps)'
    Invoke-Checked $NPM_BIN @('install', '--ignore-scripts', '--legacy-peer-deps')

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

# Env vars one validate run has set, with the values they replaced. tasks.sh gets this for
# free from its subshell; here Restore-ScopedEnv puts them back when the run ends.
$script:ScopedEnvSaved = @{}

function Set-ScopedEnv([string]$name, [string]$value) {
    if (-not $script:ScopedEnvSaved.ContainsKey($name)) {
        $script:ScopedEnvSaved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
}

function Restore-ScopedEnv {
    # $null removes the variable, which is the right restore for one that was unset.
    foreach ($name in $script:ScopedEnvSaved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:ScopedEnvSaved[$name], 'Process')
    }
    $script:ScopedEnvSaved = @{}
}

# Put an npm-installed yarn on PATH for this install only. It lives under the run's temp
# dir, so nothing global changes. Not corepack: Node 25+ ships without it, and on Windows
# agents its install step fails to rename into COREPACK_HOME.
function Initialize-ValidateYarn([string]$root) {
    $pmDir = Join-Path $root 'pm'
    Invoke-Checked $NPM_BIN @('install', '--prefix', $pmDir, '--registry', $env:CBCI_VALIDATE_PM_REGISTRY,
                              '--no-save', '--no-package-lock', '--no-audit', '--no-fund',
                              $env:CBCI_VALIDATE_PM_SPEC)
    $bin = Join-Path $pmDir (Join-Path 'node_modules' '.bin')
    Set-ScopedEnv 'PATH' "$bin$([System.IO.Path]::PathSeparator)$($env:PATH)"
    $yarnVersion = (& yarn --version) -join ''
    Log "validate: yarn $yarnVersion ($($env:CBCI_VALIDATE_PM_SPEC)) via npm"
}

# Registry-mode install with the selected package manager. 'prebuild' lets it resolve the
# optionalDependencies platform package; 'sdist' (npm only) withholds them and forces the
# from-source fallback. Mirrors tasks.sh's _validate_registry_install.
function Invoke-ValidateRegistryInstall([string]$itype, [string]$root) {
    if (-not $env:CBCI_VERSION) { Die "validate: CBCI_VERSION required when CBCI_PACKAGING_INDEX is set" }
    $spec = "$($env:CBCI_VALIDATE_PACKAGE_NAME)@$($env:CBCI_VERSION)"
    $pm = $env:CBCI_VALIDATE_PACKAGE_MANAGER
    $ignoreScripts = $env:CBCI_VALIDATE_IGNORE_SCRIPTS -eq 'true'
    Log "validate: $pm install $spec from $($env:CBCI_VALIDATE_REGISTRY) (ignore_scripts=$($env:CBCI_VALIDATE_IGNORE_SCRIPTS))"
    # npm and yarn classic both read npm_config_registry; it outranks any ~/.npmrc.
    Set-ScopedEnv 'npm_config_registry' $env:CBCI_VALIDATE_REGISTRY
    switch ($pm) {
        'npm' {
            # [string[]] up front: an @() built in an if/else can unwrap to a String, and
            # += would then concatenate instead of append.
            [string[]]$npmArgs = @('install', '--save')
            if ($itype -eq 'sdist') { $npmArgs += '--omit=optional' }
            if ($ignoreScripts) { $npmArgs += '--ignore-scripts' }
            Invoke-Checked $NPM_BIN ($npmArgs + $spec)
            # Join-String is absent on PowerShell 5.1, so the listing is collapsed with -join.
            $listing = (& $NPM_BIN @('list', '--depth=1') 2>&1) -join "`n"
            Write-Host $listing
            # An --omit=optional install that still resolved a platform package would be
            # testing the prebuild path twice and reporting the source path as covered.
            # Checked on disk: npm list names every withheld optional as UNMET.
            $scopeDir = Join-Path 'node_modules' "@$($env:CBCI_VALIDATE_PACKAGE_NAME)"
            if ($itype -eq 'sdist' -and @(Get-ChildItem -Path $scopeDir -Directory -ErrorAction SilentlyContinue).Count -gt 0) {
                Die "validate: --omit=optional still pulled a platform package; the from-source path was not exercised"
            }
        }
        'yarn' {
            Initialize-ValidateYarn $root
            # Berry treats the nearest lockfile as the project root.
            New-Item -ItemType File -Force -Path 'yarn.lock' | Out-Null
            # YARN_* env outranks every .yarnrc.yml, including a stale one in the agent's home.
            Set-ScopedEnv 'YARN_NPM_REGISTRY_SERVER' $env:CBCI_VALIDATE_REGISTRY
            Set-ScopedEnv 'YARN_NODE_LINKER' $env:CBCI_VALIDATE_YARN_LINKER
            if ($env:CBCI_VALIDATE_REGISTRY_HTTP_HOST) {
                Set-ScopedEnv 'YARN_UNSAFE_HTTP_WHITELIST' $env:CBCI_VALIDATE_REGISTRY_HTTP_HOST
            }
            # Berry has no --ignore-scripts flag; enableScripts is the equivalent.
            if ($ignoreScripts) { Set-ScopedEnv 'YARN_ENABLE_SCRIPTS' 'false' }
            Log "validate: yarn nodeLinker=$($env:CBCI_VALIDATE_YARN_LINKER)"
            Invoke-Checked 'yarn' @('add', $spec)
            & yarn info $env:CBCI_VALIDATE_PACKAGE_NAME | Out-Host
        }
        'yarn-classic' {
            Initialize-ValidateYarn $root
            New-Item -ItemType File -Force -Path 'yarn.lock' | Out-Null
            [string[]]$yarnArgs = @('add', $spec, '--registry', $env:CBCI_VALIDATE_REGISTRY)
            # Classic fails outright on an engines mismatch (cmake-js's floor) where npm
            # and Berry only warn.
            if ($env:CBCI_VALIDATE_IGNORE_ENGINES -eq 'true') { $yarnArgs += '--ignore-engines' }
            if ($ignoreScripts) { $yarnArgs += '--ignore-scripts' }
            Invoke-Checked 'yarn' $yarnArgs
            & yarn list --depth=1 | Out-Host
        }
        default { Die "validate: unknown package manager: $pm (npm|yarn|yarn-classic)" }
    }
}

function Invoke-ValidateOne([string]$itype, [string]$sdistTgz) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    $proj = Join-Path $root 'proj'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    Log "validate: install_type=$itype package_manager=$($env:CBCI_VALIDATE_PACKAGE_MANAGER) in $root"
    Push-Location $proj
    try {
        Invoke-Checked $NPM_BIN @('init', '-y') | Out-Null
        if ($env:CBCI_PACKAGING_INDEX) {
            Invoke-ValidateRegistryInstall $itype $root
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

        # Before the smoke, so the smoke proves the pruned install still loads. npm only:
        # `npm explore` needs a node_modules tree, which Yarn PnP never creates.
        if ($env:CBCI_VALIDATE_PRUNE -eq 'true' -and $env:CBCI_VALIDATE_PACKAGE_MANAGER -eq 'npm') {
            Log 'validate: help-prune'
            Invoke-Checked $NPM_BIN @('explore', $env:CBCI_VALIDATE_PACKAGE_NAME, '--', 'npm', 'run', 'help-prune')
        } elseif ($env:CBCI_VALIDATE_PRUNE -eq 'true') {
            Log "validate: help-prune is npm-only; skipped for $($env:CBCI_VALIDATE_PACKAGE_MANAGER)"
        }

        # Staged as a file in the install dir: under Yarn PnP the script has to sit inside the
        # project for `yarn node` to resolve the package for it. A file, never `node -e`:
        # PowerShell 5.1 does not escape the double quotes inside a native argument, so the
        # first `"` in the JS would end it. Captured and rewritten rather than redirected
        # with `>`, which writes UTF-16 on 5.1.
        $smokeJs = & $NODE_BIN $ENGINE validate-smoke
        if ($LASTEXITCODE -ne 0) { Die 'validate: failed to emit the smoke script' }
        $smoke = Join-Path $proj '__cbci_validate_smoke.cjs'
        [System.IO.File]::WriteAllText($smoke, ($smokeJs -join "`n"), (New-Object System.Text.UTF8Encoding $false))
        if ($env:CBCI_VALIDATE_PACKAGE_MANAGER -eq 'yarn') {
            & yarn node $smoke
        } else {
            & $NODE_BIN $smoke
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            # Hex as well: a teardown fault is an NTSTATUS (0xC0000005, 0xC0000409, ...) that is
            # unreadable in decimal, and it is what separates a crash from a JS-level exit.
            $hex = "0x{0:X8}" -f ($exitCode -band 0xFFFFFFFF)
            Die "validate: smoke check failed for $itype (node exited $exitCode / $hex)"
        }
    } finally {
        Pop-Location
        Restore-ScopedEnv
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

function Task-Validate {
    Set-Location $PROJECT_ROOT
    Warn-NodeMismatch 'validate'
    $out = & $NODE_BIN $ENGINE validate-env
    if ($LASTEXITCODE -ne 0) { Die 'failed to resolve validate-env' }
    Import-EnvPairs $out
    if ($env:CBCI_INSTALL_TYPE) { $env:CBCI_VALIDATE_INSTALL_TYPES = $env:CBCI_INSTALL_TYPE }
    # Shared by every validate run on this agent, so the GoCAVES binary downloads once.
    $env:CBCI_VALIDATE_CAVES_DIR = Join-Path $SCRIPT_DIR '.gocaves'
    $pm = $env:CBCI_VALIDATE_PACKAGE_MANAGER
    $ignoreScripts = $env:CBCI_VALIDATE_IGNORE_SCRIPTS -eq 'true'

    # Registry mode installs by name from the index, so there is no local artifact to find.
    $sdistPath = ''
    if (-not $env:CBCI_PACKAGING_INDEX) {
        # A local artifact is installed by path with npm; the other knobs only mean
        # something against a registry.
        if ($pm -ne 'npm') { Die "validate: package manager $pm needs registry mode (CBCI_PACKAGING_INDEX)" }
        if ($ignoreScripts) { Die 'validate: CBCI_VALIDATE_IGNORE_SCRIPTS needs registry mode; a local prebuild only installs through scripts/install.js' }
        $sdistTgz = Get-ChildItem (Join-Path $PROJECT_ROOT '*.tgz') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $sdistTgz) { Die "validate: no *.tgz found under $PROJECT_ROOT (build sdist first?)" }
        $sdistPath = $sdistTgz.FullName
    } else {
        Log "validate: registry mode, index=$($env:CBCI_PACKAGING_INDEX) version=$($env:CBCI_VERSION)"
    }

    foreach ($itype in ($env:CBCI_VALIDATE_INSTALL_TYPES -split ',')) {
        if ($itype -eq 'sdist') {
            # sdist means --omit=optional, which only npm has.
            if ($pm -ne 'npm') { Die "validate: install_type sdist is npm-only (got $pm)" }
            # The from-source fallback IS the install script, so this would fail by design.
            if ($ignoreScripts) { Die 'validate: install_type sdist cannot run with CBCI_VALIDATE_IGNORE_SCRIPTS (the source build is the install script)' }
        }
        Invoke-ValidateOne $itype $sdistPath
        Log "validate: $itype OK"
    }
    Log "validate: all install types passed ($($env:CBCI_VALIDATE_INSTALL_TYPES), $pm)"
}

# --- test: NOTHING IS COMPILED HERE - `test` consumes the prebuild the `prebuild` stage
# already produced, same contract as `validate`. See tasks.sh's task_test header for the
# full rationale; the mechanism is identical:
# .npmrc couchbase_local_prebuilds -> `npm ci --ignore-scripts` -> `npm run install`,
# with a post-condition check because scripts/install.js SILENTLY falls back to
# prebuilds.buildBinary() when it cannot resolve a prebuild.
function Task-Test {
    Set-Location $PROJECT_ROOT
    Warn-NodeMismatch 'test'

    if ($env:CBCI_TEST_HOST -and -not $env:CNCSTR) {
        $env:CNCSTR = "couchbase://$env:CBCI_TEST_HOST"
        if (-not $env:CNUSER) { $env:CNUSER = 'Administrator' }
        if (-not $env:CNPASS) { $env:CNPASS = 'password' }
    }

    # See tasks.sh's task_test: the tier travels as an env var so it reaches every platform.
    if (-not $env:CNTIER) {
        $tier = (& $NODE_BIN $ENGINE test-tier)
        if ($LASTEXITCODE -ne 0) { Die 'test: could not resolve the test tier' }
        $tier = "$tier".Trim()
        if ($tier) {
            $env:CNTIER = $tier
            Log "test: CNTIER=$($env:CNTIER)"
        }
    }

    # test/harness.js treats CNCSTR and CNCVER as a pair: either one without the other is a
    # fatal assertion at import time. CBCI_CLUSTER_VERSION is the x.y.z the provisioned
    # cluster reports, supplied by whichever CI entity allocated it. Keyed on CNCSTR, since
    # the mock path must leave CNCVER unset and harness.js decides mock-vs-real on CNCSTR
    # alone. See tasks.sh's task_test header.
    if ($env:CNCSTR -and -not $env:CNCVER) {
        if ($env:CBCI_CLUSTER_VERSION -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
            $env:CNCVER = $env:CBCI_CLUSTER_VERSION
            Log "test: CNCVER=$($env:CNCVER)"
        } else {
            Log "WARNING: test: CNCSTR is set but CBCI_CLUSTER_VERSION='$($env:CBCI_CLUSTER_VERSION)' is not an x.y.z version, so CNCVER stays unset"
        }
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

    Clear-NodeModules
    Log 'installing dependencies (npm ci --ignore-scripts)'
    Invoke-Checked $NPM_BIN @('ci', '--ignore-scripts')

    $junit = (& $NODE_BIN $ENGINE test-junit)
    if ($LASTEXITCODE -ne 0 -or -not $junit) { Die 'test: could not resolve the test runner' }
    $junit = "$junit".Trim()
    $junitEnv = (& $NODE_BIN $ENGINE test-junit-env)
    if ($LASTEXITCODE -ne 0) { Die 'test: could not resolve the test runner' }
    $junitEnv = "$junitEnv".Trim()

    # --ignore-scripts is load-bearing here, not tidiness. Without it npm reifies the whole
    # tree and runs the lifecycle scripts the `npm ci --ignore-scripts` above deliberately
    # skipped, which builds every native devDependency from source inside a stage that
    # compiles nothing. The reporter itself is pure JS and carries no install script.
    if ($junit -eq 'mocha-multi-reporters') {
        Log 'installing mocha-multi-reporters for test reporting'
        try { & $NPM_BIN install --no-save --ignore-scripts mocha-multi-reporters } catch { Log 'WARNING: failed to install mocha-multi-reporters' }
    }

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

    # An xunit.xml left by an EARLIER build in this reused workspace would be published as
    # this build's results the moment the reporter fails to load: green, and someone else's
    # numbers. Clear it first so the post-condition below can only pass on a file this run
    # wrote.
    Remove-Item 'xunit.xml' -Force -ErrorAction SilentlyContinue

    # Absolute, because the suite resolves a relative path against its own config root.
    if ($junitEnv) {
        $xunitPath = Join-Path (Get-Location).Path 'xunit.xml'
        Set-Item -Path "env:$junitEnv" -Value $xunitPath
        Log "test: $junitEnv=$xunitPath"
    }

    # The text match still applies to mocha so a CBCI_TEST_COMMAND override that is not an
    # npm/mocha command (or names its own reporter) is left alone.
    $expectXunit = ($junit -eq 'inline')
    $rc = 0
    foreach ($cmd in $cmds) {
        $runCmd = $cmd
        if ($junit -eq 'mocha-multi-reporters' -and ($cmd -like '*npm run test*' -or $cmd -like '*mocha*') -and $cmd -notlike '*-R*' -and $cmd -notlike '*--reporter*') {
            # The QUOTES around -- are load-bearing. PowerShell reads a bare `--` as its own
            # end-of-parameters token and drops it before the callee sees it, and `npm` here
            # resolves through PowerShell's command discovery, which on some agents finds
            # npm's npm.ps1 shim rather than npm.cmd. The separator then never reaches npm,
            # npm parses `-R` as one of its own flags and discards it, and forwards only the
            # reporter NAME, which mocha reads as a spec glob ("Cannot find any files matching
            # pattern"). The suite still runs green under the default reporter and writes no
            # xunit.xml. Quoting makes it a plain string argument, immune to either shim.
            $runCmd = "$cmd '--' -R mocha-multi-reporters"
            $expectXunit = $true
        }
        Log "test: run: $runCmd"
        Invoke-Expression $runCmd
        if ($LASTEXITCODE -ne 0) { $rc = $LASTEXITCODE }
    }

    # Verified, not trusted. A reporter that never loaded leaves a passing suite and nothing
    # to publish, which is indistinguishable from success everywhere except here.
    if ($rc -eq 0 -and $expectXunit -and -not (Test-Path 'xunit.xml')) {
        $hint = 'check how the reporter argument survived in the run line above'
        if ($junitEnv) { $hint = "check that the suite's config still reads $junitEnv" }
        Die "test: the suite passed but wrote no xunit.xml (junit=$junit), so its junit reporter never ran; $hint"
    }
    if ((Test-Path 'xunit.xml') -and $env:CBCI_JUNIT_DIR) {
        Move-Item 'xunit.xml' (Join-Path $env:CBCI_JUNIT_DIR 'xunit.xml') -Force
        Log "test: moved xunit.xml -> $env:CBCI_JUNIT_DIR/xunit.xml"
    }

    # Only after the move: a failing suite's results are the ones worth publishing.
    if ($rc -ne 0) { Die "test: suite failed (rc=$rc)" }
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
