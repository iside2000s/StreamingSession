[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'state\engine.json'
if (-not (Test-Path -LiteralPath $path)) { Write-Output 'No owned lab engine is recorded.'; return }
$manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$expected = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\dockerd.exe'
if ($manifest.Executable -ne $expected) { throw 'Unexpected engine executable in manifest.' }
$process = Get-Process -Id $manifest.ProcessId -ErrorAction SilentlyContinue
if (-not $process) { Write-Output 'Owned engine already exited.'; return }
if ($process.Path -ne $expected -or $process.StartTime.ToUniversalTime().ToString('o') -ne $manifest.StartTimeUtc) { throw 'PID no longer identifies this lab engine; nothing was stopped.' }
$containers = & $manifest.DockerClient --host $manifest.HostEndpoint ps --quiet
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect engine containers. Nothing was stopped.' }
if ($containers) { throw 'A container is still running in this lab engine. Finish that test before stopping the engine.' }
Stop-Process -Id $process.Id
if (-not $process.WaitForExit(10000)) { throw 'The owned engine has not exited yet; wait before restarting it.' }
Write-Output 'Only the recorded lab engine was stopped. Its images and state were preserved.'
