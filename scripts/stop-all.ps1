<#
.SYNOPSIS
  Stops every university-ai container and unloads the model from Docker Model Runner (frees VRAM).
  Model Runner itself stays enabled and pulled models are kept; data under UAI_DATA_ROOT is never touched.
.PARAMETER Remove
  Also remove the stopped containers (images, network and data are kept).
.PARAMETER KeepModelLoaded
  Leave the model resident in Model Runner.
#>
[CmdletBinding()]
param([switch] $Remove, [switch] $KeepModelLoaded)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
Assert-DockerReady

$names = @('university-ai-nginx', 'university-ai-frontend', 'university-ai-backend', 'university-ai-qdrant', 'university-ai-postgres')
foreach ($n in $names) {
    $state = Get-ContainerState $n
    if (-not $state) { continue }
    if ($state -eq 'running') {
        Write-Step "Stopping $n"
        & docker stop --timeout 60 $n | Out-Null
    }
    if ($Remove) {
        & docker rm $n | Out-Null
        Write-Ok "Removed $n"
    } else {
        Write-Ok "$n stopped"
    }
}

if (-not $KeepModelLoaded -and (Test-DmrModelLoaded $inf)) {
    Write-Step 'Unloading the model from Docker Model Runner'
    $null = Invoke-DmrUnloadAll
    if (Test-DmrModelLoaded $inf) { Write-Fail 'Model is still loaded; see docs\troubleshooting.md.'; exit 1 }
    Write-Ok 'Model unloaded (VRAM released). scripts\start-inference.ps1 loads it again.'
}
Write-Ok 'All university-ai services are stopped.'
