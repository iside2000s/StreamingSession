[CmdletBinding()]
param(
    [string]$RuntimeDirectory,
    [ValidateSet('SharedTemp', 'SeparateTemp')]
    [string]$IsolationMode = 'SeparateTemp',
    [ValidateSet('DirectSdk', 'StreamManager')]
    [string]$Backend = 'DirectSdk',
    [ValidateRange(1, 60)]
    [int]$StartupTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $RuntimeDirectory) {
    $RuntimeDirectory = Join-Path $repository 'StreamingSession-WindowsApp\bin\Release\Server\releases\6.2.3'
}
$RuntimeDirectory = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$loader = Join-Path $repository 'StreamingSession-OpenXRSample\packages\OpenXR.Loader.1.0.6.2\native\x64\release\bin\openxr_loader.dll'
$executable = Join-Path $PSScriptRoot 'out\CloudXrProbe.exe'
$ownedProcesses = [Collections.Generic.List[object]]::new()

function Get-XrPipes {
    @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match '(?i)cloudxr|monado' })
}

function Read-ProbeLog($Entry) {
    if (Test-Path -LiteralPath $Entry.Stdout) {
        $stream = [IO.FileStream]::new($Entry.Stdout, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($stream)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    return ''
}

function Start-Probe([string]$Name, [string[]]$Arguments) {
    # Windows path names cannot contain quotes. Reject them explicitly so that
    # quoting of ProcessStartInfo's argument string stays unambiguous.
    $quoted = foreach ($argument in $Arguments) {
        if ($argument.Contains('"') -or $argument.EndsWith('\')) {
            throw 'Probe arguments must not contain quotes or end in a backslash.'
        }
        '"' + $argument + '"'
    }
    $stdout = Join-Path $runDirectory ($Name + '.stdout.log')
    $stderr = Join-Path $runDirectory ($Name + '.stderr.log')
    # Some native dependencies snapshot getenv() during process startup, before
    # wmain. Set these in the inherited child environment as well as the probe's
    # explicit Win32 environment setup. Restore this script's environment after
    # starting the child; no machine/user environment variables are modified.
    $childEnvironment = @{}
    $tempIndex = [Array]::IndexOf($Arguments, '--temp-dir')
    if ($tempIndex -ge 0) {
        $childEnvironment.TMP = $Arguments[$tempIndex + 1]
        $childEnvironment.TEMP = $Arguments[$tempIndex + 1]
    }
    $logIndex = [Array]::IndexOf($Arguments, '--log-dir')
    if ($logIndex -ge 0) {
        $childEnvironment.NV_CXR_OUTPUT_DIR = $Arguments[$logIndex + 1]
        $childEnvironment.NV_CXR_FILE_LOGGING = 'true'
    }
    $previousEnvironment = @{}
    try {
        foreach ($key in $childEnvironment.Keys) {
            $previousEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $childEnvironment[$key], 'Process')
        }
        $process = Start-Process -FilePath $executable -ArgumentList ($quoted -join ' ') `
            -WorkingDirectory (Split-Path -Parent $executable) -WindowStyle Hidden `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    }
    finally {
        foreach ($key in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previousEnvironment[$key], 'Process')
        }
    }
    $entry = [pscustomobject]@{ Name = $Name; Process = $process; Stdout = $stdout; Stderr = $stderr }
    $ownedProcesses.Add($entry)
    return $entry
}

function Wait-ServiceReady($Entry) {
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $log = Read-ProbeLog $Entry
        if ($log -match '(?m)^PROBE READY\r?$') { return $true }
        if ($log -match '(?m)^PROBE (START result=-|ERROR )' -or $Entry.Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Run-Client([string]$Name, [string]$TempDirectory) {
    $arguments = @('--mode', 'client', '--runtime', $RuntimeDirectory, '--loader', $loader)
    if ($TempDirectory) { $arguments += @('--temp-dir', $TempDirectory) }
    $entry = Start-Probe $Name $arguments
    if (-not $entry.Process.WaitForExit(15000)) {
        throw ($Name + ' timed out connecting to OpenXR.')
    }
    $entry.Process.WaitForExit()
    $log = Read-ProbeLog $entry
    return [pscustomobject]@{
        Name = $Name
        CreateInstanceSucceeded = $log -match '(?m)^PROBE XR_CREATE_INSTANCE result=0\r?$'
        GetSystemSucceeded = $log -match '(?m)^PROBE XR_GET_SYSTEM result=0\r?$'
        Markers = @($log -split '\r?\n' | Where-Object { $_.StartsWith('PROBE ') })
    }
}

function Count-Connections($Entry) {
    return [regex]::Matches((Read-ProbeLog $Entry), '(?m)^PROBE EVENT type=3\r?$').Count
}

function Stop-ProbeService($Entry, [string]$StopFile) {
    [IO.File]::WriteAllText($StopFile, 'stop')
    if (-not $Entry.Process.WaitForExit(10000)) { throw ($Entry.Name + ' did not shut down on request.') }
    $Entry.Process.WaitForExit()
}

function Wait-GraphicsReady($Entry) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Read-ProbeLog $Entry) -match '(?m)^PROBE XR_GRAPHICS_HOLD_BEGIN\r?$') { return -not $Entry.Process.HasExited }
        if ($Entry.Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

foreach ($requiredFile in @((Join-Path $RuntimeDirectory 'cloudxr.dll'), (Join-Path $RuntimeDirectory 'openxr_cloudxr.json'), $loader)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw ('Missing prerequisite: ' + $requiredFile) }
}

# Do not stop, reconfigure, or attach to the user's current runtime. An idle WPF
# launcher is allowed, but any live runtime/manager or fixed IPC pipe aborts.
$existingServices = @(Get-Process -Name 'CloudXrService', 'NvStreamManager' -ErrorAction SilentlyContinue)
$existingPipes = Get-XrPipes
if ($existingServices.Count -ne 0 -or $existingPipes.Count -ne 0) {
    throw 'A CloudXR runtime/manager or XR named pipe is already active. Close that streaming session before running this experiment. No existing process was stopped.'
}
$network = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$busyPorts = @($network.GetActiveTcpListeners().Port) + @($network.GetActiveUdpListeners().Port)
foreach ($port in @(50110, 50120, 50210, 50220)) {
    if ($busyPorts -contains $port) { throw ('Experimental port is already in use: ' + $port) }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio 2022 C++ build tools are required.' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\Current\Bin\MSBuild.exe'
if (-not $msbuild) { throw 'Visual Studio C++ build tools were not found.' }
& $msbuild (Join-Path $PSScriptRoot 'CloudXrProbe.vcxproj') /nologo /v:minimal /p:Configuration=Release /p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed.' }

$runDirectory = Join-Path $PSScriptRoot ('results\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $runDirectory
$dllHashesBefore = @('cloudxr.dll', 'openxr_cloudxr.dll', 'NvStreamServer.dll') | ForEach-Object {
    [pscustomobject]@{ Name = $_; SHA256 = (Get-FileHash -LiteralPath (Join-Path $RuntimeDirectory $_) -Algorithm SHA256).Hash }
}
$summary = [ordered]@{
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    RuntimeDirectory = $RuntimeDirectory
    IsolationMode = $IsolationMode
    Backend = $Backend
    SourceCommit = (& git -C $repository rev-parse HEAD)
    RuntimeDlls = $dllHashesBefore
    ServerAReady = $false
    ServerBReady = $false
    ClientBeforeB = $null
    ClientAfterB = $null
    ClientSeatB = $null
    SeatBRoutedToB = $false
    ConcurrentD3D11Sessions = $false
    GraphicsAMarkers = @()
    GraphicsBMarkers = @()
    ConnectionsBeforeSeatBClient = $null
    ConnectionsAfterSeatBClient = $null
    ClientAAfterBStopped = $null
    ClientBAfterBStopped = $null
    SeatBAvoidsFallbackToA = $false
    ServerAStillAliveAfterB = $false
    ServerAMarkers = @()
    ServerBMarkers = @()
    PipesWhileARunning = @()
    PipesWhileBothRunning = @()
    SignalingPortsListening = @()
    PipeCollisionEvidence = @()
    Error = $null
    RuntimeDllsUnchanged = $false
    AllOwnedProcessesStopped = $false
    ExpectedChecksPassed = $false
}

try {
    $logA = Join-Path $runDirectory 'runtime-a'
    $logB = Join-Path $runDirectory 'runtime-b'
    $null = New-Item -ItemType Directory -Path $logA, $logB
    $tempA = $null
    $tempB = $null
    if ($IsolationMode -eq 'SeparateTemp') {
        $tempA = Join-Path $runDirectory 'temp-a'
        $tempB = Join-Path $runDirectory 'temp-b'
        $null = New-Item -ItemType Directory -Path $tempA, $tempB
    }
    $common = @('--mode', 'service', '--runtime', $RuntimeDirectory, '--seconds', '120')
    $argumentsA = $common + @('--port', '50110', '--media-port', '50120', '--log-dir', $logA, '--stop-file', (Join-Path $runDirectory 'stop-a'))
    $argumentsB = $common + @('--port', '50210', '--media-port', '50220', '--log-dir', $logB, '--stop-file', (Join-Path $runDirectory 'stop-b'))
    if ($tempA) { $argumentsA += @('--temp-dir', $tempA) }
    if ($tempB) { $argumentsB += @('--temp-dir', $tempB) }
    if ($Backend -eq 'StreamManager') {
        $configA = Join-Path $runDirectory 'runtime-a.yaml'
        $configB = Join-Path $runDirectory 'runtime-b.yaml'
        foreach ($seat in @(@($configA, 50110, 50120), @($configB, 50210, 50220))) {
            $yaml = "apiVersion: cloudxr.nvidia.com/v1beta1`nkind: OpenXRRuntimeConfiguration`nfeatureFlags:`n  deviceProfile: apple-vision-pro`n  serverPort: $($seat[1])`n  mediaPort: $($seat[2])`n  endpointIp: 127.0.0.1`n  runtimeFoveation: false`n  audioStreaming: false`n  micStreaming: false`n"
            [IO.File]::WriteAllText($seat[0], $yaml)
        }
        $argumentsA[1] = 'manager'
        $argumentsB[1] = 'manager'
        $runId = Split-Path -Leaf $runDirectory
        $argumentsA += @('--pipe', ('cloudxr-probe-a-' + $runId), '--runtime-config', $configA)
        $argumentsB += @('--pipe', ('cloudxr-probe-b-' + $runId), '--runtime-config', $configB)
    }
    $serviceA = Start-Probe 'service-a' $argumentsA
    $summary.ServerAReady = Wait-ServiceReady $serviceA
    if (-not $summary.ServerAReady) { throw 'Control runtime A did not become ready; the two-runtime test is inconclusive.' }
    $summary.PipesWhileARunning = @(Get-XrPipes)
    $summary.ClientBeforeB = Run-Client 'client-before-b' $tempA
    if (-not $summary.ClientBeforeB.GetSystemSucceeded) { throw 'Control OpenXR attachment failed; the two-runtime test is inconclusive.' }
    Write-Output ('Control runtime ready; OpenXR get-system success: ' + $summary.ClientBeforeB.GetSystemSucceeded)

    $serviceB = Start-Probe 'service-b' $argumentsB
    $summary.ServerBReady = Wait-ServiceReady $serviceB
    $summary.ServerAStillAliveAfterB = -not $serviceA.Process.HasExited
    # If B fails, the second probe checks that trying B did not break A. If B
    # starts, this is still only an attachment check, not proof of seat routing.
    if ($summary.ServerAStillAliveAfterB) { $summary.ClientAfterB = Run-Client 'client-after-b' $tempA }
    Write-Output ('Second runtime ready with different network ports: ' + $summary.ServerBReady)
    if ($summary.ServerBReady) {
        $summary.PipesWhileBothRunning = @(Get-XrPipes)
        $summary.SignalingPortsListening = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -in @(50110, 50210, 48322, 48010) } | ForEach-Object { $_.ToString() })
        $before = [pscustomobject]@{ A = (Count-Connections $serviceA); B = (Count-Connections $serviceB) }
        $summary.ConnectionsBeforeSeatBClient = $before
        $summary.ClientSeatB = Run-Client 'client-seat-b' $tempB
        Start-Sleep -Milliseconds 300
        $after = [pscustomobject]@{ A = (Count-Connections $serviceA); B = (Count-Connections $serviceB) }
        $summary.ConnectionsAfterSeatBClient = $after
        $summary.SeatBRoutedToB = $summary.ClientSeatB.GetSystemSucceeded -and $after.A -eq $before.A -and $after.B -eq ($before.B + 1)
        Write-Output ('Seat B attached to B without attaching to A: ' + $summary.SeatBRoutedToB)
        if ($IsolationMode -eq 'SeparateTemp') {
            $graphicsArguments = @('--mode', 'client', '--runtime', $RuntimeDirectory, '--loader', $loader, '--graphics', 'true', '--hold-seconds', '5')
            $graphicsA = Start-Probe 'graphics-a' ($graphicsArguments + @('--temp-dir', $tempA))
            $graphicsB = Start-Probe 'graphics-b' ($graphicsArguments + @('--temp-dir', $tempB))
            $readyA = Wait-GraphicsReady $graphicsA
            $readyB = Wait-GraphicsReady $graphicsB
            $summary.ConcurrentD3D11Sessions = $readyA -and $readyB -and -not $graphicsA.Process.HasExited -and -not $graphicsB.Process.HasExited
            foreach ($graphics in @($graphicsA, $graphicsB)) {
                if (-not $graphics.Process.WaitForExit(15000)) { throw ($graphics.Name + ' timed out.') }
                $graphics.Process.WaitForExit()
            }
            $summary.GraphicsAMarkers = @((Read-ProbeLog $graphicsA) -split '\r?\n' | Where-Object { $_.StartsWith('PROBE ') })
            $summary.GraphicsBMarkers = @((Read-ProbeLog $graphicsB) -split '\r?\n' | Where-Object { $_.StartsWith('PROBE ') })
            Write-Output ('Two D3D11 OpenXR sessions with swapchains alive concurrently: ' + $summary.ConcurrentD3D11Sessions)
            Stop-ProbeService $serviceB (Join-Path $runDirectory 'stop-b')
            $summary.ClientAAfterBStopped = Run-Client 'client-a-after-b-stopped' $tempA
            $connectionsBefore = Count-Connections $serviceA
            $summary.ClientBAfterBStopped = Run-Client 'client-b-after-b-stopped' $tempB
            Start-Sleep -Milliseconds 200
            $summary.SeatBAvoidsFallbackToA = -not $summary.ClientBAfterBStopped.CreateInstanceSucceeded -and (Count-Connections $serviceA) -eq $connectionsBefore
            Write-Output ('A works after B stops: ' + $summary.ClientAAfterBStopped.GetSystemSucceeded)
            Write-Output ('Stopped seat B does not fall back to A: ' + $summary.SeatBAvoidsFallbackToA)
        }
    }
}
catch {
    $summary.Error = $_.Exception.Message
}
finally {
    # Each host observes only its own stop file. Never kill a process by name.
    foreach ($name in @('stop-a', 'stop-b')) {
        [IO.File]::WriteAllText((Join-Path $runDirectory $name), 'stop')
    }
    foreach ($entry in $ownedProcesses) {
        if (-not $entry.Process.HasExited -and -not $entry.Process.WaitForExit(10000)) {
            # This Process object was created by Start-Probe in this invocation.
            $entry.Process.Kill()
            $entry.Process.WaitForExit()
        }
    }
    foreach ($entry in $ownedProcesses) {
        $markers = @((Read-ProbeLog $entry) -split '\r?\n' | Where-Object { $_.StartsWith('PROBE ') })
        if ($entry.Name -eq 'service-a') { $summary.ServerAMarkers = $markers }
        if ($entry.Name -eq 'service-b') { $summary.ServerBMarkers = $markers }
    }
    $allLogs = @(Get-ChildItem -LiteralPath $runDirectory -Filter '*.log' -Recurse)
    $summary.PipeCollisionEvidence = @($allLogs | Select-String -Pattern 'already running|CreateNamedPipe.*failed|IPC_SERVICE_ALREADY_RUNNING|ipc_cloudxr' | Select-Object -First 15 | ForEach-Object {
        [pscustomobject]@{ File = $_.Path.Substring($runDirectory.Length + 1); Line = $_.LineNumber; Text = $_.Line.Trim() }
    })
    $summary.RuntimeDllsUnchanged = $true
    foreach ($item in $dllHashesBefore) {
        if ((Get-FileHash -LiteralPath (Join-Path $RuntimeDirectory $item.Name) -Algorithm SHA256).Hash -ne $item.SHA256) {
            $summary.RuntimeDllsUnchanged = $false
        }
    }
    $summary.AllOwnedProcessesStopped = @($ownedProcesses | Where-Object { -not $_.Process.HasExited }).Count -eq 0
    $controlPassed = $summary.ServerAReady -and $summary.ClientBeforeB.GetSystemSucceeded -and $summary.ServerAStillAliveAfterB -and $summary.ClientAfterB.GetSystemSucceeded
    if ($IsolationMode -eq 'SeparateTemp') {
        $summary.ExpectedChecksPassed = $controlPassed -and $summary.ServerBReady -and $summary.SeatBRoutedToB -and $summary.ConcurrentD3D11Sessions -and $summary.ClientAAfterBStopped.GetSystemSucceeded -and $summary.SeatBAvoidsFallbackToA
    }
    else {
        $summary.ExpectedChecksPassed = $controlPassed -and -not $summary.ServerBReady -and $summary.PipeCollisionEvidence.Count -gt 0
    }
    $summary.ExpectedChecksPassed = $summary.ExpectedChecksPassed -and $summary.RuntimeDllsUnchanged -and $summary.AllOwnedProcessesStopped -and -not $summary.Error
    $summary.FinishedUtc = [DateTime]::UtcNow.ToString('o')
    $summaryPath = Join-Path $runDirectory 'summary.json'
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Output ('Report: ' + $summaryPath)
    Write-Output ('Runtime DLLs unchanged: ' + $summary.RuntimeDllsUnchanged)
    Write-Output ('All experiment processes stopped: ' + $summary.AllOwnedProcessesStopped)
    Write-Output ('Expected checks passed for ' + $IsolationMode + '/' + $Backend + ': ' + $summary.ExpectedChecksPassed)
}
if ($summary.Error) { throw $summary.Error }
if (-not $summary.ExpectedChecksPassed) { throw 'The expected experiment checks did not all pass. Inspect summary.json and the logs.' }
