#!/usr/bin/env pwsh
#
# bootstrap.ps1 - Windows PowerShell mirror of bootstrap.sh.
#
# Windows Jenkins agents have no bash, so the consumer pipeline curls THIS by name
# on Windows and runs it with `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`.
# Responsibilities are identical to bootstrap.sh:
#   1. Pin the CI-core ref (env CBCI_REF) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.js, jenkins.js, tasks.sh, tasks.ps1,
#      ci-config.yaml, package.json, package-lock.json) at that ref.
#   3. Verify what was fetched (sha256) before anything runs.
#   4. Materialize node_modules (npm ci) - engine.js's one pinned runtime
#      dependency (`yaml`) must be installed before `node engine.js` works.
#
# Keep the expected hashes below IN SYNC with bootstrap.sh (one table per bootstrapper).

# Force TLS 1.2 on PowerShell 5.1 / .NET Framework on older Windows Server agents
# so Invoke-WebRequest / Invoke-RestMethod doesn't fail with TLS secure channel errors.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is glacial with the progress bar

# --- configuration -----------------------------------------------------------

# Pinned ref of couchbase-sdk-ci that this bootstrap fetches. A CI fix ships by
# moving this ref; SDK repos never change.
$CBCI_REF = if ($env:CBCI_REF) { $env:CBCI_REF } else { 'master' }

# Base raw URL for the couchnode/ tree at the pinned ref.
$CBCI_BASE_URL = if ($env:CBCI_BASE_URL) {
    $env:CBCI_BASE_URL
} else {
    "https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/$CBCI_REF/couchnode/ci_scripts_v1"
}

# Where the manifest is written. Consumers run ./tasks.ps1 from here.
$CBCI_DEST = if ($env:CBCI_DEST) { $env:CBCI_DEST } else { '.' }

# The fixed manifest (must match bootstrap.sh's CBCI_MANIFEST). bootstrap.ps1 itself
# is excluded - it is already present.
$CBCI_MANIFEST = @(
    'engine.mjs'
    'jenkins.mjs'
    'tasks.sh'
    'tasks.ps1'
    'ci-config.yaml'
    'package.json'
    'package-lock.json'
)

# Expected sha256 (lowercase hex). Keep in sync with bootstrap.sh get_expected_hash().
$CBCI_EXPECTED = @{
    'engine.mjs'        = '0a9ef2b11c25fe28e4ee197bd1ae169f83c95d56792c9266fa31be9dc74886b1'
    'jenkins.mjs'       = '143e490ebaa2257abe296f9dc43dd4424d91e680e281cfe70e74302a463234cd'
    'tasks.sh'          = '333baa647b9be224b0053b6c819e8b56ead8399e4d8acfa2cd57588eae5aea1e'
    'tasks.ps1'         = 'cb6cb6b521908173ced33bba73b29c06dfd5a2bf1cc2e71822effcea2cd6cd98'
    'ci-config.yaml'    = '41a5d7fe9a47049296b626e358edc118ea880d4fa4ad2877c130a6f554e60557'
    'package.json'      = '490e8f0a45c7c24b8f80f303202673c182154e3fa89884b32b24408825e727c4'
    'package-lock.json' = '8930ae2b212bdabb240935d44acfd1b5c869d09b8311e76ab45e035f10a64372'
}

# --- helpers -----------------------------------------------------------------

function Write-Log([string]$msg) { Write-Host "[bootstrap] $msg" }

function Get-Sha256([string]$file) {
    (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
}

# Fetch $url -> $out, preferring curl.exe but falling back to Invoke-WebRequest.
# Mirrors bootstrap.sh's curl->wget fallback (curl.exe ships with Windows 10+/
# Server 2019+ and avoids Invoke-WebRequest's PS 5.1 TLS/proxy defaults).
function Get-ManifestFile([string]$url, [string]$out) {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fsSL $url -o $out
        if ($LASTEXITCODE -eq 0) { return }
        Write-Log "curl.exe failed for $url (exit $LASTEXITCODE); falling back to Invoke-WebRequest"
    } else {
        Write-Log "curl.exe unavailable; using Invoke-WebRequest for $url"
    }
    # $ErrorActionPreference='Stop' (top of script) makes an HTTP/transport error throw
    # and abort the run, same fail-fast contract as curl -f. verify below checksums
    # every file as a final backstop.
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
}

# npm ci (not npm install) - reproducible from package-lock.json, matching exactly
# what the checksum above verified. Skippable via CBCI_SKIP_NPM_INSTALL for a
# consumer that already vendors node_modules another way.
function Install-Dependencies {
    if ($env:CBCI_SKIP_NPM_INSTALL -eq 'true') {
        Write-Log 'CBCI_SKIP_NPM_INSTALL=true - skipping npm ci'
        return
    }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Log "ERROR: npm not found on PATH (required to install engine.js's 'yaml' dependency)"
        exit 1
    }
    Write-Log 'installing dependencies (npm ci)'
    Push-Location $CBCI_DEST
    try {
        & npm ci --omit=dev
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: npm ci failed (exit $LASTEXITCODE)"
            exit 1
        }
    } finally {
        Pop-Location
    }
}

# --- main --------------------------------------------------------------------

Write-Log "ref=$CBCI_REF dest=$CBCI_DEST"
New-Item -ItemType Directory -Force -Path $CBCI_DEST | Out-Null

foreach ($name in $CBCI_MANIFEST) {
    $url = "$CBCI_BASE_URL/$name"
    $out = Join-Path $CBCI_DEST $name
    Write-Log "fetching $name <- $url"
    Get-ManifestFile $url $out
}

$failed = $false
foreach ($name in $CBCI_MANIFEST) {
    $file = Join-Path $CBCI_DEST $name
    if (-not (Test-Path $file) -or ((Get-Item $file).Length -eq 0)) {
        Write-Log "ERROR: manifest file missing or empty: $name"
        $failed = $true
        continue
    }
    $expected = $CBCI_EXPECTED[$name]
    if ($expected) {
        $actual = Get-Sha256 $file
        if ($actual -ne $expected) {
            Write-Log "ERROR: checksum verification failed for $name"
            Write-Log "  expected: $expected"
            Write-Log "  actual:   $actual"
            $failed = $true
        }
    }
}

if ($failed) { exit 1 }
Install-Dependencies
Write-Log "manifest ready: $($CBCI_MANIFEST -join ', ')"
