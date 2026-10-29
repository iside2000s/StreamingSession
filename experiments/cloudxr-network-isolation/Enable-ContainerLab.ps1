[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param()
$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess('Windows optional feature: Containers', 'Enable with dependencies; do not restart automatically')) { return }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this reviewed script in an administrator PowerShell after the user approves enabling Containers.'
}
$feature = Get-WindowsOptionalFeature -Online -FeatureName Containers
$state = Join-Path $PSScriptRoot 'state'
$null = New-Item -ItemType Directory -Path $state -Force
$path = Join-Path $state 'feature-enable.json'
try {
    $restartNeeded = $false
    $changed = $feature.State -ne 'Enabled'
    if ($changed) {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
        $restartNeeded = $result.RestartNeeded
    }
    $report = [ordered]@{Succeeded=$true; Feature='Containers'; Changed=$changed; RestartNeeded=$restartNeeded; AutomaticRestart=$false; Utc=[DateTime]::UtcNow.ToString('o')}
    $report | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    [pscustomobject]$report
}
catch {
    @{Succeeded=$false; Feature='Containers'; Error=$_.Exception.Message; AutomaticRestart=$false; Utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    throw
}
