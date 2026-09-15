#!/usr/bin/env pwsh
#
# windows-toolchain-diag.ps1 - dump the MSVC / Windows SDK layout an agent ACTUALLY has.
#
# Two ways in:
#   1. The pipeline fetches this by name and runs it whenever it can find no Visual Studio it
#      can build with, or the one it picked fails, and on demand via its WINDOWS_TOOLCHAIN_DIAG
#      parameter. Arguments arrive as CBCI_DIAG_* environment variables so the caller needs no
#      extra quoting.
#   2. By hand on the agent itself, with no arguments:  .\windows-toolchain-diag.ps1
#
# Deliberately NOT part of the bootstrap manifest: it is fetched only once something has
# already gone wrong, so a normal build never pays for it and it needs no pinned sha256.
#
# Read-only and best-effort throughout (SilentlyContinue, always exit 0): the caller is on its
# way to reporting the real failure and this must never replace or pre-empt that.

[CmdletBinding()]
param(
    # Why the dump was taken. Echoed at the top so a console log says which guard fired.
    [string]$Context = $env:CBCI_DIAG_CONTEXT,

    # The vcvarsall.bat the caller settled on. Reported PRESENT/MISSING by full path, since
    # `call` on a missing one prints "The system cannot find the path specified." and names
    # neither the path nor the agent. A caller that passes nothing found no candidate at all.
    [string]$ExpectedVcvarsall = $env:CBCI_DIAG_VCVARSALL,

    # The CI's name for this machine, which is not always $env:COMPUTERNAME. Both are printed.
    [string]$NodeName = $env:CBCI_DIAG_NODE
)

$ErrorActionPreference = 'Continue'

if (-not $Context)   { $Context = 'run directly, no context given' }
if (-not $NodeName)  { $NodeName = if ($env:NODE_NAME) { $env:NODE_NAME } else { '(unknown)' } }
# Nothing from a PIPELINE caller means it searched and came up empty, which is the finding
# itself; inventing a path to report MISSING would dress that up as a bad guess. A HAND run
# with no arguments gets a plausible default instead, so "does this machine have a usable
# Visual Studio where one is normally installed" is answerable with no arguments at all.
$callerFoundNothing = $false
if (-not $ExpectedVcvarsall) {
    if ($env:CBCI_DIAG_CONTEXT) {
        $callerFoundNothing = $true
    } else {
        # Built by interpolation, not Join-Path: off Windows $env:ProgramFiles is unset and
        # Join-Path rejects both a null Path and a literal 'C:\' fallback (no such drive there).
        $pf = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $ExpectedVcvarsall = "$pf\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
    }
}

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "----- $title -----"
}

# Both roots, because edition and bitness vary per agent: VS2019 installs under Program Files
# (x86), VS2022 under Program Files.
$roots = @()
if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'Microsoft Visual Studio') }
if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio') }

Write-Host '===== CBCI windows toolchain diagnostics ====='
Write-Host "context   : $Context"
Write-Host "node      : $NodeName"
Write-Host "computer  : $env:COMPUTERNAME"
Write-Host "arch      : $env:PROCESSOR_ARCHITECTURE"
Write-Host "os        : $([System.Environment]::OSVersion.VersionString)"
Write-Host "powershell: $($PSVersionTable.PSVersion)"
Write-Host "cwd       : $((Get-Location).Path)"

Write-Section 'vcvarsall.bat the caller expects'
if ($callerFoundNothing) {
    Write-Host 'NONE - the caller found no installed Visual Studio matching what it asked for'
} elseif (Test-Path -LiteralPath $ExpectedVcvarsall) {
    Write-Host "PRESENT $ExpectedVcvarsall"
} else {
    Write-Host "MISSING $ExpectedVcvarsall"
}

Write-Section 'visual studio instances reported by vswhere'
$vswhere = $null
if (${env:ProgramFiles(x86)}) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
}
if ($vswhere -and (Test-Path -LiteralPath $vswhere)) {
    # -products * so Community/BuildTools instances show up, not just Professional/Enterprise.
    $raw = & $vswhere -all -prerelease -products * -format json 2>$null | Out-String
    $instances = @()
    if ($raw.Trim()) {
        try { $instances = @($raw | ConvertFrom-Json) } catch { Write-Host "could not parse vswhere json: $_" }
    }
    if ($instances.Count -eq 0) {
        Write-Host 'vswhere found NO installed instances'
    }
    foreach ($i in $instances) {
        Write-Host ''
        Write-Host ('  displayName      : ' + $i.displayName)
        Write-Host ('  installationPath : ' + $i.installationPath)
        Write-Host ('  version          : ' + $i.installationVersion)
        Write-Host ('  productId        : ' + $i.productId)
        $vc = Join-Path $i.installationPath 'VC\Auxiliary\Build\vcvarsall.bat'
        if (Test-Path -LiteralPath $vc) {
            Write-Host ('  vcvarsall        : ' + $vc)
        } else {
            # An instance without this has no C++ workload, so it cannot build the SDK even
            # though vswhere lists it.
            Write-Host '  vcvarsall        : NONE, no C++ build tools in this instance'
        }
        $tools = Join-Path $i.installationPath 'VC\Tools\MSVC'
        if (Test-Path -LiteralPath $tools) {
            $names = @(Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
            Write-Host ('  msvc toolsets    : ' + ($names -join ', '))
        }
    }
} else {
    Write-Host 'MISSING vswhere.exe, no Visual Studio Installer on this agent'
}

Write-Section 'visual studio install roots on disk'
foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root) {
        Write-Host "${root}:"
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host ('  ' + $_.Name) }
    } else {
        Write-Host "MISSING $root"
    }
}

Write-Section 'vcvarsall.bat found under those roots'
# Walked as <root>\<year>\<edition> rather than recursed: a full recursion of a VS tree is
# hundreds of thousands of files. This is where every VS2017+ layout puts it, and it catches an
# edition (Community, BuildTools) the caller is not asking for.
$found = @()
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($year in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        foreach ($ed in @(Get-ChildItem -LiteralPath $year.FullName -Directory -ErrorAction SilentlyContinue)) {
            $vc = Join-Path $ed.FullName 'VC\Auxiliary\Build\vcvarsall.bat'
            if (Test-Path -LiteralPath $vc) { $found += $vc }
        }
        $legacy = Join-Path $year.FullName 'VC\vcvarsall.bat'
        if (Test-Path -LiteralPath $legacy) { $found += $legacy }
    }
}
if ($found.Count -eq 0) {
    Write-Host 'NONE, this agent has no C++ build tools under either Visual Studio root'
} else {
    $found | ForEach-Object { Write-Host $_ }
}

Write-Section 'windows sdk versions installed'
$sdkInc = $null
if (${env:ProgramFiles(x86)}) {
    $sdkInc = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
}
if ($sdkInc -and (Test-Path -LiteralPath $sdkInc)) {
    # stdalign.h marks the C11 ucrt headers. They ship in the Windows SDK, not in the MSVC
    # toolset, so the SDK is what decides whether boringssl compiles however new the installed
    # Visual Studio is. The first SDK carrying them is 10.0.20348.0.
    Get-ChildItem -LiteralPath $sdkInc -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $note = 'NO C11 ucrt headers (no stdalign.h), cannot build boringssl'
            if (Test-Path -LiteralPath (Join-Path $_.FullName 'ucrt\stdalign.h')) {
                $note = 'has the C11 ucrt headers'
            }
            Write-Host ('  ' + $_.Name + '  ' + $note)
        }
} else {
    Write-Host "MISSING $sdkInc"
}

Write-Section 'MSVC-related environment already set on this agent'
# Empty is NORMAL: the build does not run inside a developer prompt, it sources vcvarsall
# itself. A non-empty value means something else on the agent set it first.
Get-ChildItem env: |
    Where-Object { $_.Name -match '^(VSINSTALLDIR|VCINSTALLDIR|VCToolsVersion|VCToolsInstallDir|VSCMD_VER|WindowsSdkDir|WindowsSDKVersion)$' } |
    ForEach-Object { Write-Host ('  ' + $_.Name + '=' + $_.Value) }

Write-Section 'compiler on PATH'
$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if ($cl) { Write-Host $cl.Source } else { Write-Host 'cl.exe not on PATH, which is expected before vcvarsall runs' }

Write-Host ''
Write-Host '===== end CBCI windows toolchain diagnostics ====='
exit 0
