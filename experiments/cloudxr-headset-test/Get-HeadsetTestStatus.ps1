[CmdletBinding()]
param([switch]$AsJson)
$ErrorActionPreference = 'Stop'
$latest = Join-Path $PSScriptRoot 'state\latest-run.json'
if (-not (Test-Path -LiteralPath $latest)) { throw 'No headset test manifest exists.' }
$manifest = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
$rows = foreach ($seat in @('a', 'b')) {
    $log = Join-Path $manifest.RunDirectory ('seat-' + $seat + '\seat.log')
    $lines = @()
    if (Test-Path -LiteralPath $log) { $lines = @(Get-Content -LiteralPath $log) }
    $state = $lines | Where-Object { $_ -match ' STATE runtime=' } | Select-Object -Last 1
    $session = $lines | Where-Object { $_ -match ' SESSION ' } | Select-Object -Last 1
    $client = $lines | Where-Object { $_ -match ' CLIENT ' } | Select-Object -Last 1
    $process = $manifest.Processes | Where-Object { $_.Name -eq ('app-' + $seat) } | Select-Object -First 1
    $alive = $false
    if ($process) {
        $actual = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        $alive = $null -ne $actual -and $actual.Path -eq $process.Executable
    }
    $runtimeLogs = Join-Path $manifest.RunDirectory ('seat-' + $seat + '\runtime-logs')
    $conflictingPorts = @()
    if (Test-Path -LiteralPath $runtimeLogs) {
        $conflictingPorts = @(Get-ChildItem -LiteralPath $runtimeLogs -Filter 'cxr_streamsdk*.log' |
            Select-String -Pattern 'Socket Bind: failed to bind socket .* to [0-9.]+:(\d+) \(Error: 10048\)' |
            ForEach-Object { [int]$_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
    }
    [pscustomobject]@{
        Seat = $seat.ToUpperInvariant()
        ProcessAlive = $alive
        Runtime = $alive -and $state -match 'runtime=True'
        OpenXRApp = $alive -and $state -match 'app=True'
        Headset = $alive -and $state -match 'headset=True'
        Session = if ($session) { ($session -split ' SESSION ', 2)[1] } else { 'not connected' }
        Client = if ($client) { ($client -split ' CLIENT ', 2)[1] } else { '' }
        LastState = [string]$state
        ObservedMediaBindConflicts = $conflictingPorts
    }
}
if ($AsJson) {
    [pscustomobject]@{Status=$manifest.Status; RunDirectory=$manifest.RunDirectory; Seats=@($rows)} | ConvertTo-Json -Depth 4
}
else {
    $rows | Format-Table Seat,ProcessAlive,Runtime,OpenXRApp,Headset,Session,Client,ObservedMediaBindConflicts -AutoSize
    Write-Output ('Logs: ' + $manifest.RunDirectory)
}
