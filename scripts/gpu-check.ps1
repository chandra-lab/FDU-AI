<#
.SYNOPSIS
  Verifies the GPU (Windows + Docker), Docker Model Runner (CUDA llama.cpp backend, localhost-only TCP),
  the pinned model digest, and that the profile's context size fits in VRAM.
  Writes <UAI_DATA_ROOT>\logs\compatibility-check.json; start-inference.ps1 refuses to pull or load
  the model without a recent PASS for the same profile.
.PARAMETER SkipDockerTest
  Skip the container nvidia-smi test (recorded as a warning).
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
if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
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
        $ccStatus = if ([double]$gpu.compute_capability -ge [double]$inf['MIN_COMPUTE_CAPABILITY']) { 'PASS' } else { 'FAIL' }
        Add-Check 'gpu.compute_capability' $ccStatus ("{0} (minimum {1})" -f $gpu.compute_capability, $inf['MIN_COMPUTE_CAPABILITY'])
    }
}

Write-Step 'Docker engine and GPU passthrough'
$dockerGpu = $null
if (-not (Test-DockerReady)) {
    Add-Check 'docker.engine' 'FAIL' 'Docker engine not reachable; start Docker Desktop.'
} else {
    Add-Check 'docker.engine' 'PASS' 'Docker reachable.'
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
            Add-Check 'docker.gpu' 'WARN' ("container GPU test failed (Model Runner runs on the host, so inference may still work): {0}" -f (($out | Select-Object -Last 2) -join ' '))
        }
    }
}

Write-Step 'Docker Model Runner'
$dmr = Get-DmrStatus
$modelId = $null; $loaded = $false
if (-not $dmr.Running) {
    Add-Check 'dmr.running' 'FAIL' 'Model Runner is not running: docker desktop enable model-runner --gpu=enable --tcp=12434 --cors=none'
} else {
    Add-Check 'dmr.running' 'PASS' 'Model Runner is running.'
    if ($dmr.LlamaStatus -eq 'Running' -and $dmr.LlamaDetails -match 'cuda') {
        Add-Check 'dmr.backend' 'PASS' ("llama.cpp {0}" -f $dmr.LlamaDetails)
    } elseif ($dmr.LlamaStatus -eq 'Running') {
        Add-Check 'dmr.backend' 'FAIL' ("llama.cpp is running without CUDA ({0}); expect ~3 tok/s on CPU. See docs\troubleshooting.md" -f $dmr.LlamaDetails)
    } else {
        Add-Check 'dmr.backend' 'FAIL' ("llama.cpp backend status '{0}': {1}. See docs\troubleshooting.md" -f $dmr.LlamaStatus, $dmr.LlamaDetails)
    }
    $listen = @(Get-NetTCPConnection -LocalPort ([int]$inf['DMR_TCP_PORT']) -State Listen -ErrorAction SilentlyContinue)
    if (-not $listen) {
        Add-Check 'dmr.tcp' 'WARN' ("host TCP {0} not enabled; start-inference.ps1 enables it" -f $inf['DMR_TCP_PORT'])
    } elseif (@($listen | Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' }).Count -gt 0) {
        Add-Check 'dmr.tcp' 'FAIL' ("port {0} is bound to {1}; it must be localhost-only" -f $inf['DMR_TCP_PORT'], (($listen.LocalAddress | Sort-Object -Unique) -join ', '))
    } else {
        Add-Check 'dmr.tcp' 'PASS' ("API on 127.0.0.1:{0} only" -f $inf['DMR_TCP_PORT'])
    }
    $modelId = Get-DmrModelId $inf
    if (-not $modelId) {
        Add-Check 'dmr.model' 'PASS' ("{0} not pulled yet; start-inference.ps1 will pull it (~17.5 GB)" -f $inf['MODEL_REF'])
    } elseif ($modelId -eq $inf['MODEL_DIGEST']) {
        Add-Check 'dmr.model' 'PASS' ("{0} present at tested digest {1}" -f $inf['MODEL_REF'], $modelId.Substring(7, 12))
    } else {
        Add-Check 'dmr.model' 'FAIL' ("{0} is {1}, not the tested {2}. Re-test and update MODEL_DIGEST deliberately; no silent substitution." -f $inf['MODEL_REF'], $modelId, $inf['MODEL_DIGEST'])
    }
    $loaded = Test-DmrModelLoaded $inf
}

Write-Step ("VRAM for profile '{0}' (context {1} tokens)" -f $cfg['INFERENCE_PROFILE'], $inf['CONTEXT_SIZE'])
$math = $null
if ($gpu) {
    $totalGiB = $gpu.total_mib / 1024
    $freeGiB = $gpu.free_mib / 1024
    $kv = [double]$inf['CONTEXT_SIZE'] * [double]$inf['KV_BYTES_PER_TOKEN'] / $GiB
    $required = [double]$inf['EST_BASE_GIB'] + $kv
    $margin = [double]$inf['VRAM_SAFETY_MARGIN_GIB']
    $math = [ordered]@{
        total_gib = [math]::Round($totalGiB, 2); free_gib = [math]::Round($freeGiB, 2)
        model_base_gib = [double]$inf['EST_BASE_GIB']; kv_cache_gib = [math]::Round($kv, 2)
        model_required_gib = [math]::Round($required, 2); safety_margin_gib = $margin
        model_loaded_now = $loaded
    }
    $math.GetEnumerator() | ForEach-Object { '    {0,-22} {1}' -f $_.Key, $_.Value } | Write-Host
    if ($loaded) {
        if ($freeGiB -ge $margin) { Add-Check 'vram.fit' 'PASS' ("model resident; {0:N2} GiB free >= {1} GiB margin" -f $freeGiB, $margin) }
        else { Add-Check 'vram.fit' 'WARN' ("model resident but only {0:N2} GiB free; desktop apps may push it into shared memory" -f $freeGiB) }
    } elseif ($required + $margin -le $freeGiB) {
        Add-Check 'vram.fit' 'PASS' ("needs {0:N2} GiB + {1} GiB margin; {2:N2} GiB free" -f $required, $margin, $freeGiB)
    } else {
        Add-Check 'vram.fit' 'FAIL' ("needs {0:N2} GiB + {1} GiB margin but only {2:N2} GiB free; lower CONTEXT_SIZE or free VRAM (other GPU apps/containers)" -f $required, $margin, $freeGiB)
    }
}

Write-Step 'Disk space (Model Runner stores models under %USERPROFILE%\.docker\models)'
$freeDiskGB = [math]::Round((Get-PSDrive (Split-Path -Qualifier $env:USERPROFILE).TrimEnd(':')).Free / 1e9, 1)
if ($modelId) { Add-Check 'disk.model' 'PASS' ("model already pulled; {0} GB free" -f $freeDiskGB) }
elseif ($freeDiskGB -ge 25) { Add-Check 'disk.model' 'PASS' ("{0} GB free >= 25 GB" -f $freeDiskGB) }
else { Add-Check 'disk.model' 'FAIL' ("{0} GB free < 25 GB needed" -f $freeDiskGB) }

$failed = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$overall = if ($failed -eq 0) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    status = $overall
    checked_at = (Get-Date).ToUniversalTime().ToString('o')
    host = $env:COMPUTERNAME
    profile = $cfg['INFERENCE_PROFILE']
    profile_sha256 = $inf['PROFILE_SHA256']
    target_model = $inf['TARGET_MODEL']
    model_ref = $inf['MODEL_REF']
    model_digest_expected = $inf['MODEL_DIGEST']
    model_digest_local = $modelId
    dmr_backend = $dmr.LlamaDetails
    gpu = $gpu
    docker_gpu = $dockerGpu
    vram = $math
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
