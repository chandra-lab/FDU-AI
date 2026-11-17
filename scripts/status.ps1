<#
.SYNOPSIS
  Shows network, container, GPU, model-download and inference API status.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg

Write-Step 'GPU'
& nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv

if (-not (Test-DockerReady)) { Write-Fail 'Docker engine not reachable.'; return }

Write-Step 'Network'
$net = & docker network ls --filter "name=^$($cfg['UAI_NETWORK'])$" --format '{{.Name}}'
if ($net) { Write-Ok "network '$net' exists" } else { Write-Warn "network '$($cfg['UAI_NETWORK'])' missing (scripts\create-network.ps1)" }

Write-Step 'Containers'
& docker ps -a --filter 'label=project=university-ai' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

Write-Step 'Model'
$dir = Get-ModelLocalPath $cfg $inf
if (Test-ModelDownloaded -Config $cfg -InferenceProfile $inf) {
    Write-Ok ("{0}@{1} downloaded at {2}" -f $inf['MODEL_REPO'], $inf['MODEL_REVISION'].Substring(0, 8), $dir)
} elseif (Test-Path $dir) {
    $gb = (Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1e9
    Write-Warn ("download incomplete: {0:N2} GB in {1}" -f $gb, $dir)
    if ((Get-ContainerState 'university-ai-model-download') -eq 'running') { Write-Host '  download container running: docker logs -f university-ai-model-download' }
} else {
    Write-Warn 'not downloaded (scripts\download-model.ps1)'
}

Write-Step 'Inference API'
$port = $cfg['INFERENCE_HOST_PORT']
if ((Get-ContainerState $cfg['INFERENCE_CONTAINER']) -ne 'running') { Write-Warn "$($cfg['INFERENCE_CONTAINER']) not running"; return }
if (-not $port) { Write-Host '  INFERENCE_HOST_PORT empty; API only reachable inside the Docker network.'; return }
try {
    $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/health"
    Write-Ok "/health OK on 127.0.0.1:$port"
    $models = Invoke-RestMethod -TimeoutSec 5 -Headers @{ Authorization = "Bearer $($cfg['INFERENCE_API_KEY'])" } "http://127.0.0.1:$port/v1/models"
    foreach ($m in $models.data) { Write-Ok ("serving '{0}' (max_model_len {1})" -f $m.id, $m.max_model_len) }
} catch {
    Write-Warn "API not ready: $($_.Exception.Message)"
}
