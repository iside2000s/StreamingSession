[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$engine = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'state\engine.json') -Raw | ConvertFrom-Json
$client = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\docker.exe'
$endpoint = 'npipe:////./pipe/streamingsession-cloudxr-lab'
if ($engine.DockerClient -ne $client -or $engine.HostEndpoint -ne $endpoint) { throw 'Unexpected lab engine.' }
$image = 'sha256:7fb65857422af705198cd96f6a4481cde176dddf4cb1b8bc869d74ec51b0f06d'
$payload = Join-Path $PSScriptRoot 'out\payload'
$runId = [Guid]::NewGuid().ToString('N')
$run = Join-Path $PSScriptRoot ('state\dual-gpu-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $run
$sockets = @()
$seats = @()
$report = @{Passed=$false; ConcurrentRunning=$false; Image=$image; RunId=$runId}
try {
    foreach ($port in @(47998,47999)) {
        $socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
        $sockets += $socket
        $socket.ExclusiveAddressUse = $true
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any,$port))
    }
    foreach ($seat in @('a','b')) {
        $name = 'cloudxr-dual-gpu-' + $runId + '-' + $seat
        $stdout = Join-Path $run ($seat + '.stdout.log')
        $stderr = Join-Path $run ($seat + '.stderr.log')
        $parameters = @('--host',$endpoint,'run','--name',$name,'--isolation=process','--network=none','--device','class/5B45201D-F2F2-4F3B-85BB-30FF1F953599','--mount',('type=bind,source=' + $payload + ',target=C:\lab,readonly'),$image,'C:\lab\GpuEncodeProbe.exe','--bind-udp','--hold-seconds','45')
        $quoted = @($parameters | ForEach-Object { if ($_.Contains('"')) { throw 'Invalid argument quoting.' }; '"' + $_ + '"' }) -join ' '
        $process = Start-Process $client -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $seats += @{Name=$name; Process=$process; Stdout=$stdout; Stderr=$stderr}
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $ready = @($seats | Where-Object { (Test-Path -LiteralPath $_.Stdout) -and (Get-Content -LiteralPath $_.Stdout -Raw) -match 'READY HOLDING_GPU_SESSION' })
        if ($ready.Count -eq 2) { break }
        if (@($seats | Where-Object {$_.Process.HasExited}).Count) { throw 'A GPU container exited before both were ready.' }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($ready.Count -ne 2) { throw 'Dual GPU readiness timed out.' }
    $started = [DateTime]::UtcNow
    foreach ($seat in $seats) {
        $running = & $client --host $endpoint inspect --format '{{.State.Running}}' $seat.Name
        if ($LASTEXITCODE -ne 0 -or $running -ne 'true') { throw 'Both containers were not running concurrently.' }
    }
    Start-Sleep -Seconds 10
    foreach ($seat in $seats) {
        $running = & $client --host $endpoint inspect --format '{{.State.Running}}' $seat.Name
        if ($LASTEXITCODE -ne 0 -or $running -ne 'true') { throw 'A container stopped during the overlap check.' }
    }
    $report.ConcurrentRunning = $true
    $report.OverlapSeconds = ([DateTime]::UtcNow - $started).TotalSeconds
    foreach ($seat in $seats) {
        if (-not $seat.Process.WaitForExit(60000)) { throw 'A GPU container did not finish before its deadline.' }
        $exitCode = & $client --host $endpoint inspect --format '{{.State.ExitCode}}' $seat.Name
        if ($LASTEXITCODE -ne 0 -or $exitCode -ne '0') { throw 'A GPU container did not exit successfully.' }
        $log = Get-Content -LiteralPath $seat.Stdout -Raw
        if ($log -notmatch 'PASS UDP_NAMESPACE_BOUND' -or $log -notmatch 'PASS D3D11_NVENC_H264') { throw 'A container is missing a required probe result.' }
    }
    $report.Passed = $true
    Write-Output ('PASS dual container UDP and NVENC session overlap: ' + $run)
} catch { $report.Error=$_.Exception.Message; throw }
finally {
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
    foreach ($socket in $sockets) { $socket.Dispose() }
    foreach ($seat in $seats) {
        $ErrorActionPreference = 'Continue'
        & $client --host $endpoint rm --force $seat.Name *> $null
        $ErrorActionPreference = 'Stop'
        $null = $seat.Process.WaitForExit(10000)
    }
}
