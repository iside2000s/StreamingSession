[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HostAddress,
    [string]$BundleId = 'com.cloudxr.visionos',
    [ValidateSet('NativeFixed', 'IceAutomatic')][string]$NetworkMode = 'NativeFixed',
    [ValidateRange(1, 120)][int]$MaximumMinutes = 60,
    [switch]$SkipBuild,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$parsedAddress = $null
if (-not [Net.IPAddress]::TryParse($HostAddress, [ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'HostAddress must be a local IPv4 address.' }
$localAddresses = @(foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    foreach ($unicast in $adapter.GetIPProperties().UnicastAddresses) { $unicast.Address.ToString() }
})
if ($localAddresses -notcontains $HostAddress) { throw 'HostAddress is not assigned to this computer.' }
$existing = @(Get-Process -Name CloudXrService, NvStreamManager, SignalingGateway -ErrorAction SilentlyContinue)
if ($existing.Count) { throw 'A streaming runtime/manager/gateway is already running. No existing process was stopped.' }
$network = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$busyPorts = @($network.GetActiveTcpListeners().Port) + @($network.GetActiveUdpListeners().Port)
$requiredPorts = @(48322, 55001, 55002, 50110, 50210)
if ($NetworkMode -eq 'NativeFixed') { $requiredPorts += @(50120, 50220) }
foreach ($port in $requiredPorts) {
    if ($busyPorts -contains $port) { throw ('Test port is already in use: ' + $port) }
}
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-HeadsetTest.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
}
$app = Join-Path $PSScriptRoot 'out\app\FoveatedStreamingSample.exe'
$gateway = Join-Path $PSScriptRoot 'out\SignalingGateway.exe'
$cube = Join-Path $PSScriptRoot 'out\cube\StreamingSession-OpenXRSample.exe'
$runtimeJson = Join-Path $PSScriptRoot 'out\app\Server\releases\6.2.3\openxr_cloudxr.json'
foreach ($file in @($app, $gateway, $cube, $runtimeJson)) {
    if (-not (Test-Path -LiteralPath $file)) { throw ('Missing build output: ' + $file) }
}
$run = Join-Path $PSScriptRoot ('state\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$routes = Join-Path $run 'routes'
$null = New-Item -ItemType Directory -Path $run, $routes
$seats = @()
for ($index = 0; $index -lt 2; $index++) {
    $id = @('a', 'b')[$index]
    $directory = Join-Path $run ('seat-' + $id)
    $null = New-Item -ItemType Directory -Path $directory, (Join-Path $directory 'tmp'), (Join-Path $directory 'runtime-logs')
    $seat = [ordered]@{
        SeatId = $id
        DisplayName = ($env:COMPUTERNAME + ' - Vision Pro ' + $id.ToUpperInvariant())
        HostAddress = $HostAddress
        SessionPort = 55001 + $index
        SignalingPort = 50110 + (100 * $index)
        MediaPort = $(if ($NetworkMode -eq 'IceAutomatic') { 0 } else { 50120 + (100 * $index) })
        EnableIce = ($NetworkMode -eq 'IceAutomatic')
        StateDirectory = $directory
        RouteDirectory = $routes
        BundleId = $BundleId
        RuntimeVersion = '6.2.3'
        AutoStart = $true
    }
    $seat | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'seat.json') -Encoding UTF8
    $ice = $seat.EnableIce.ToString().ToLowerInvariant()
    $yaml = "apiVersion: cloudxr.nvidia.com/v1beta1`nkind: OpenXRRuntimeConfiguration`nfeatureFlags:`n  deviceProfile: apple-vision-pro`n  serverPort: $($seat.SignalingPort)`n  mediaPort: $($seat.MediaPort)`n  enableIce: $ice`n  endpointIp: $HostAddress`n  runtimeFoveation: true`n  runtimeFoveationUnwarpedWidth: 1920`n  disableAlpha: false`n  audioStreaming: false`n  micStreaming: false`n"
    [IO.File]::WriteAllText((Join-Path $directory 'runtime.yaml'), $yaml)
    $seats += [pscustomobject]$seat
}
$gatewayConfig = [ordered]@{
    ListenAddress = $HostAddress
    ListenPort = 48322
    StopFile = (Join-Path $run 'gateway.stop')
    ReadyFile = (Join-Path $run 'gateway.ready')
    LogFile = (Join-Path $run 'gateway.log')
    Routes = @($seats | ForEach-Object { [ordered]@{
        SeatId = $_.SeatId
        ClientRoutePath = (Join-Path $routes ($_.SeatId + '.route.json'))
        BackendAddress = $HostAddress
        BackendPort = $_.SignalingPort
    } })
}
$gatewayPath = Join-Path $run 'gateway.json'
$gatewayConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $gatewayPath -Encoding UTF8
$manifest = [ordered]@{
    HostAddress = $HostAddress
    NetworkMode = $NetworkMode
    RunDirectory = $run
    StopFile = (Join-Path $run 'coordinator.stop')
    CoordinatorPid = $PID
    Processes = @()
    Status = 'prepared'
}
$manifestPath = Join-Path $run 'manifest.json'
$latestPath = Join-Path $PSScriptRoot 'state\latest-run.json'
function Save-Manifest {
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $latestPath -Encoding UTF8
}
Save-Manifest
Write-Output ('Test state: ' + $run)
Write-Output ('Network mode: ' + $NetworkMode + ' (experimental; simultaneous native streaming is not verified)')
if ($PrepareOnly) { return }

[Reflection.Assembly]::LoadFrom($app) | Out-Null
$job = [FoveatedStreaming.WindowsSample.ProcessJobObject]::new()
$owned = [Collections.Generic.List[object]]::new()

function Start-Owned([string]$Name, [string]$Executable, [string[]]$Arguments, [hashtable]$Environment, [bool]$Visible) {
    $saved = @{}
    try {
        foreach ($key in $Environment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $Environment[$key], 'Process')
        }
        $parameters = @{
            FilePath = $Executable
            WorkingDirectory = (Split-Path -Parent $Executable)
            WindowStyle = 'Hidden'
            PassThru = $true
            RedirectStandardOutput = (Join-Path $run ($Name + '.stdout.log'))
            RedirectStandardError = (Join-Path $run ($Name + '.stderr.log'))
        }
        if ($Visible) { $parameters.WindowStyle = 'Normal' }
        if ($Arguments.Count) {
            $quoted = foreach ($argument in $Arguments) {
                if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unexpected quote or trailing backslash in child argument.' }
                '"' + $argument + '"'
            }
            $parameters.ArgumentList = $quoted -join ' '
        }
        $process = Start-Process @parameters
        if (-not $job.AssignProcess($process)) { $process.Kill(); throw ('Could not assign cleanup job: ' + $Name) }
        $owned.Add([pscustomobject]@{ Name = $Name; Process = $process })
        $manifest.Processes += [ordered]@{Name=$Name; Id=$process.Id; Executable=$Executable}
        Save-Manifest
        return $process
    }
    finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

try {
    $gatewayProcess = Start-Owned 'gateway' $gateway @($gatewayPath) @{} $false
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $gatewayConfig.ReadyFile) -and [DateTime]::UtcNow -lt $readyDeadline) {
        if ($gatewayProcess.HasExited) { throw 'Gateway exited before becoming ready.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $gatewayConfig.ReadyFile)) { throw 'Gateway did not become ready.' }
    foreach ($seat in $seats) {
        $environment = @{
            STREAMING_EXPERIMENT_CONFIG = (Join-Path $seat.StateDirectory 'seat.json')
            TMP = (Join-Path $seat.StateDirectory 'tmp')
            TEMP = (Join-Path $seat.StateDirectory 'tmp')
            NV_CXR_OUTPUT_DIR = (Join-Path $seat.StateDirectory 'runtime-logs')
            NV_CXR_FILE_LOGGING = 'true'
        }
        $seatProcess = Start-Owned ('app-' + $seat.SeatId) $app @() $environment $true
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $log = Join-Path $seat.StateDirectory 'seat.log'
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($seatProcess.HasExited) { throw ('Seat ' + $seat.SeatId + ' exited during startup.') }
            if ((Test-Path -LiteralPath $log) -and (Get-Content -LiteralPath $log -Raw) -match 'STATE runtime=True') { $ready = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $ready) { throw ('Seat ' + $seat.SeatId + ' runtime did not start. Inspect its window and log.') }
        $environment.XR_RUNTIME_JSON = $runtimeJson
        $environment.Remove('STREAMING_EXPERIMENT_CONFIG')
        $null = Start-Owned ('cube-' + $seat.SeatId) $cube @() $environment $true
        Write-Output ('READY seat ' + $seat.SeatId.ToUpperInvariant() + ': client IP=' + $HostAddress + ' session port=' + $seat.SessionPort)
    }
    $manifest.Status = 'running'
    Save-Manifest
    Write-Output 'Both test seats are running. Scan the QR code in the matching seat window when prompted.'
    Write-Output ('Stop by creating: ' + $manifest.StopFile)
    $deadline = [DateTime]::UtcNow.AddMinutes($MaximumMinutes)
    while (-not (Test-Path -LiteralPath $manifest.StopFile) -and [DateTime]::UtcNow -lt $deadline) {
        if ($gatewayProcess.HasExited) { throw 'Signaling gateway exited; stopping owned test processes.' }
        Start-Sleep -Milliseconds 500
    }
}
finally {
    $manifest.Status = 'stopping'
    Save-Manifest
    [IO.File]::WriteAllText($gatewayConfig.StopFile, 'stop')
    foreach ($entry in $owned) {
        if ($entry.Name.StartsWith('app-') -and -not $entry.Process.HasExited) { $null = $entry.Process.CloseMainWindow() }
    }
    Start-Sleep -Milliseconds 700
    $job.Dispose()
    $manifest.Status = 'stopped'
    Save-Manifest
    Write-Output 'Owned test processes stopped. Existing applications were not stopped.'
}
