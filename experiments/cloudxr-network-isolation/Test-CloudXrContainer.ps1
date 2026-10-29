# Replays the final trial on the recorded Windows/621.01 environment.
# Requires the prepared out/sdk-runtime copy documented in RESULTS.md.
$ErrorActionPreference = 'Stop'
$labRoot = $PSScriptRoot
$engine = Get-Content -LiteralPath (Join-Path $labRoot 'state\engine.json') -Raw | ConvertFrom-Json
if ($engine.DockerClient -ne (Join-Path $labRoot 'out\tools\engine-29.9.2\docker\docker.exe') -or $engine.HostEndpoint -ne 'npipe:////./pipe/streamingsession-cloudxr-lab') { throw 'Unexpected lab engine.' }
$run = Join-Path (Join-Path $labRoot 'state') ('sdk-inspect-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $run
$payload = Join-Path $labRoot 'out\payload'
$runtime = Join-Path $labRoot 'out\sdk-runtime'
Copy-Item -LiteralPath (Join-Path $labRoot 'Container-SdkProbe.ps1') -Destination (Join-Path $payload 'Inspect-Sdk.ps1') -Force
$name = 'cloudxr-sdk-inspect-' + [Guid]::NewGuid().ToString('N')
$parameters = @('--host',$engine.HostEndpoint,'run','--rm','--name',$name,'--isolation=process','--network=none','--device','class/5B45201D-F2F2-4F3B-85BB-30FF1F953599','--mount',('type=bind,source=' + $payload + ',target=C:\lab,readonly'),'--mount',('type=bind,source=' + $runtime + ',target=C:\runtime,readonly'),'--mount',('type=bind,source=' + $run + ',target=C:\report'),'--mount','type=bind,source=C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_20f49c6eb5c9b39b,target=C:\nvidia-driver,readonly','--env','VK_DRIVER_FILES=C:\nvidia-driver\nv-vk64.json','--env','VK_LOADER_DEBUG=error,warn,driver','--workdir','C:\runtime','--env','STREAMINGSESSION_CONTAINER_PROBE=1','--env','TMP=C:\report','--env','TEMP=C:\report','sha256:7fb65857422af705198cd96f6a4481cde176dddf4cb1b8bc869d74ec51b0f06d','powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File','C:\lab\Inspect-Sdk.ps1')
$ErrorActionPreference = 'Continue'
$output = & $engine.DockerClient @parameters 2>&1
$code = $LASTEXITCODE
$output | ForEach-Object {$_.ToString()} | Set-Content -LiteralPath (Join-Path $run 'probe.log') -Encoding UTF8
@{ExitCode=$code;Run=$run;Ready=($code -eq 0 -and ($output -join "`n") -match 'PROBE READY')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $labRoot 'state\sdk-inspect-result.json') -Encoding UTF8
