<#
.SYNOPSIS
  Smoke-tests Qwen3.8-27B on Docker Model Runner: model listing, localhost-only exposure,
  non-thinking and thinking chat, streaming, and access from a container on the university-ai network.
.PARAMETER Benchmark
  Also measure decode speed for 1 and 4 parallel requests (512 tokens each).
#>
[CmdletBinding()]
param([int] $MaxTokens = 256, [switch] $Benchmark)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
$cfg = Get-UaiConfig
$inf = Get-InferenceProfile $cfg
$base = Get-DmrBaseUrl $inf
$model = $inf['SERVED_MODEL_ID']
$failed = 0

Write-Step "GET $base/models"
$models = Invoke-RestMethod -TimeoutSec 10 "$base/models"
$ids = @($models.data | ForEach-Object { $_.id })
if ($ids -contains $model) { Write-Ok "serving $model" } else { Write-Fail "model '$model' not in $($ids -join ', ')"; $failed++ }

Write-Step 'API must not be reachable on LAN addresses'
$lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback' } | ForEach-Object { $_.IPAddress })
foreach ($ip in $lanIps) {
    $client = New-Object System.Net.Sockets.TcpClient
    $open = $false
    try { $open = $client.ConnectAsync($ip, [int]$inf['DMR_TCP_PORT']).Wait(2000) } catch { }
    $client.Close()
    if ($open) { Write-Fail "port $($inf['DMR_TCP_PORT']) is reachable on $ip"; $failed++ } else { Write-Ok "not reachable on $ip" }
}

function Invoke-Chat([hashtable] $Extra, [string] $Prompt, [int] $Tokens = $MaxTokens) {
    $body = @{ model = $model; max_tokens = $Tokens; messages = @(@{ role = 'user'; content = $Prompt }) }
    foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
    $json = $body | ConvertTo-Json -Depth 6
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Post -TimeoutSec 600 -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) "$base/chat/completions"
    $sw.Stop()
    [pscustomobject]@{ Response = $r; Seconds = $sw.Elapsed.TotalSeconds; TokPerSec = $r.usage.completion_tokens / [math]::Max($sw.Elapsed.TotalSeconds, 0.001) }
}

Write-Step 'Chat completion, thinking disabled (Qwen instruct sampling)'
$nt = Invoke-Chat @{ temperature = 0.7; top_p = 0.8; top_k = 20; presence_penalty = 1.5; chat_template_kwargs = @{ enable_thinking = $false } } 'In one sentence, what is a university registrar?'
$msg = $nt.Response.choices[0].message
if ($msg.content -and -not $msg.reasoning_content) { Write-Ok ("{0} tokens in {1:N1} s: {2}" -f $nt.Response.usage.completion_tokens, $nt.Seconds, $msg.content.Trim()) }
else { Write-Fail ("unexpected response (content='{0}', reasoning chars={1})" -f $msg.content, ("$($msg.reasoning_content)").Length); $failed++ }

Write-Step 'Chat completion, thinking enabled (reasoning returned separately)'
$th = Invoke-Chat @{ temperature = 1.0; top_p = 0.95; top_k = 20 } 'What is 17 * 23? Reply with just the number.' 1024
$msg = $th.Response.choices[0].message
$reasoning = "$($msg.reasoning_content)"
if ($reasoning.Length -gt 0 -and "$($msg.content)" -match '391') { Write-Ok ("{0} tokens in {1:N1} s; reasoning chars={2}; answer: {3}" -f $th.Response.usage.completion_tokens, $th.Seconds, $reasoning.Length, $msg.content.Trim()) }
else { Write-Fail ("reasoning chars={0}, content='{1}', finish={2}" -f $reasoning.Length, $msg.content, $th.Response.choices[0].finish_reason); $failed++ }

Write-Step 'Tool calling'
$tool = @{ type = 'function'; function = @{ name = 'get_weather'; description = 'Get the weather for a city'; parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') } } }
$tc = Invoke-Chat @{ tools = @($tool); chat_template_kwargs = @{ enable_thinking = $false } } 'What is the weather in Paris? Use the tool.'
$call = $tc.Response.choices[0].message.tool_calls | Select-Object -First 1
if ($call.function.name -eq 'get_weather' -and $call.function.arguments -match 'Paris') { Write-Ok ("get_weather({0})" -f $call.function.arguments) }
else { Write-Fail ("no tool call (finish={0})" -f $tc.Response.choices[0].finish_reason); $failed++ }

Write-Step 'Streaming'
$body = @{ model = $model; max_tokens = 64; stream = $true; messages = @(@{ role = 'user'; content = 'Count from 1 to 10.' }); chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 6
$req = [System.Net.HttpWebRequest]::Create("$base/chat/completions")
$req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 120000
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

Write-Step ("Container on '{0}' -> {1}" -f $cfg['UAI_NETWORK'], $inf['DMR_CONTAINER_BASE_URL'])
$rc = Invoke-Native docker run --rm --network $cfg['UAI_NETWORK'] ("--volume={0}:/check:ro" -f (Join-Path $RepoRoot 'inference\scripts')) $cfg['NET_TEST_IMAGE'] python /check/net-check.py $inf['DMR_CONTAINER_BASE_URL'] $model
if ($rc -eq 0) { Write-Ok 'backend network path works' } else { Write-Fail 'container could not reach Model Runner'; $failed++ }

if ($Benchmark) {
    Write-Step 'Decode benchmark (512 tokens, thinking off)'
    $benchBody = @{ model = $model; max_tokens = 512; temperature = 0.7; top_p = 0.8; messages = @(@{ role = 'user'; content = 'Write a long, detailed essay about the history of universities in Europe.' }); chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
    foreach ($n in 1, 4) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $jobs = 1..$n | ForEach-Object {
            Start-Job -ArgumentList $benchBody, "$base/chat/completions" -ScriptBlock {
                param($b, $u)
                $t = [System.Diagnostics.Stopwatch]::StartNew()
                $r = Invoke-RestMethod -Method Post -Uri $u -ContentType 'application/json' -Body $b -TimeoutSec 900
                [pscustomobject]@{ tokens = $r.usage.completion_tokens; seconds = $t.Elapsed.TotalSeconds }
            }
        }
        $res = $jobs | Wait-Job | Receive-Job; $jobs | Remove-Job
        $total = ($res | Measure-Object tokens -Sum).Sum
        Write-Ok ("parallel={0}: {1:N1} tok/s aggregate, {2:N1} tok/s per request (wall {3:N1} s)" -f $n, ($total / $sw.Elapsed.TotalSeconds), (($res | ForEach-Object { $_.tokens / $_.seconds } | Measure-Object -Average).Average), $sw.Elapsed.TotalSeconds)
    }
}

Write-Host ''
if ($failed -eq 0) { Write-Ok 'All inference smoke tests passed.' } else { Write-Fail "$failed test(s) failed." }
exit ([int]($failed -ne 0))
