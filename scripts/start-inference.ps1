<#
.SYNOPSIS
  Builds (if needed) and starts university-ai-inference (vLLM, OpenAI-compatible API on port 8000
  inside the private network; optionally published on 127.0.0.1 only).
.PARAMETER Build
  Rebuild the inference image even if it exists.
.PARAMETER Recreate
  Remove and recreate the container if it is already running (picks up profile changes).
.PARAMETER NoWait
  Return immediately instead of waiting for /health.
#>
[CmdletBinding()]
param([switch] $Build, [switch] $Recreate, [switch] $NoWait)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
Assert-DockerReady

$name = $cfg['INFERENCE_CONTAINER']
$state = Get-ContainerState $name
if ($state -eq 'running' -and -not $Recreate) {
    Write-Ok "$name is already running (use -Recreate to restart with the current profile)."
    return
}

if ($state -ne 'running') { Assert-CompatibilityPass -Config $cfg -InferenceProfile $inf }
if (-not (Test-ModelDownloaded -Config $cfg -InferenceProfile $inf)) {
    throw ("Weights for {0}@{1} are not fully downloaded. Run scripts\download-model.ps1 (status: scripts\status.ps1)." -f $inf['MODEL_REPO'], $inf['MODEL_REVISION'])
}
if (-not $cfg['INFERENCE_API_KEY'] -or $cfg['INFERENCE_API_KEY'] -eq 'CHANGE_ME') {
    throw 'INFERENCE_API_KEY is not set in .env. Run scripts\setup.ps1.'
}

& (Join-Path $PSScriptRoot 'create-network.ps1')

$image = $cfg['INFERENCE_IMAGE']
$imageExists = ((Invoke-NativeQuiet docker image inspect $image).ExitCode -eq 0)
if ($Build -or -not $imageExists) {
    Write-Step "Building $image from $($cfg['INFERENCE_BASE_IMAGE'])"
    $rc = Invoke-Native docker build --build-arg ("VLLM_IMAGE={0}" -f $cfg['INFERENCE_BASE_IMAGE']) --label project=university-ai -t $image (Join-Path $RepoRoot 'inference')
    if ($rc -ne 0) { throw 'docker build failed.' }
}

if ($state) {
    Write-Step "Removing existing container $name ($state)"
    & docker rm -f $name | Out-Null
}

$env:VLLM_API_KEY = $cfg['INFERENCE_API_KEY']
$dockerArgs = @(
    'run', '-d', '--name', $name,
    '--network', $cfg['UAI_NETWORK'], '--network-alias', 'inference',
    '--gpus', 'all', '--shm-size', '8g',
    '--restart', 'unless-stopped',
    '--label', 'project=university-ai',
    '--log-opt', 'max-size=50m', '--log-opt', 'max-file=5',
    '--env-file', $inf['PROFILE_PATH'],
    '-e', ("MODEL_PATH={0}" -f (Get-ModelContainerPath $inf)),
    '-e', 'VLLM_API_KEY',
    '-v', ("{0}:/models:ro" -f (Join-Path $cfg['UAI_DATA_ROOT'] 'models'))
)
$port = $cfg['INFERENCE_HOST_PORT']
if ($port) { $dockerArgs += @('-p', ("127.0.0.1:{0}:8000" -f $port)) }
$dockerArgs += $image

Write-Step ("Starting {0}: {1} as '{2}' (max_model_len={3}, max_num_seqs={4}, gpu_mem={5})" -f $name, $inf['MODEL_REPO'], $inf['SERVED_MODEL_NAME'], $inf['MAX_MODEL_LEN'], $inf['MAX_NUM_SEQS'], $inf['GPU_MEMORY_UTILIZATION'])
$rc = Invoke-Native docker @dockerArgs
Remove-Item Env:\VLLM_API_KEY
if ($rc -ne 0) { throw "docker run failed for $name." }
if ($NoWait) { Write-Ok "Started. Follow startup with: docker logs -f $name"; return }

$timeout = [int]$cfg['INFERENCE_STARTUP_TIMEOUT']
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Step "Waiting up to $timeout s for the model to load (docker logs -f $name for detail)"
while ($sw.Elapsed.TotalSeconds -lt $timeout) {
    Start-Sleep -Seconds 10
    $s = Get-ContainerState $name
    if ($s -ne 'running') {
        $null = Invoke-Native docker logs --tail 40 $name
        throw "$name stopped during startup (state: $s). See logs above and docs\troubleshooting.md."
    }
    $healthy = $false
    if ($port) {
        try { $healthy = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/health").StatusCode -eq 200) } catch { }
    } else {
        $healthy = ((& docker inspect $name --format '{{.State.Health.Status}}') -eq 'healthy')
    }
    if ($healthy) {
        Write-Ok ("{0} healthy after {1:N0} s." -f $name, $sw.Elapsed.TotalSeconds)
        return
    }
    Write-Host ("  ... {0:N0} s" -f $sw.Elapsed.TotalSeconds)
}
throw "$name did not become healthy within $timeout s. Check: docker logs $name"
