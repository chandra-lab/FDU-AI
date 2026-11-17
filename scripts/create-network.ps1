<#
.SYNOPSIS
  Creates the private Docker bridge network shared by all university-ai containers (idempotent).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
Assert-DockerReady

$name = $cfg['UAI_NETWORK']
$existing = & docker network ls --filter "name=^$name$" --format '{{.Name}}'
if ($existing -eq $name) {
    Write-Ok "Docker network '$name' already exists."
    return
}

Write-Step "Creating Docker network '$name'"
& docker network create --driver bridge --label "project=university-ai" $name | Out-Null
if ($LASTEXITCODE -ne 0) { throw "docker network create failed for '$name'." }
Write-Ok "Created Docker network '$name'."
