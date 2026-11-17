<#
.SYNOPSIS
  Smoke-tests the inference OpenAI-compatible API on 127.0.0.1: auth enforcement, /v1/models,
  a non-thinking chat completion, a thinking-mode completion, and streaming.
#>
[CmdletBinding()]
param([int] $MaxTokens = 256)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
$port = $cfg['INFERENCE_HOST_PORT']
if (-not $port) { throw 'INFERENCE_HOST_PORT is empty; the API is not published on localhost.' }
$base = "http://127.0.0.1:$port"
$headers = @{ Authorization = "Bearer $($cfg['INFERENCE_API_KEY'])" }
$model = $inf['SERVED_MODEL_NAME']
$failed = 0

Write-Step 'Unauthenticated request must be rejected'
try {
    $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "$base/v1/models"
    Write-Fail 'API accepted a request without a key.'; $failed++
} catch {
    $code = [int]$_.Exception.Response.StatusCode
    if ($code -eq 401) { Write-Ok 'HTTP 401 without key.' } else { Write-Fail "Unexpected status $code"; $failed++ }
}

Write-Step '/v1/models'
$models = Invoke-RestMethod -TimeoutSec 10 -Headers $headers "$base/v1/models"
$ids = @($models.data | ForEach-Object { $_.id })
if ($ids -contains $model) { Write-Ok ("serving {0} (max_model_len {1})" -f $model, ($models.data | Where-Object id -eq $model).max_model_len) }
else { Write-Fail "model '$model' not in $($ids -join ', ')"; $failed++ }

function Invoke-Chat([hashtable] $Extra, [string] $Prompt) {
    $body = @{
        model = $model; max_tokens = $MaxTokens
        messages = @(@{ role = 'user'; content = $Prompt })
    }
    foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
    $json = $body | ConvertTo-Json -Depth 6
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Post -TimeoutSec 600 -Headers $headers -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) "$base/v1/chat/completions"
    $sw.Stop()
    $tps = if ($sw.Elapsed.TotalSeconds -gt 0) { $r.usage.completion_tokens / $sw.Elapsed.TotalSeconds } else { 0 }
    [pscustomobject]@{ Response = $r; Seconds = $sw.Elapsed.TotalSeconds; TokPerSec = $tps }
}

Write-Step 'Chat completion, thinking disabled (Qwen instruct sampling)'
$nt = Invoke-Chat @{ temperature = 0.7; top_p = 0.8; top_k = 20; presence_penalty = 1.5; chat_template_kwargs = @{ enable_thinking = $false } } 'In one sentence, what is a university registrar?'
$text = $nt.Response.choices[0].message.content
if ($text) { Write-Ok ("{0} tokens in {1:N1} s ({2:N1} tok/s): {3}" -f $nt.Response.usage.completion_tokens, $nt.Seconds, $nt.TokPerSec, $text.Trim()) }
else { Write-Fail 'empty content'; $failed++ }

Write-Step 'Chat completion, thinking enabled (reasoning parsed separately)'
$th = Invoke-Chat @{ temperature = 1.0; top_p = 0.95; top_k = 20; chat_template_kwargs = @{ reasoning_effort = 'low' } } 'What is 17 * 23? Reply with just the number.'
$msg = $th.Response.choices[0].message
$reasoning = if ($msg.reasoning_content) { $msg.reasoning_content } else { $msg.reasoning }
Write-Ok ("{0} tokens in {1:N1} s ({2:N1} tok/s); reasoning chars={3}; finish={4}; content: {5}" -f $th.Response.usage.completion_tokens, $th.Seconds, $th.TokPerSec, ("$reasoning").Length, $th.Response.choices[0].finish_reason, ("$($msg.content)").Trim())

Write-Step 'Streaming'
$body = @{ model = $model; max_tokens = 64; stream = $true; messages = @(@{ role = 'user'; content = 'Count from 1 to 10.' }); chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 6
$req = [System.Net.HttpWebRequest]::Create("$base/v1/chat/completions")
$req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 120000
$req.Headers.Add('Authorization', $headers.Authorization)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
$reader = New-Object System.IO.StreamReader($req.GetResponse().GetResponseStream())
$chunks = 0; $done = $false
while (-not $reader.EndOfStream) {
    $line = $reader.ReadLine()
    if ($line -eq 'data: [DONE]') { $done = $true; break }
    if ($line.StartsWith('data: ')) { $chunks++ }
}
$reader.Close()
if ($done -and $chunks -gt 1) { Write-Ok "received $chunks SSE chunks and [DONE]" } else { Write-Fail "stream incomplete (chunks=$chunks, done=$done)"; $failed++ }

Write-Host ''
if ($failed -eq 0) { Write-Ok 'All inference smoke tests passed.' } else { Write-Fail "$failed test(s) failed." }
exit ([int]($failed -ne 0))
