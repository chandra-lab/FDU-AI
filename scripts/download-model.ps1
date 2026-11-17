<#
.SYNOPSIS
  Downloads the pinned checkpoint of the selected inference profile into <UAI_DATA_ROOT>\models\.
  Refuses to run unless gpu-check.ps1 has recorded a recent PASS for the same profile.
  Runs in a throwaway container (university-ai-model-download) using the pinned inference base image,
  so no Python is needed on Windows. Resumable: re-run to continue an interrupted download.
.PARAMETER Wait
  Stream progress and block until finished (default: run detached and return).
#>
[CmdletBinding()]
param([switch] $Wait)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
Assert-DockerReady
Assert-CompatibilityPass -Config $cfg -InferenceProfile $inf

if (Test-ModelDownloaded -Config $cfg -InferenceProfile $inf) {
    Write-Ok ("{0}@{1} is already downloaded at {2}" -f $inf['MODEL_REPO'], $inf['MODEL_REVISION'], (Get-ModelLocalPath $cfg $inf))
    return
}

$name = 'university-ai-model-download'
$existing = Get-ContainerState $name
if ($existing -eq 'running') {
    Write-Warn "A download is already running. Follow it with: docker logs -f $name"
    return
}
if ($existing) { & docker rm $name | Out-Null }

$root = $cfg['UAI_DATA_ROOT']
foreach ($sub in 'models', 'hf-cache') { New-Item -ItemType Directory -Force -Path (Join-Path $root $sub) | Out-Null }
$repo = $inf['MODEL_REPO']
$rev = $inf['MODEL_REVISION']

$dockerArgs = @(
    'run', '--name', $name, '--network', $cfg['UAI_NETWORK'],
    '--label', 'project=university-ai',
    '-v', ("{0}:/models" -f (Join-Path $root 'models')),
    '-v', ("{0}:/hf-cache" -f (Join-Path $root 'hf-cache')),
    '-v', ("{0}:/opt/uai-scripts:ro" -f (Join-Path $RepoRoot 'inference\scripts')),
    '-e', 'HF_HOME=/hf-cache',
    '-e', 'HF_HUB_DISABLE_TELEMETRY=1',
    '-e', "MODEL_REPO=$repo",
    '-e', "MODEL_REVISION=$rev",
    '-e', ("TARGET_DIR={0}" -f (Get-ModelContainerPath $inf))
)
# Passed by name only so the token never appears in the process command line.
if ($cfg['HF_TOKEN']) { $env:HF_TOKEN = $cfg['HF_TOKEN']; $dockerArgs += @('-e', 'HF_TOKEN') }
if (-not $Wait) { $dockerArgs += '-d' }
$dockerArgs += @('--entrypoint', '/bin/bash', $cfg['INFERENCE_BASE_IMAGE'], '/opt/uai-scripts/download.sh')

Write-Step ("Downloading {0}@{1} -> {2}" -f $repo, $rev, (Get-ModelLocalPath $cfg $inf))
$rc = Invoke-Native docker @dockerArgs
if ($rc -ne 0) { throw "Model download container failed (exit $rc). See: docker logs $name" }

if ($Wait) {
    & docker rm $name | Out-Null
    if (Test-ModelDownloaded -Config $cfg -InferenceProfile $inf) { Write-Ok 'Download complete and verified.' }
    else { throw 'Download finished but verification failed; re-run to resume.' }
} else {
    Write-Ok "Download started in container '$name'."
    Write-Host "  Progress: docker logs -f $name"
    Write-Host '  Status:   scripts\status.ps1'
}
