<#
.SYNOPSIS
  One-time host setup: persistent data directories, .env, Docker network.
  Safe to re-run; never overwrites an existing .env or existing data.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$envPath = Join-Path $RepoRoot '.env'
if (Test-Path $envPath) {
    Write-Ok ".env already exists; leaving it unchanged."
} else {
    Write-Step 'Creating .env from .env.example'
    Copy-Item (Join-Path $RepoRoot '.env.example') $envPath
    Write-Ok '.env created.'
}

$cfg = Get-UaiConfig
$root = $cfg['UAI_DATA_ROOT']
Write-Step "Creating persistent data directories under $root"
foreach ($sub in 'postgres', 'qdrant', 'logs', 'backups') {
    $p = Join-Path $root $sub
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p | Out-Null
        Write-Ok "Created $p"
    } else {
        Write-Ok "Exists  $p"
    }
}

if (Test-DockerReady) {
    & (Join-Path $PSScriptRoot 'create-network.ps1')
} else {
    Write-Warn 'Docker engine not reachable; start Docker Desktop and run scripts\create-network.ps1.'
}

Write-Host ''
Write-Host 'Next: scripts\gpu-check.ps1  (must PASS before scripts\start-inference.ps1 will pull or load the model)'
