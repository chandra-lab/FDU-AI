<#
.SYNOPSIS
  Makes Qwen3.8-27B available through Docker Desktop Model Runner:
  enables Model Runner (GPU, localhost-only TCP), pulls the model if missing and verifies its digest,
  applies the profile's runtime config (context size, keep-alive) and loads it with a warm-up request.
.PARAMETER Reload
  Unload the model first so a changed CONTEXT_SIZE / KEEP_ALIVE takes effect.
#>
[CmdletBinding()]
param([switch] $Reload)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
Assert-DockerReady
$ref = $inf['MODEL_REF']
$port = $inf['DMR_TCP_PORT']

$dmr = Get-DmrStatus
if (-not $dmr.Running -or -not (Test-DmrTcpListening $inf)) {
    Write-Step "Enabling Docker Model Runner (GPU, TCP 127.0.0.1:$port, CORS off)"
    $rc = Invoke-Native docker desktop enable model-runner --gpu=enable "--tcp=$port" --cors=none
    if ($rc -ne 0) { throw 'docker desktop enable model-runner failed.' }
    Start-Sleep -Seconds 5
    $dmr = Get-DmrStatus
}
if (-not $dmr.Running) { throw 'Model Runner is not running. See docs\troubleshooting.md.' }
if ($dmr.LlamaStatus -ne 'Running' -or $dmr.LlamaDetails -notmatch 'cuda') {
    throw ("llama.cpp CUDA backend not ready (status '{0}': {1}). See docs\troubleshooting.md." -f $dmr.LlamaStatus, $dmr.LlamaDetails)
}
Write-Ok "Model Runner backend: llama.cpp $($dmr.LlamaDetails)"

Assert-CompatibilityPass -Config $cfg -InferenceProfile $inf

$id = Get-DmrModelId $inf
if (-not $id) {
    Write-Step "Pulling $ref (~17.5 GB)"
    $rc = Invoke-Native docker model pull $ref
    if ($rc -ne 0) { throw "docker model pull $ref failed." }
    $id = Get-DmrModelId $inf
}
if ($id -ne $inf['MODEL_DIGEST']) {
    throw ("{0} resolves to {1}, not the tested digest {2}. Not loading it; re-test and update MODEL_DIGEST deliberately." -f $ref, $id, $inf['MODEL_DIGEST'])
}
Write-Ok ("{0} at tested digest {1}" -f $ref, $id.Substring(7, 12))

if ($Reload -and (Test-DmrModelLoaded $inf)) {
    Write-Step 'Unloading the model to apply new runtime settings'
    $null = Invoke-DmrUnloadAll
}

Write-Step ("Configuring {0}: context-size={1}, keep-alive={2}" -f $ref, $inf['CONTEXT_SIZE'], $inf['KEEP_ALIVE'])
$rc = Invoke-Native docker model configure ("--context-size={0}" -f $inf['CONTEXT_SIZE']) ("--keep-alive={0}" -f $inf['KEEP_ALIVE']) $ref
if ($rc -ne 0) { throw 'docker model configure failed.' }

Write-Step 'Loading the model (warm-up request)'
$body = @{
    model = $inf['SERVED_MODEL_ID']; max_tokens = 1
    messages = @(@{ role = 'user'; content = 'ping' })
    chat_template_kwargs = @{ enable_thinking = $false }
} | ConvertTo-Json -Depth 5
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $null = Invoke-RestMethod -Method Post -TimeoutSec ([int]$cfg['INFERENCE_STARTUP_TIMEOUT']) -ContentType 'application/json' -Body $body ("{0}/chat/completions" -f (Get-DmrBaseUrl $inf))
} catch {
    throw "Warm-up request failed after $([int]$sw.Elapsed.TotalSeconds) s: $($_.Exception.Message). Check: docker model logs"
}
if (-not (Test-DmrModelLoaded $inf)) { throw 'Warm-up answered but the model is not listed by docker model ps.' }
Write-Ok ("{0} loaded and answering after {1:N0} s." -f $inf['TARGET_MODEL_DISPLAY_NAME'], $sw.Elapsed.TotalSeconds)
Write-Host ("  Host API:      {0}" -f (Get-DmrBaseUrl $inf))
Write-Host ("  Container API: {0}" -f $inf['DMR_CONTAINER_BASE_URL'])
