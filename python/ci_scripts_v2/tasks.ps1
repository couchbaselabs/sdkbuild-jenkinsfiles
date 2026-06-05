#!/usr/bin/env pwsh
#
# tasks.ps1 - Windows task executors for the Couchbase Python SDK (PowerShell Core).
#
# Mirror of tasks.sh for Windows. pwsh is cross-platform, so this is not strictly
# Windows-locked if ever needed elsewhere. The vendor pipeline invokes:
#   pwsh ./tasks.ps1 <stage> [args...]
#
# Keep stage names and behavior in lockstep with tasks.sh, the POSIX reference.

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

# Apply KEY=VALUE facts from engine.py into the process environment so child pythons
# inherit them. engine's _emit_pairs (project-env / validate-env / build-env) prints
# ALL pairs on ONE space-separated line, so tokenize on whitespace - iterating the raw
# lines and Split("=",2) sets only the FIRST pair and swallows the rest (this was the
# `KeyError: 'CBCI_VALIDATE_IMPORT'` in validate/test). Values are space-free by the
# _emit_pairs contract. NOT for wheel-env: it uses _emit_lines precisely because its
# CIBW_* values may contain spaces, so that consumer must stay one-pair-per-line.
function Import-EngineEnvPairs([string[]]$lines) {
    if (-not $lines) { return }
    foreach ($pair in (($lines -join " ") -split '\s+')) {
        if ($pair -notlike "*=*") { continue }
        $parts = $pair.Split("=", 2)
        [System.Environment]::SetEnvironmentVariable($parts[0], $parts[1])
    }
}

# Pick the wheel under wheelhouse\dist compatible with interpreter $vpy. Mirrors
# tasks.sh's _select_wheel: normally there's exactly one wheel (a per-cell unstash only
# ever brings its own unit's wheel), but the copy-artifacts test-only rerun fetches
# EVERY platform's wheel into every cell's wheelhouse\dist indiscriminately, so a naive
# "first file" pick can grab the wrong platform's wheel. Let pip's own compatibility
# check be the oracle instead of reimplementing wheel tag matching.
function Select-Wheel($vpy) {
    $candidates = @(Get-ChildItem "wheelhouse\dist\*.whl" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }
    foreach ($w in $candidates) {
        # try/catch, not just the *>$null redirect: with $ErrorActionPreference = "Stop"
        # (top of script), a native command's stderr output gets promoted to a TERMINATING
        # error before the redirect can suppress it -- an incompatible wheel is the expected,
        # non-fatal case here (that's how we detect it), so swallow the exception and fall
        # through to the exit-code check, exactly like tasks.sh's `if ... ; then` guard.
        try {
            & $vpy -m pip install --dry-run --no-deps $w.FullName *>$null
        } catch {
            # non-fatal: this candidate isn't compatible with $vpy; try the next one
        }
        if ($LASTEXITCODE -eq 0) { return $w.FullName }
    }
    Stop-Task "install: none of $($candidates.Count) wheels under wheelhouse\dist are compatible with this interpreter/platform: $($candidates.FullName -join ', ')"
}

function Get-BuiltArtifactPath($vpy) {
    $itype = if ($env:CBCI_INSTALL_TYPE) { $env:CBCI_INSTALL_TYPE } else { "wheel" }
    $artifact = $null
    if ($itype -eq "wheel") {
        $path = Select-Wheel $vpy
        if ($path) { $artifact = Get-Item $path }
    } elseif ($itype -eq "sdist") {
        $artifact = Get-ChildItem "dist\*.tar.gz" | Select-Object -First 1
    } else {
        Stop-Task "install: unknown install_type: $itype (wheel|sdist)"
    }
    if (-not $artifact) { Stop-Task "No $itype artifact found (build it first?)" }
    return $artifact.FullName
}

function Invoke-DisplayInfo {
    Write-Log "project=$($env:CBCI_PROJECT_TYPE) sha=$($env:CBCI_SHA) version=$($env:CBCI_VERSION)"
    & $Python $Engine validate-config
}

function Invoke-Lint   { Stop-Task "lint: not implemented on Windows (use tasks.sh)" }
function Invoke-Sdist  { Stop-Task "sdist: not implemented on Windows (use tasks.sh)" }

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
    Import-EngineEnvPairs (& $Python $Engine build-env wheel)

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
    # NATIVE wheel build (no cibuildwheel) - the Jenkins path for Windows. Builds with the
    # on-PATH (cbdep) python + the existing MSVC/cmake/go toolchain env (getEnvStr). Unlike
    # POSIX, Windows debug info lives in separate .pdb files (not embedded in the .pyd), so
    # the release wheel is already lean and there is no strip/debug-wheel split - the .pdb
    # itself is the debug artifact. See engine.py adapter_jenkins_tags.
    Write-Log "wheel-native: building wheel natively (no cibuildwheel)"

    # Export the same PYCBC_* knobs the engine resolves (PYCBC_USE_OPENSSL,
    # PYCBC_BUILD_TYPE=RelWithDebInfo, ...) so the native build matches the planned config.
    $buildEnvLines = & $Python $Engine build-env wheel
    if ($LASTEXITCODE -ne 0) { Stop-Task "wheel-native: build-env wheel failed" }
    Import-EngineEnvPairs $buildEnvLines

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

    # Collect the SDK's symbols into dist_debug as raw .pdb files. Each is renamed to the
    # stem of the wheel it belongs to, because a .pdb is bound to one exact binary by a
    # signature GUID and the linker names them all after the CMake target. Left unrenamed,
    # every Python version emits the same "_core.pdb" and the last build to land silently
    # overwrites the rest, here and again in the release upload.
    # Missing symbols stay non-fatal: the release wheel stands on its own.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $pdbRoots = @()
    if ($env:PYCBC_BUILD_TEMP) { $pdbRoots += $env:PYCBC_BUILD_TEMP }
    if ($env:PYCBC_BUILD_BASE) { $pdbRoots += $env:PYCBC_BUILD_BASE }
    $pdbRoots += (Join-Path $ProjectRoot "build")
    $pdbFiles = @(foreach ($r in ($pdbRoots | Select-Object -Unique)) {
        if (Test-Path $r) { Get-ChildItem -Path $r -Recurse -Filter *.pdb -ErrorAction SilentlyContinue }
    })

    $pdbCount = 0
    foreach ($w in $wheels) {
        # Take the module name from the wheel's own .pyd rather than hardcoding it, so the
        # match cannot drift if the extension is renamed. MSVC names the linker .pdb after
        # that same output name, which is what makes this a reliable pairing.
        $modNames = @()
        $zip = [System.IO.Compression.ZipFile]::OpenRead($w.FullName)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.Name -like "*.pyd") { $modNames += ($e.Name -split '\.')[0] }
            }
        } finally { $zip.Dispose() }
        $modNames = @($modNames | Select-Object -Unique)
        if ($modNames.Count -eq 0) {
            Write-Log "wheel-native: $($w.Name) holds no .pyd, no symbols to pair"
            continue
        }

        $pdbMatches = @($pdbFiles | Where-Object { $modNames -contains $_.BaseName } |
                     Sort-Object LastWriteTime -Descending)
        if ($pdbMatches.Count -eq 0) {
            Write-Log "wheel-native: no .pdb matching [$($modNames -join ', ')] for $($w.Name)"
            continue
        }
        if ($pdbMatches.Count -gt 1) {
            Write-Log "wheel-native: $($pdbMatches.Count) candidate .pdb(s) for $($w.Name), taking newest"
        }
        $destName = [System.IO.Path]::GetFileNameWithoutExtension($w.Name) + ".pdb"
        Copy-Item $pdbMatches[0].FullName -Destination (Join-Path $debugDir $destName) -Force -ErrorAction SilentlyContinue
        Write-Log "wheel-native: symbols $($pdbMatches[0].Name) -> $destName"
        $pdbCount++
    }
    Write-Log "wheel-native: collected $pdbCount .pdb file(s) into dist_debug"

    Remove-Item -Recurse -Force $bdist -ErrorAction SilentlyContinue
}

function Invoke-Validate {
    Write-Log "validating built wheel"
    Import-EngineEnvPairs (& $Python $Engine validate-env)

    $venvRoot = [System.IO.Path]::GetTempFileName()
    Remove-Item $venvRoot
    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
    $venvPath = Join-Path $venvRoot "venv"

    & $Python -m venv $venvPath
    $vpy = Join-Path $venvPath "Scripts\python.exe"
    & $vpy -m pip install --upgrade pip

    $artifact = Get-BuiltArtifactPath $vpy
    Write-Log "artifact = $artifact"
    & $vpy -m pip install $artifact

    # NOTE: expandable here-string. Keep the Python below free of '$' and backticks, or
    # PowerShell will interpolate/escape them before the interpreter ever sees them.
    $smokeScript = @"
import importlib, os, pprint, sys


def dump_extension_modules(mod):
    # Name the cause of a failed import: what shipped vs what this interpreter accepts.
    # An extension whose FILENAME is not an importable suffix fails identically to one that
    # was never built. Windows is the trap: it has no '.abi3.pyd' suffix (only '.pyd'), so a
    # stable-ABI module named the POSIX way is invisible to the importer. Validate failing
    # also means the run never reaches archiving, so this is the only look inside the
    # artifact anyone gets.
    import importlib.machinery as machinery
    import importlib.util as util
    print(f"[validate] import failed; suffixes this interpreter accepts: {machinery.EXTENSION_SUFFIXES}", file=sys.stderr)
    try:
        roots = list(util.find_spec(mod).submodule_search_locations or [])
    except Exception as exc:
        print(f"[validate]   could not locate '{mod}' on disk: {exc!r}", file=sys.stderr)
        return
    found = 0
    for root in roots:
        for dirpath, _, names in os.walk(root):
            for name in sorted(names):
                if os.path.splitext(name)[1].lower() in (".so", ".pyd", ".dylib"):
                    found += 1
                    rel = os.path.join(os.path.relpath(dirpath, root), name)
                    print(f"[validate]   shipped: {rel}", file=sys.stderr)
    if not found:
        print(f"[validate]   shipped: NO extension modules under {roots} (the build produced none, or they were left out of the artifact)", file=sys.stderr)


mod = os.environ["CBCI_VALIDATE_IMPORT"]
try:
    m = importlib.import_module(mod)
except ImportError:
    dump_extension_modules(mod)
    raise
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

function Invoke-TestSetup {
    # Build the artifact-isolation test tree under .cbci_test (needs the SDK checkout). CI
    # doesn't call this directly - every fan-out test node gets the SDK checkout (Jenkins
    # stashes it once from a single checkout stage) and builds its own tree inline via
    # Invoke-Test. This exists for local/manual use, mirroring tasks.sh's `test-setup`: run it
    # once and reuse the tree across repeated `tasks.ps1 test` invocations.
    $testDir = Join-Path $ProjectRoot ".cbci_test"
    if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $testRoot = Invoke-BuildTestTree $testDir
    if (-not $testRoot) { Stop-Task "Test setup did not produce test tree" }
    Write-Log "test-setup: test tree ready at $testRoot"
}

# Run engine.py test-setup and return the tree root it printed (its LAST stdout line - mirrors
# tasks.sh's `test-setup ... | tail -1`), or $null. NOT `Join-Path $testDir "pycbc_test"` +
# Test-Path: test_setup() creates that directory in its FIRST step (renamed API dirs), then
# generates pytest.ini/requirements-test.txt afterward - so a crash partway through (e.g. a
# pre-3.11 interpreter whose tomli backport didn't actually install) still leaves the directory
# sitting there, and a bare Test-Path would misreport a half-built tree as done. Capturing
# engine.py's own last-line output means a crash before `print(test_root)` yields nothing here,
# so the caller's check below catches it instead of failing later with a confusing "file not
# found" deep inside pip. try/catch (not just checking $LASTEXITCODE): $ErrorActionPreference =
# "Stop" (top of script) promotes the subprocess's stderr into a terminating exception - see
# Select-Wheel's identical guard above.
function Invoke-BuildTestTree($testDir) {
    $lines = $null
    try {
        $lines = & $Python $Engine test-setup $testDir
    } catch {
        # non-fatal here: fall through with $lines unset so the caller reports it clearly
    }
    if (-not $lines) { return $null }
    $root = $lines | Select-Object -Last 1
    if ($root -and (Test-Path $root)) { return $root }
    return $null
}

function Invoke-Test {
    Write-Log "running tests"
    Import-EngineEnvPairs (& $Python $Engine validate-env)

    # Prefer a PRE-BUILT tree staged here (a dev ran Invoke-TestSetup by hand) - otherwise
    # build it inline from the SDK checkout CI already staged under ProjectRoot (Jenkins: one
    # checkout stage stashes it for every fan-out node). The tree is
    # platform/arch/python/install_type independent, so building it per node is cheap and
    # never wrong. Detect by pytest.ini at a tree root under .cbci_test; do NOT delete a
    # pre-built tree.
    $testDir = Join-Path $ProjectRoot ".cbci_test"
    $testRoot = $null
    if (Test-Path $testDir) {
        $testRoot = Get-ChildItem -Path $testDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "pytest.ini") } |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ($testRoot) {
        Write-Log "test tree = $testRoot (reusing pre-built)"
    } else {
        if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        $testRoot = Invoke-BuildTestTree $testDir
        if (-not $testRoot) { Stop-Task "Test setup did not produce test tree" }
        Write-Log "test tree = $testRoot (built)"
    }

    $cmds = & $Python $Engine test-cmds

    $venvRoot = [System.IO.Path]::GetTempFileName()
    Remove-Item $venvRoot
    New-Item -ItemType Directory -Path $venvRoot -Force | Out-Null
    $venvPath = Join-Path $venvRoot "venv"

    & $Python -m venv $venvPath
    $vpy = Join-Path $venvPath "Scripts\python.exe"
    & $vpy -m pip install --upgrade pip

    $artifact = Get-BuiltArtifactPath $vpy
    Write-Log "artifact = $artifact"
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

# Optional artifact log (CBCI_LOG_FILE) - on par with tasks.sh: re-invoke this script
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
    { $_ -in @("test-setup", "test_setup") }     { Invoke-TestSetup; break }
    "test"                                       {
        Invoke-Test
        break
    }
    default { Stop-Task "unknown stage: $Stage" }
}
