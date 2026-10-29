[CmdletBinding()]
param([ValidateRange(5,120)][int]$Seconds=30)
$ErrorActionPreference = 'Stop'
$run = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'state\latest-run.json') -Raw | ConvertFrom-Json).RunDirectory
$samples = [Collections.Generic.List[object]]::new()
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
while ([DateTime]::UtcNow -lt $deadline) {
    $now = [DateTime]::UtcNow
    $row = [ordered]@{Utc=$now.ToString('o'); AFrames=$null; BFrames=$null; ATracking=$null; BTracking=$null; BothFreshStreaming=$true}
    foreach ($seat in @('a','b')) {
        try {
            $state = Get-Content -LiteralPath (Join-Path $run ($seat + '.json')) -Raw | ConvertFrom-Json
            $age = ($now - [DateTime]::Parse($state.receivedUtc).ToUniversalTime()).TotalSeconds
            if ($state.phase -ne 'streaming' -or $state.error -or $age -gt 5) { $row.BothFreshStreaming = $false }
            $row[$seat.ToUpperInvariant() + 'Frames'] = $state.frames
            $row[$seat.ToUpperInvariant() + 'Tracking'] = $state.trackingSent
        }
        catch { $row.BothFreshStreaming = $false }
    }
    $samples.Add([pscustomobject]$row)
    Start-Sleep -Milliseconds 1000
}
$first = $samples[0]
$last = $samples[$samples.Count-1]
$report = [ordered]@{
    Samples = @($samples.ToArray())
    BothFreshStreamingSamples = @($samples | Where-Object {$_.BothFreshStreaming}).Count
    ObservedSeconds = [Math]::Round(([DateTime]::Parse($last.Utc) - [DateTime]::Parse($first.Utc)).TotalSeconds,2)
    AFrameDelta = $last.AFrames - $first.AFrames
    BFrameDelta = $last.BFrames - $first.BFrames
    ATrackingDelta = $last.ATracking - $first.ATracking
    BTrackingDelta = $last.BTracking - $first.BTracking
    Note = 'Two desktop IWER clients, not Vision Pro hardware. No frame-rate or production-support guarantee.'
}
$path = Join-Path $run ('measurement-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
[pscustomobject]$report | Select-Object BothFreshStreamingSamples,ObservedSeconds,AFrameDelta,BFrameDelta,ATrackingDelta,BTrackingDelta | Format-List
Write-Output ('Report: ' + $path)
