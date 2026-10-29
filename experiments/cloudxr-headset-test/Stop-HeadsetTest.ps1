$ErrorActionPreference = 'Stop'
$latest = Join-Path $PSScriptRoot 'state\latest-run.json'
if (-not (Test-Path -LiteralPath $latest)) { throw 'No headset test manifest exists.' }
$manifest = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
$stateRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'state')).TrimEnd('\') + '\'
$stopFile = [IO.Path]::GetFullPath($manifest.StopFile)
if (-not $stopFile.StartsWith($stateRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected stop-file path.' }
[IO.File]::WriteAllText($stopFile, 'stop')
Write-Output 'Requested shutdown of the owned headset test processes.'
