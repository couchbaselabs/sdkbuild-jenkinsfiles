#!/usr/bin/env pwsh
#
# tasks.ps1 — Windows task executors for the Couchbase Python SDK (PowerShell Core).
#
# Mirror of tasks.sh for Windows. pwsh is cross-platform, so this is not strictly
# Windows-locked if ever needed elsewhere. The vendor pipeline invokes:
#   pwsh ./tasks.ps1 <stage> [args...]
#
# Phase 1 scaffold: dispatch is real; each task is stubbed with TODOs. Keep stage
# names + behavior in lockstep with tasks.sh (the POSIX reference).

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Stage,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine = Join-Path $ScriptDir "engine.py"
$Python = if ($env:CBCI_PYTHON) { $env:CBCI_PYTHON } else { "python" }
$ProjectRoot = if ($env:CBCI_PROJECT_ROOT) { $env:CBCI_PROJECT_ROOT } else { (Get-Location).Path }

function Write-Log($msg) { Write-Host "[$(Get-Date -Format o)] [tasks] $msg" }
function Stop-Task($msg) { Write-Error "[tasks] ERROR: $msg"; exit 1 }

function Get-BuiltArtifactPath {
    $itype = if ($env:CBCI_INSTALL_TYPE) { $env:CBCI_INSTALL_TYPE } else { "wheel" }
    $artifact = $null
    if ($itype -eq "wheel") {
        $artifact = Get-ChildItem "wheelhouse\dist\*.whl" | Select-Object -First 1
    } elseif ($itype -eq "sdist") {
        $artifact = Get-ChildItem "dist\*.tar.gz" | Select-Object -First 1
    } else {
        Stop-Task "install: unknown install_type: $itype (wheel|sdist)"
    }
    if (-not $artifact) { Stop-Task "No $itype artifact found (build it first?)" }
    return $artifact.FullName
}

function Invoke-DisplayInfo {
    # TODO(Phase 1): mirror tasks.sh task_display_info.
    Write-Log "project=$($env:CBCI_PROJECT_TYPE) sha=$($env:CBCI_SHA) version=$($env:CBCI_VERSION)"
    & $Python $Engine validate-config
}

function Invoke-Lint   { Stop-Task "lint: not yet implemented (Phase 1)" }
function Invoke-Sdist  { Stop-Task "sdist: not yet implemented (Phase 1)" }

function Invoke-Wheel {
    Write-Log "building wheel with cibuildwheel"
    
    # Set up cibuildwheel env variables
    $env:CIBW_PLATFORM = "windows"
    $cibwEnvLines = & $Python $Engine wheel-env
    foreach ($line in $cibwEnvLines) {
        if ($line -like "*=*") {
            $parts = $line.Split("=", 2)
            [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
        }
    }
    
    # Read project build env (like PYCBC_USE_OPENSSL, PYCBC_BUILD_TYPE)
    $buildEnvLines = & $Python $Engine build-env wheel
    if ($buildEnvLines) {
        $envString = $buildEnvLines -join " "
        $pairs = $envString.Split(" ")
        foreach ($pair in $pairs) {
            if ($pair -like "*=*") {
                $parts = $pair.Split("=", 2)
                [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
            }
        }
    }
    
    & $Python -m pip install --upgrade pip
    & $Python -m pip install cibuildwheel
    
    # Find target sdist if available
    $target = "."
    if (Test-Path "dist") {
        $sdist = Get-ChildItem "dist\*.tar.gz" | Select-Object -First 1
        if ($sdist) { $target = $sdist.FullName }
    }
    
    Write-Log "target = $target"
    & $Python -m cibuildwheel --output-dir wheelhouse/dist $target
}

function Invoke-Validate {
    Write-Log "validating built wheel"
    $envLines = & $Python $Engine validate-env
    foreach ($line in $envLines) {
        if ($line -like "*=*") {
            $parts = $line.Split("=", 2)
            [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
        }
    }
    
    $artifact = Get-BuiltArtifactPath
    Write-Log "artifact = $artifact"
    
    $venvRoot = [System.IO.Path]::GetTempFileName()
    Remove-Item $venvRoot
    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
    $venvPath = Join-Path $venvRoot "venv"
    
    & $Python -m venv $venvPath
    $vpy = Join-Path $venvPath "Scripts\python.exe"
    & $vpy -m pip install --upgrade pip
    & $vpy -m pip install $artifact
    
    $smokeScript = @"
import importlib, os, pprint, sys
mod = os.environ["CBCI_VALIDATE_IMPORT"]
m = importlib.import_module(mod)
print(f"[validate] imported {mod} from {getattr(m, '__file__', '?')}")
if os.environ.get("CBCI_VALIDATE_HAS_METADATA") == "true":
    md = m.get_metadata(detailed=True)
    print("[validate] get_metadata(detailed=True):")
    pprint.pprint(md)
    blob = repr(md).lower()
    want_ver = (os.environ.get("CBCI_VERSION") or "").strip().lower()
    if want_ver and want_ver not in blob:
        print(f"[validate] WARNING: version '{want_ver}' not found in metadata", file=sys.stderr)
    want_ssl = (os.environ.get("CBCI_VALIDATE_SSL") or "").strip().lower()
    if want_ssl and want_ssl not in blob:
        print(f"[validate] WARNING: expected ssl backend '{want_ssl}' not evident in metadata", file=sys.stderr)
    print("[validate] smoke OK (extension imported + initialized)")
else:
    print("[validate] smoke OK (import only)")
"@
    
    $scriptPath = Join-Path $venvRoot "smoke.py"
    Set-Content -Path $scriptPath -Value $smokeScript
    & $vpy $scriptPath
    $exitCode = $LASTEXITCODE
    
    Remove-Item -Recurse -Force $venvRoot
    
    if ($exitCode -ne 0) { Stop-Task "Smoke validation failed" }
    Write-Log "Validation completed successfully."
}

function Invoke-Test {
    Write-Log "running tests"
    $envLines = & $Python $Engine validate-env
    foreach ($line in $envLines) {
        if ($line -like "*=*") {
            $parts = $line.Split("=", 2)
            [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
        }
    }
    
    $artifact = Get-BuiltArtifactPath
    Write-Log "artifact = $artifact"
    
    $testDir = Join-Path $ProjectRoot ".cbci_test"
    if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    
    & $Python $Engine test-setup $testDir | Out-Null
    $testRoot = Join-Path $testDir "pycbc_test"
    if (-not (Test-Path $testRoot)) { Stop-Task "Test setup did not produce test tree" }
    Write-Log "test tree = $testRoot"
    
    $cmds = & $Python $Engine test-cmds
    
    $venvRoot = [System.IO.Path]::GetTempFileName()
    Remove-Item $venvRoot
    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
    $venvPath = Join-Path $venvRoot "venv"
    
    & $Python -m venv $venvPath
    $vpy = Join-Path $venvPath "Scripts\python.exe"
    & $vpy -m pip install --upgrade pip
    & $vpy -m pip install $artifact
    & $vpy -m pip install -r (Join-Path $testRoot "requirements-test.txt")
    
    $junitDir = [System.Environment]::GetEnvironmentVariable("CBCI_JUNIT_DIR")
    if ($junitDir -and -not (Test-Path $junitDir)) {
        New-Item -ItemType Directory -Path $junitDir -Force | Out-Null
    }
    
    Push-Location $testRoot
    $rc = 0
    $origPath = $env:PATH
    $env:PATH = "$(Join-Path $venvPath "Scripts");$origPath"
    
    try {
        $idx = 1
        foreach ($cmd in $cmds) {
            if ($cmd.Trim()) {
                $fullCmd = $cmd
                if ($junitDir) {
                    if ($cmd -match "pytest" -or $cmd -match "py.test") {
                        $apiname = "override-$idx"
                        if ($cmd -match "acouchbase") {
                            $apiname = "acouchbase"
                        } elseif ($cmd -match "txcouchbase") {
                            $apiname = "txcouchbase"
                        } elseif ($cmd -match "couchbase") {
                            $apiname = "couchbase"
                        }
                        $fullCmd = "$cmd --junitxml=$junitDir\junit-$apiname.xml"
                        $idx++
                    }
                }
                Write-Log "run: $fullCmd"
                cmd /c $fullCmd
                if ($LASTEXITCODE -ne 0) { $rc = $LASTEXITCODE }
            }
        }
    } finally {
        $env:PATH = $origPath
        Pop-Location
        Remove-Item -Recurse -Force $venvRoot
    }
    
    if ($rc -ne 0) { Stop-Task "pytest failed (rc=$rc)" }
    Write-Log "tests completed successfully."
}

switch ($Stage) {
    { $_ -in @("display-info", "display_info") } { Invoke-DisplayInfo; break }
    "lint"                                       { Invoke-Lint; break }
    "sdist"                                      { Invoke-Sdist; break }
    "wheel"                                      { Invoke-Wheel; break }
    "validate"                                   { Invoke-Validate; break }
    "test"                                       {
        Invoke-Test
        break
    }
    default { Stop-Task "unknown stage: $Stage" }
}
