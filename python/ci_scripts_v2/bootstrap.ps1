#!/usr/bin/env pwsh
#
# bootstrap.ps1 - Windows PowerShell mirror of bootstrap.sh.
#
# Windows Jenkins agents have no bash, so the consumer pipeline curls THIS by name
# on Windows and runs it with `powershell -ExecutionPolicy Bypass -File bootstrap.ps1`.
# Responsibilities are identical to bootstrap.sh:
#   1. Pin the CI-core ref (env CBCI_REF) the rest of the manifest is fetched from.
#   2. Fetch the fixed manifest (engine.py, jenkins.py, tasks.sh, tasks.ps1,
#      auditwheel_patch.py, ci-config.yaml) at that ref.
#   3. Verify what was fetched (sha256) before anything runs.
#
# Keep the expected hashes below IN SYNC with bootstrap.sh (one table per bootstrapper).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is glacial with the progress bar

# --- configuration -----------------------------------------------------------

# Pinned ref of couchbase-sdk-ci that this bootstrap fetches. A CI fix ships by
# moving this ref; SDK repos never change.
$CBCI_REF = if ($env:CBCI_REF) { $env:CBCI_REF } else { 'master' }

# Base raw URL for the python/ tree at the pinned ref.
$CBCI_BASE_URL = if ($env:CBCI_BASE_URL) {
    $env:CBCI_BASE_URL
} else {
    "https://raw.githubusercontent.com/couchbaselabs/sdkbuild-jenkinsfiles/$CBCI_REF/python/ci_scripts_v2"
}

# Where the manifest is written. Consumers run ./tasks.ps1 from here.
$CBCI_DEST = if ($env:CBCI_DEST) { $env:CBCI_DEST } else { '.' }

# The fixed manifest (must match bootstrap.sh's CBCI_MANIFEST). bootstrap.ps1 itself
# is excluded, since it is already present.
$CBCI_MANIFEST = @(
    'engine.py'
    'jenkins.py'
    'tasks.sh'
    'tasks.ps1'
    'auditwheel_patch.py'
    'ci-config.yaml'
)

# Expected sha256 (lowercase hex). Keep in sync with bootstrap.sh get_expected_hash().
$CBCI_EXPECTED = @{
    'engine.py'           = '35c00330788ee1997909848c33baf492e917517005f408aec68f6afcc5a9f64c'
    'jenkins.py'          = '3a4f4be98f8c5e31e93551e8766267a24947fd8795551b9abf7faff6b72ec250'
    'tasks.sh'            = '22764f1d87d5109b26f7af42bbecdd6ecd85be3b93bef0c527108d7794a150b2'
    'tasks.ps1'           = '6dfd9c6f0a8273870cfa8c6cb8fdc5a19d9685e725c4423238ece3ebbffa4a3c'
    'auditwheel_patch.py' = '1e38cfe3a7335fe3c5d5e08a0f53718f38d95b8f7185c1315fec5cddc5ad4bfa'
    'ci-config.yaml'      = '6b3c035f8cc80ffb75dd6006134531e6a31bc6bdb3bb3d29e605ca777512cec9'
}

# --- helpers -----------------------------------------------------------------

function Write-Log([string]$msg) { Write-Host "[bootstrap] $msg" }

function Get-Sha256([string]$file) {
    (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
}

# Fetch $url -> $out, preferring curl.exe but falling back to Invoke-WebRequest, so a single
# broken fetcher does not doom the node. The Windows fallback is IWR, not wget: wget is not
# standard on Windows agents, whereas IWR always ships. curl.exe stays PRIMARY and IWR runs
# only when it fails, so the normal path is unchanged. This is parity with bootstrap.sh's
# curl->wget fallback, not a fix for an observed Windows failure.
function Get-ManifestFile([string]$url, [string]$out) {
    # curl.exe ships with Windows 10+/Server 2019+ and avoids Invoke-WebRequest's PS 5.1
    # TLS/proxy defaults.
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fsSL $url -o $out
        if ($LASTEXITCODE -eq 0) { return }
        Write-Log "curl.exe failed for $url (exit $LASTEXITCODE); falling back to Invoke-WebRequest"
    } else {
        Write-Log "curl.exe unavailable; using Invoke-WebRequest for $url"
    }
    # $ErrorActionPreference='Stop' (top of script) makes an HTTP/transport error throw and
    # abort the run, same fail-fast contract as curl -f. verify below checksums every file.
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
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
Write-Log "manifest ready: $($CBCI_MANIFEST -join ', ')"
