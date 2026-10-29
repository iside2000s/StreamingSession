[CmdletBinding()]
param([ValidateRange(5, 300)][int]$Seconds = 30)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'state\latest-run.json') -Raw | ConvertFrom-Json
$samples = [Collections.Generic.List[object]]::new()
$bothSince = $null
$longestBoth = 0.0
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
Write-Output ('Measuring concurrent headset state for ' + $Seconds + ' seconds.')
while ([DateTime]::UtcNow -lt $deadline) {
    $status = (& (Join-Path $PSScriptRoot 'Get-HeadsetTestStatus.ps1') -AsJson) | ConvertFrom-Json
    $a = $status.Seats | Where-Object {$_.Seat -eq 'A'}
    $b = $status.Seats | Where-Object {$_.Seat -eq 'B'}
    $now = [DateTime]::UtcNow
    $both = $a.ProcessAlive -and $b.ProcessAlive -and $a.Headset -and $b.Headset
    if ($both) {
        if ($null -eq $bothSince) { $bothSince = $now }
        $longestBoth = [Math]::Max($longestBoth, ($now - $bothSince).TotalSeconds)
    }
    else { $bothSince = $null }
    $samples.Add([pscustomobject]@{Utc=$now.ToString('o'); A=$a.Headset; B=$b.Headset; Both=$both; ASession=$a.Session; BSession=$b.Session})
    Start-Sleep -Milliseconds 1000
}
$path = Join-Path $manifest.RunDirectory ('measurement-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
$report = [ordered]@{
    RequestedSeconds = $Seconds
    Samples = @($samples.ToArray())
    BothConnectedSamples = @($samples | Where-Object {$_.Both}).Count
    LongestObservedBothSeconds = [Math]::Round($longestBoth, 2)
    Note = 'SDK connection state only; picture quality and independent viewpoints require user observation.'
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Output ('Both-connected samples: ' + $report.BothConnectedSamples)
Write-Output ('Longest observed continuous overlap: ' + $report.LongestObservedBothSeconds + ' seconds')
Write-Output ('Measurement: ' + $path)
