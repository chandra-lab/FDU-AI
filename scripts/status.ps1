<#
.SYNOPSIS
  Shows GPU, Docker network, containers, Docker Model Runner and inference API status.
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

Write-Step 'Docker Model Runner'
$dmr = Get-DmrStatus
if (-not $dmr.Running) { Write-Fail 'Model Runner not running.'; return }
if ($dmr.LlamaDetails -match 'cuda') { Write-Ok "llama.cpp $($dmr.LlamaDetails)" } else { Write-Warn "llama.cpp $($dmr.LlamaStatus): $($dmr.LlamaDetails)" }
$id = Get-DmrModelId $inf
if ($id -eq $inf['MODEL_DIGEST']) { Write-Ok ("{0} pulled at tested digest" -f $inf['MODEL_REF']) }
elseif ($id) { Write-Warn ("{0} digest {1} differs from tested {2}" -f $inf['MODEL_REF'], $id, $inf['MODEL_DIGEST']) }
else { Write-Warn ("{0} not pulled (scripts\start-inference.ps1)" -f $inf['MODEL_REF']) }
$null = Invoke-Native docker model ps

Write-Step 'Inference API'
if (-not (Test-DmrTcpListening $inf)) { Write-Warn "host TCP $($inf['DMR_TCP_PORT']) not enabled (scripts\start-inference.ps1)"; return }
try {
    $models = Invoke-RestMethod -TimeoutSec 5 ("{0}/models" -f (Get-DmrBaseUrl $inf))
    foreach ($m in $models.data) { Write-Ok ("API lists '{0}' at {1}" -f $m.id, (Get-DmrBaseUrl $inf)) }
} catch {
    Write-Warn "API not answering: $($_.Exception.Message)"
}
