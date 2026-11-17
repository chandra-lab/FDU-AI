# Shared helpers dot-sourced by the scripts in ..\  (Windows PowerShell 5.1 compatible).

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Read-EnvFile {
    param([Parameter(Mandatory)] [string] $Path)
    $result = [ordered]@{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

# .env overrides .env.example so scripts work (with defaults) before setup.ps1 has run.
function Get-UaiConfig {
    $cfg = Read-EnvFile (Join-Path $script:RepoRoot '.env.example')
    $local = Read-EnvFile (Join-Path $script:RepoRoot '.env')
    foreach ($k in $local.Keys) { $cfg[$k] = $local[$k] }
    $cfg['REPO_ROOT'] = $script:RepoRoot
    return $cfg
}

function Get-InferenceProfile {
    param([Parameter(Mandatory)] $Config)
    $path = Join-Path $script:RepoRoot ("inference\configs\{0}.env" -f $Config['INFERENCE_PROFILE'])
    if (-not (Test-Path $path)) { throw "Inference profile not found: $path" }
    $p = Read-EnvFile $path
    $p['PROFILE_PATH'] = $path
    $p['PROFILE_SHA256'] = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
    return $p
}

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string] $Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }

# Windows PowerShell 5.1 turns native stderr into terminating errors under 'Stop', even with 2>$null.
# Probes whose failure is an expected answer run through this with 'Continue'.
function Invoke-NativeQuiet {
    param([Parameter(Mandatory)] [string] $Exe, [Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>$null
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

# Runs a native command, streaming stdout+stderr to the host, and returns its exit code.
function Invoke-Native {
    param([Parameter(Mandatory)] [string] $Exe, [Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
    return $LASTEXITCODE
}

function Test-DockerReady {
    return ((Invoke-NativeQuiet docker info --format '{{.ServerVersion}}').ExitCode -eq 0)
}

function Assert-DockerReady {
    if (-not (Test-DockerReady)) {
        throw 'Docker engine is not reachable. Start Docker Desktop (Linux containers / WSL2) and retry.'
    }
}

function Get-ContainerState {
    param([Parameter(Mandatory)] [string] $Name)
    $r = Invoke-NativeQuiet docker container inspect $Name --format '{{.State.Status}}'
    if ($r.ExitCode -ne 0) { return $null }
    return "$($r.Output)".Trim()
}

# Weights are stored as plain files (hf download --local-dir), not in the symlinked HF hub cache:
# symlinks created by Linux containers on a Windows bind mount are not reliably readable from Windows.
function Get-ModelDirName {
    param([Parameter(Mandatory)] $InferenceProfile)
    return ($InferenceProfile['MODEL_REPO'] -replace '/', '--')
}

function Get-ModelLocalPath {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $InferenceProfile)
    return Join-Path $Config['UAI_DATA_ROOT'] ("models\{0}" -f (Get-ModelDirName $InferenceProfile))
}

function Get-ModelContainerPath {
    param([Parameter(Mandatory)] $InferenceProfile)
    return '/models/' + (Get-ModelDirName $InferenceProfile)
}

# Gate used before any weight download or inference start: requires a PASS report from gpu-check.ps1
# for the exact current profile file, no older than MaxAgeHours.
function Assert-CompatibilityPass {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $InferenceProfile, [int] $MaxAgeHours = 24)
    $path = Join-Path $Config['UAI_DATA_ROOT'] 'logs\compatibility-check.json'
    $hint = 'Run scripts\gpu-check.ps1 first.'
    if (-not (Test-Path $path)) { throw "No compatibility report at $path. $hint" }
    $r = Get-Content $path -Raw | ConvertFrom-Json
    if ($r.status -ne 'PASS') { throw "Last compatibility check status is '$($r.status)'. Fix the failing checks in $path. $hint" }
    if ($r.profile_sha256 -ne $InferenceProfile['PROFILE_SHA256']) { throw "Profile '$($Config['INFERENCE_PROFILE'])' changed since the last check. $hint" }
    $age = (Get-Date).ToUniversalTime() - ([datetime]::Parse($r.checked_at)).ToUniversalTime()
    if ($age.TotalHours -gt $MaxAgeHours) { throw ("Compatibility report is {0:N1} h old (max {1} h). {2}" -f $age.TotalHours, $MaxAgeHours, $hint) }
    Write-Ok ("Compatibility check PASS for '{0}' at {1}" -f $r.profile, $r.checked_at)
}

function Test-ModelDownloaded {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $InferenceProfile)
    $dir = Get-ModelLocalPath -Config $Config -InferenceProfile $InferenceProfile
    $marker = Join-Path $dir '.uai-download.json'
    if (-not (Test-Path $marker)) { return $false }
    $m = Get-Content $marker -Raw | ConvertFrom-Json
    if ($m.revision -ne $InferenceProfile['MODEL_REVISION'] -or $m.status -ne 'complete') { return $false }
    $index = Join-Path $dir 'model.safetensors.index.json'
    if (-not (Test-Path $index)) { return $false }
    $files = (Get-Content $index -Raw | ConvertFrom-Json).weight_map.PSObject.Properties.Value | Sort-Object -Unique
    foreach ($f in $files) {
        $p = Join-Path $dir $f
        if (-not (Test-Path $p) -or (Get-Item $p).Length -eq 0) { return $false }
    }
    return $true
}
