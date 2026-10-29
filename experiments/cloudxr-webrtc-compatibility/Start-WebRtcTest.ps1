[CmdletBinding()]
param([ValidateRange(1,30)][int]$MaximumMinutes=10)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$probe = Join-Path $repository 'experiments\cloudxr-multi-instance\out\CloudXrProbe.exe'
$cube = Join-Path $repository 'experiments\cloudxr-headset-test\out\cube\StreamingSession-OpenXRSample.exe'
$app = Join-Path $repository 'experiments\cloudxr-headset-test\out\app\FoveatedStreamingSample.exe'
$runtime = Join-Path $repository 'StreamingSession-WindowsApp\bin\Release\Server\releases\6.2.3'
$node = (Get-Command node.exe -ErrorAction Stop).Source
foreach ($file in @($probe,$cube,$app,(Join-Path $PSScriptRoot 'out\site\bundle.js'))) {
    if (-not (Test-Path -LiteralPath $file)) { throw ('Missing prepared output: ' + $file) }
}
if (@(Get-Process CloudXrProbe,CloudXrService,NvStreamManager,SignalingGateway -ErrorAction SilentlyContinue).Count) { throw 'Another streaming probe/runtime is running. No existing process was stopped.' }
$network = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$busy = @($network.GetActiveTcpListeners().Port) + @($network.GetActiveUdpListeners().Port)
foreach ($port in @(50110,50120,50210,50220,55300)) { if ($busy -contains $port) { throw ('Test port is in use: ' + $port) } }
$run = Join-Path $PSScriptRoot ('state\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $run
[Reflection.Assembly]::LoadFrom($app) | Out-Null
$job = [FoveatedStreaming.WindowsSample.ProcessJobObject]::new()
$owned = [Collections.Generic.List[object]]::new()
$seats = [Collections.Generic.List[object]]::new()
$stopFile = Join-Path $run 'stop'
@{RunDirectory=$run; StopFile=$stopFile; CoordinatorPid=$PID} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'state\latest-run.json') -Encoding UTF8
function Start-Owned([string]$Name,[string]$Executable,[string[]]$Parameters,[hashtable]$ChildEnvironment) {
    $saved = @{}
    try {
        foreach ($key in $ChildEnvironment.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key,'Process')
            [Environment]::SetEnvironmentVariable($key,$ChildEnvironment[$key],'Process')
        }
        $quoted = foreach ($argument in $Parameters) {
            if ($argument.Contains('"') -or $argument.EndsWith('\')) { throw 'Unexpected child argument quoting.' }
            '"' + $argument + '"'
        }
        $start = @{FilePath=$Executable; WorkingDirectory=(Split-Path -Parent $Executable); WindowStyle='Hidden'; PassThru=$true; RedirectStandardOutput=(Join-Path $run ($Name + '.stdout.log')); RedirectStandardError=(Join-Path $run ($Name + '.stderr.log'))}
        if ($Parameters.Count) { $start.ArgumentList = $quoted -join ' ' }
        $process = Start-Process @start
        if (-not $job.AssignProcess($process)) { $process.Kill(); throw 'Could not assign the experiment cleanup job.' }
        $owned.Add($process)
        return $process
    }
    finally { foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') } }
}
try {
    for ($index=0; $index -lt 2; $index++) {
        $id = @('a','b')[$index]
        $directory = Join-Path $run $id
        $temporary = Join-Path $directory 'tmp'
        $logs = Join-Path $directory 'logs'
        $null = New-Item -ItemType Directory -Path $temporary,$logs -Force
        $environment = @{TMP=$temporary; TEMP=$temporary; NV_CXR_OUTPUT_DIR=$logs; NV_CXR_FILE_LOGGING='true'}
        $parameters = @('--mode','service','--runtime',$runtime,'--profile','auto-webrtc','--enable-ice','true','--port',[string](50110+100*$index),'--media-port',[string](50120+100*$index),'--log-dir',$logs,'--seconds',[string]($MaximumMinutes*60+30),'--stop-file',(Join-Path $directory 'service.stop'))
        $service = Start-Owned ('service-' + $id) $probe $parameters $environment
        $stdout = Join-Path $run ('service-' + $id + '.stdout.log')
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($service.HasExited) { throw ('Seat ' + $id + ' service startup failed.') }
            if ((Test-Path -LiteralPath $stdout) -and (Get-Content -LiteralPath $stdout -Raw) -match 'PROBE READY') { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not ((Get-Content -LiteralPath $stdout -Raw) -match 'PROBE READY')) { throw 'Service readiness timed out.' }
        $environment.XR_RUNTIME_JSON = Join-Path $runtime 'openxr_cloudxr.json'
        $seats.Add([pscustomobject]@{Id=$id; Service=$service; Log=$stdout; Environment=$environment; Cube=$null})
    }
    $web = Start-Owned 'web' $node @((Join-Path $PSScriptRoot 'server.mjs'),(Join-Path $PSScriptRoot 'out\site'),$run) @{}
    Write-Output ('RUN ' + $run)
    Write-Output 'READY A http://127.0.0.1:55300/?seat=a'
    Write-Output 'READY B http://127.0.0.1:55300/?seat=b'
    $deadline = [DateTime]::UtcNow.AddMinutes($MaximumMinutes)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $stopFile)) {
        if ($web.HasExited) { throw 'Local web client host exited.' }
        foreach ($seat in $seats) {
            if ($seat.Service.HasExited) { throw ('Seat ' + $seat.Id + ' runtime exited.') }
            if ($null -eq $seat.Cube -and (Get-Content -LiteralPath $seat.Log -Raw) -match 'PROBE EVENT type=1\b') {
                $seat.Cube = Start-Owned ('cube-' + $seat.Id) $cube @() $seat.Environment
                Write-Output ('CUBE_STARTED ' + $seat.Id)
            }
        }
        Start-Sleep -Milliseconds 200
    }
}
finally {
    $job.Dispose()
    Write-Output 'Owned WebRTC test processes stopped.'
}
