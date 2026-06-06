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

function Invoke-WheelNative {
    # NATIVE wheel build (no cibuildwheel) — the Jenkins path for Windows. Builds with the
    # on-PATH (cbdep) python + the existing MSVC/cmake/go toolchain env (getEnvStr). Unlike
    # POSIX, Windows debug info lives in separate .pdb files (not embedded in the .pyd), so
    # the release wheel is already lean and there is no strip/debug-wheel split — instead we
    # best-effort collect the .pdb(s) as raw symbols. See engine.py adapter_jenkins_tags.
    Write-Log "wheel-native: building wheel natively (no cibuildwheel)"

    # Export the same PYCBC_* knobs the engine resolves (PYCBC_USE_OPENSSL,
    # PYCBC_BUILD_TYPE=RelWithDebInfo, ...) so the native build matches the planned config.
    $buildEnvLines = & $Python $Engine build-env wheel
    if ($LASTEXITCODE -ne 0) { Stop-Task "wheel-native: build-env wheel failed" }
    foreach ($pair in (($buildEnvLines -join " ").Split(" "))) {
        if ($pair -like "*=*") {
            $parts = $pair.Split("=", 2)
            [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
        }
    }

    & $Python -m pip install --upgrade pip
    & $Python -m pip install wheel
    if ($LASTEXITCODE -ne 0) { Stop-Task "wheel-native: failed to install build deps" }

    # Build from the sdist (CPM cache baked in) when present, else the cwd checkout.
    $target = "."
    if (Test-Path "dist") {
        $sdist = Get-ChildItem "dist\*.tar.gz" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sdist) { $target = $sdist.FullName }
    }

    $bdist = Join-Path ([System.IO.Path]::GetTempPath()) ("cbci-bdist-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $bdist | Out-Null

    $pipArgs = @("-m", "pip", "wheel", $target, "--no-deps", "-w", $bdist)
    if ($env:CBCI_BUILD_VERBOSITY) { $pipArgs += "-v" }
    Write-Log "wheel-native: building wheel (target=$target)"
    & $Python @pipArgs
    if ($LASTEXITCODE -ne 0) { Stop-Task "wheel-native: pip wheel failed" }

    $distDir = Join-Path $ProjectRoot "wheelhouse\dist"
    $debugDir = Join-Path $ProjectRoot "wheelhouse\dist_debug"
    New-Item -ItemType Directory -Force -Path $distDir, $debugDir | Out-Null

    $wheels = Get-ChildItem (Join-Path $bdist "*.whl") -ErrorAction SilentlyContinue
    if (-not $wheels) { Stop-Task "wheel-native: pip produced no wheel in $bdist" }
    foreach ($w in $wheels) {
        Write-Log "wheel-native: release wheel $($w.Name)"
        Copy-Item $w.FullName -Destination $distDir -Force
    }

    # Best-effort: collect .pdb symbols from the build tree into dist_debug (raw files, not
    # a wheel). Missing .pdb is non-fatal — the release wheel stands on its own.
    $pdbRoots = @()
    if ($env:PYCBC_BUILD_TEMP) { $pdbRoots += $env:PYCBC_BUILD_TEMP }
    if ($env:PYCBC_BUILD_BASE) { $pdbRoots += $env:PYCBC_BUILD_BASE }
    $pdbRoots += (Join-Path $ProjectRoot "build")
    $pdbFiles = foreach ($r in ($pdbRoots | Select-Object -Unique)) {
        if (Test-Path $r) { Get-ChildItem -Path $r -Recurse -Filter *.pdb -ErrorAction SilentlyContinue }
    }
    $pdbCount = 0
    foreach ($p in $pdbFiles) {
        Copy-Item $p.FullName -Destination $debugDir -Force -ErrorAction SilentlyContinue
        $pdbCount++
    }
    Write-Log "wheel-native: collected $pdbCount .pdb file(s) into dist_debug (best-effort)"

    Remove-Item -Recurse -Force $bdist -ErrorAction SilentlyContinue
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

# Optional artifact log (CBCI_LOG_FILE) — on par with tasks.sh: re-invoke this script
# once with output teed to the file the vendor CI archives. Tee-Object (not
# Start-Transcript) so native build output is captured under Windows PowerShell 5.1 too.
# Guarded against recursion; internal hooks (_*) are skipped.
if ($env:CBCI_LOG_FILE -and -not $env:CBCI_LOG_TEEING -and ($Stage -notlike "_*")) {
    $logDir = Split-Path -Parent $env:CBCI_LOG_FILE
    if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $env:CBCI_LOG_TEEING = "1"
    $exe = (Get-Process -Id $PID).Path
    $reArgs = @('-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $Stage)
    if ($Args) { $reArgs += $Args }
    & $exe @reArgs 2>&1 | Tee-Object -FilePath $env:CBCI_LOG_FILE
    exit $LASTEXITCODE
}

switch ($Stage) {
    { $_ -in @("display-info", "display_info") } { Invoke-DisplayInfo; break }
    "lint"                                       { Invoke-Lint; break }
    "sdist"                                      { Invoke-Sdist; break }
    "wheel"                                      { Invoke-Wheel; break }
    "wheel-native"                               { Invoke-WheelNative; break }
    "validate"                                   { Invoke-Validate; break }
    "test"                                       {
        Invoke-Test
        break
    }
    default { Stop-Task "unknown stage: $Stage" }
}
