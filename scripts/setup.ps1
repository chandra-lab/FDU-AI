<#
.SYNOPSIS
  One-time host setup: persistent data directories, .env with generated secrets, Docker network.
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
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $apiKey = 'uai-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    $content = (Get-Content (Join-Path $RepoRoot '.env.example') -Raw) -replace 'INFERENCE_API_KEY=CHANGE_ME', "INFERENCE_API_KEY=$apiKey"
    [System.IO.File]::WriteAllText($envPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ".env created with a generated INFERENCE_API_KEY."
}

$cfg = Get-UaiConfig
$root = $cfg['UAI_DATA_ROOT']
Write-Step "Creating persistent data directories under $root"
foreach ($sub in 'models', 'hf-cache', 'postgres', 'qdrant', 'logs', 'logs\inference', 'backups') {
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
Write-Host 'Next: scripts\gpu-check.ps1  (must PASS before scripts\download-model.ps1 will run)'
