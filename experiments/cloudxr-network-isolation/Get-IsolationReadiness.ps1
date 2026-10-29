[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$featureNames = @('Containers', 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')
$features = @(Get-CimInstance Win32_OptionalFeature | Where-Object {$featureNames -contains $_.Name} | ForEach-Object {
    [pscustomobject]@{Name=$_.Name; State=(@{1='Enabled';2='Disabled';3='Absent';4='Unknown'}[[int]$_.InstallState])}
})
$services = @(Get-Service hns,vmcompute,vmms -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{Name=$_.Name; State=$_.Status.ToString()}
})
$os = Get-CimInstance Win32_OperatingSystem
$gpu = @(Get-CimInstance Win32_VideoController | Where-Object {$_.Name -like '*NVIDIA*'} | Select-Object Name,DriverVersion)
$engine = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\dockerd.exe'
$containerFeature = $features | Where-Object {$_.Name -eq 'Containers'}
[ordered]@{
    CapturedUtc = [DateTime]::UtcNow.ToString('o')
    OperatingSystem = $os.Caption
    BuildNumber = $os.BuildNumber
    Elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Features = $features
    Services = $services
    NvidiaGpu = $gpu
    PreparedPortableEngine = (Test-Path -LiteralPath $engine)
    ContainerFeatureEnabled = ($null -ne $containerFeature -and $containerFeature.State -eq 'Enabled')
    GpuAndNvencInContainer = 'Unverified: requires an actual process-container encode test'
    Note = 'Read-only inventory. No features, services, network settings or GPU assignments were changed.'
} | ConvertTo-Json -Depth 5
