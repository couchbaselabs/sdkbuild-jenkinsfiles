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
    'engine.py'           = '5b9f76d709bd6a2735dc2bb84364cd4cedd35104e794a35831212fdea9683743'
    'jenkins.py'          = '6ea6ef4ae06674023d6dcadcdd8f9e58e468d376acbe8a7fe8120f4143f9ecfb'
    'tasks.sh'            = '4fd931ab0e198bdfb015fc57b534da8d4f2d4205983f787dff48b8e4f014c437'
    'tasks.ps1'           = 'ebb82b9d825761945f1586bb44907f04ee1c98a891fe89292b0ccd6547704bf5'
    'auditwheel_patch.py' = '402f0b8270a7f8acd4790d12cc96257190c1f8209eff2d7d3f450d661d58bef5'
    'ci-config.yaml'      = '2f075cca668628cea899c98e5abe72cfa0cd39d62fc4ebd76a936256416e457c'
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
