<#
.SYNOPSIS
  Stops every university-ai container. Data under UAI_DATA_ROOT is never touched.
.PARAMETER Remove
  Also remove the stopped containers (images, network and data are kept).
#>
[CmdletBinding()]
param([switch] $Remove)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
Assert-DockerReady

$names = @(
    'university-ai-nginx', 'university-ai-frontend', 'university-ai-backend',
    $cfg['INFERENCE_CONTAINER'], 'university-ai-qdrant', 'university-ai-postgres',
    'university-ai-model-download'
)
foreach ($n in $names) {
    $state = Get-ContainerState $n
    if (-not $state) { continue }
    if ($state -eq 'running') {
        Write-Step "Stopping $n"
        & docker stop --time 60 $n | Out-Null
    }
    if ($Remove) {
        & docker rm $n | Out-Null
        Write-Ok "Removed $n"
    } else {
        Write-Ok "$n stopped"
    }
}
Write-Ok 'All university-ai containers are stopped.'
