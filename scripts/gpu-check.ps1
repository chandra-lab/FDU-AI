<#
.SYNOPSIS
  Verifies the GPU on Windows and inside Docker, then checks that the selected inference profile
  fits in VRAM and on disk. Writes <UAI_DATA_ROOT>\logs\compatibility-check.json.
  download-model.ps1 and start-inference.ps1 refuse to run without a recent PASS for the same profile.
.PARAMETER SkipDockerTest
  Skip the container nvidia-smi test (not recommended; the result is recorded as not verified).
#>
[CmdletBinding()]
param([switch] $SkipDockerTest)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string] $Name, [string] $Status, [string] $Detail) {
    $checks.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
    switch ($Status) { 'PASS' { Write-Ok "$Name - $Detail" } 'WARN' { Write-Warn "$Name - $Detail" } default { Write-Fail "$Name - $Detail" } }
}
$GiB = [math]::Pow(2, 30)

Write-Step 'Host GPU (nvidia-smi on Windows)'
$gpu = $null
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Add-Check 'host.nvidia-smi' 'FAIL' 'nvidia-smi not found; install/repair the NVIDIA Windows driver.'
} else {
    $lines = @(& nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,driver_version,compute_cap --format=csv,noheader,nounits 2>$null)
    $line = $lines | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or -not $line) {
        Add-Check 'host.nvidia-smi' 'FAIL' 'nvidia-smi returned no GPU.'
    } else {
        $f = $line -split ',\s*'
        $gpu = [pscustomobject]@{
            name = $f[0]; total_mib = [int]$f[1]; used_mib = [int]$f[2]; free_mib = [int]$f[3]
            driver = $f[4]; compute_capability = $f[5]
        }
        Add-Check 'host.nvidia-smi' 'PASS' ("{0}, driver {1}, compute {2}, {3} MiB total / {4} MiB free" -f $gpu.name, $gpu.driver, $gpu.compute_capability, $gpu.total_mib, $gpu.free_mib)
        if ([double]$gpu.compute_capability -ge [double]$inf['MIN_COMPUTE_CAPABILITY']) {
            Add-Check 'gpu.compute_capability' 'PASS' ("{0} >= {1} required by {2}" -f $gpu.compute_capability, $inf['MIN_COMPUTE_CAPABILITY'], $inf['QUANTIZATION'])
        } else {
            Add-Check 'gpu.compute_capability' 'FAIL' ("{0} < {1} required by {2}" -f $gpu.compute_capability, $inf['MIN_COMPUTE_CAPABILITY'], $inf['QUANTIZATION'])
        }
    }
}

Write-Step 'Docker GPU passthrough'
$dockerGpu = $null
if (-not (Test-DockerReady)) {
    Add-Check 'docker.engine' 'FAIL' 'Docker engine not reachable; start Docker Desktop.'
} else {
    $runtimes = & docker info --format '{{json .Runtimes}}' | ConvertFrom-Json
    if ($runtimes.PSObject.Properties.Name -contains 'nvidia') {
        Add-Check 'docker.engine' 'PASS' 'Docker reachable; nvidia runtime registered.'
    } else {
        Add-Check 'docker.engine' 'WARN' 'Docker reachable; no nvidia runtime listed (Docker Desktop may still support --gpus).'
    }
    if ($SkipDockerTest) {
        Add-Check 'docker.gpu' 'WARN' 'Skipped by -SkipDockerTest.'
    } else {
        $ErrorActionPreference = 'Continue'
        $out = @(& docker run --rm --gpus all $cfg['CUDA_TEST_IMAGE'] nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1)
        $dockerExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($dockerExit -eq 0) {
            $dockerGpu = ($out | Select-Object -Last 1).ToString().Trim()
            Add-Check 'docker.gpu' 'PASS' ("{0} sees: {1}" -f $cfg['CUDA_TEST_IMAGE'], $dockerGpu)
        } else {
            Add-Check 'docker.gpu' 'FAIL' ("docker run --gpus all failed: {0}" -f (($out | Select-Object -Last 3) -join ' '))
        }
    }
}

Write-Step ("VRAM budget for profile '{0}' ({1} via {2})" -f $cfg['INFERENCE_PROFILE'], $inf['TARGET_MODEL'], $inf['MODEL_REPO'])
$math = $null
if ($gpu) {
    $totalGiB = $gpu.total_mib / 1024
    $freeGiB = $gpu.free_mib / 1024
    $util = [double]$inf['GPU_MEMORY_UTILIZATION']
    $budget = $util * $totalGiB
    $kv = [double]$inf['MAX_MODEL_LEN'] * [double]$inf['KV_BYTES_PER_TOKEN'] / $GiB
    $state = [double]$inf['MAX_NUM_SEQS'] * [double]$inf['STATE_BYTES_PER_SEQ'] / $GiB
    $required = [double]$inf['EST_WEIGHTS_GIB'] + [double]$inf['EST_RUNTIME_OVERHEAD_GIB'] + $kv + $state
    $math = [ordered]@{
        total_gib = [math]::Round($totalGiB, 2); free_gib = [math]::Round($freeGiB, 2)
        gpu_memory_utilization = $util; vllm_budget_gib = [math]::Round($budget, 2)
        weights_gib = [double]$inf['EST_WEIGHTS_GIB']; overhead_gib = [double]$inf['EST_RUNTIME_OVERHEAD_GIB']
        kv_one_full_sequence_gib = [math]::Round($kv, 2); linear_attention_state_gib = [math]::Round($state, 2)
        required_minimum_gib = [math]::Round($required, 2); headroom_for_extra_kv_gib = [math]::Round($budget - $required, 2)
    }
    $math.GetEnumerator() | ForEach-Object { '    {0,-28} {1}' -f $_.Key, $_.Value } | Write-Host

    if ($required -le $budget) {
        Add-Check 'vram.fit' 'PASS' ("needs {0:N2} GiB of a {1:N2} GiB vLLM budget ({2:N2} GiB spare for KV cache)" -f $required, $budget, ($budget - $required))
    } else {
        Add-Check 'vram.fit' 'FAIL' ("needs {0:N2} GiB but the vLLM budget is {1:N2} GiB; lower MAX_MODEL_LEN/MAX_NUM_SEQS or choose another checkpoint (no automatic substitution)" -f $required, $budget)
    }

    $containerState = Get-ContainerState $cfg['INFERENCE_CONTAINER']
    if ($containerState -eq 'running') {
        Add-Check 'vram.free_at_start' 'PASS' ("{0} is running and holds its memory; free-memory check skipped" -f $cfg['INFERENCE_CONTAINER'])
    } elseif ($freeGiB -ge $budget + 0.5) {
        Add-Check 'vram.free_at_start' 'PASS' ("{0:N2} GiB free >= {1:N2} GiB budget + 0.5 GiB margin" -f $freeGiB, $budget)
    } elseif ($freeGiB -ge $budget) {
        Add-Check 'vram.free_at_start' 'WARN' ("{0:N2} GiB free is within 0.5 GiB of the {1:N2} GiB budget; close GPU-heavy desktop apps before starting" -f $freeGiB, $budget)
    } else {
        Add-Check 'vram.free_at_start' 'FAIL' ("only {0:N2} GiB free; vLLM needs {1:N2} GiB free at startup (close GPU apps or lower GPU_MEMORY_UTILIZATION)" -f $freeGiB, $budget)
    }
}

Write-Step 'Disk space'
$modelReady = Test-ModelDownloaded -Config $cfg -InferenceProfile $inf
$drive = Split-Path -Qualifier $cfg['UAI_DATA_ROOT']
$freeDiskGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':'))).Free / 1e9, 1)
if ($modelReady) {
    Add-Check 'disk.model' 'PASS' ("weights already present ({0}); {1} GB free on {2}" -f $inf['MODEL_REVISION'].Substring(0, 8), $freeDiskGB, $drive)
} elseif ($freeDiskGB -ge [double]$inf['REQUIRED_DISK_GB']) {
    Add-Check 'disk.model' 'PASS' ("{0} GB free on {1} >= {2} GB needed" -f $freeDiskGB, $drive, $inf['REQUIRED_DISK_GB'])
} else {
    Add-Check 'disk.model' 'FAIL' ("{0} GB free on {1} < {2} GB needed" -f $freeDiskGB, $drive, $inf['REQUIRED_DISK_GB'])
}

$failed = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$overall = if ($failed -eq 0) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    status = $overall
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    host = $env:COMPUTERNAME
    profile = $cfg['INFERENCE_PROFILE']
    profile_sha256 = $inf['PROFILE_SHA256']
    target_model = $inf['TARGET_MODEL']
    model_repo = $inf['MODEL_REPO']
    model_revision = $inf['MODEL_REVISION']
    gpu = $gpu
    docker_gpu = $dockerGpu
    vram = $math
    model_downloaded = $modelReady
    checks = $checks
}
$logDir = Join-Path $cfg['UAI_DATA_ROOT'] 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$reportPath = Join-Path $logDir 'compatibility-check.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8

Write-Host ''
if ($overall -eq 'PASS') { Write-Ok "Compatibility check PASSED. Report: $reportPath" }
else { Write-Fail "Compatibility check FAILED ($failed failing check(s)). Report: $reportPath" }
exit ([int]($overall -ne 'PASS'))
