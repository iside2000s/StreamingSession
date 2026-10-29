[CmdletBinding()]
param([switch]$UseOfflineImage)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'state\engine.json') -Raw | ConvertFrom-Json
$client = $manifest.DockerClient
$endpoint = $manifest.HostEndpoint
$expected = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\docker.exe'
if ($client -ne $expected -or $endpoint -ne 'npipe:////./pipe/streamingsession-cloudxr-lab') { throw 'Unexpected lab engine configuration.' }
$payload = Join-Path $PSScriptRoot 'out\payload'
if (-not (Test-Path -LiteralPath (Join-Path $payload 'GpuEncodeProbe.exe'))) { throw 'Run Build-LabTools.ps1 first.' }
$image = 'mcr.microsoft.com/windows/server@sha256:c241b18ec3d59e82992722b473fa19e290fd27cb7819fe69a0f4ad31130a245a'
if ($UseOfflineImage) {
    # The config digest from that same pinned Microsoft manifest is Docker's image ID.
    $image = 'sha256:7fb65857422af705198cd96f6a4481cde176dddf4cb1b8bc869d74ec51b0f06d'
}
$ErrorActionPreference = 'Continue'
try { & $client --host $endpoint image inspect $image *> $null; $imageExitCode = $LASTEXITCODE }
finally { $ErrorActionPreference = 'Stop' }
if ($imageExitCode -ne 0) {
    if ($UseOfflineImage) {
        $archive = Join-Path $PSScriptRoot 'out\image-download\windows-server-2025.tar'
        if (-not (Test-Path -LiteralPath $archive)) { throw 'Run Prepare-OfflineImage.ps1 first.' }
        & $client --host $endpoint load --input $archive
        if ($LASTEXITCODE -ne 0) { throw 'Verified Microsoft image archive load failed.' }
        & $client --host $endpoint image inspect $image --format '{{.Id}}'
        if ($LASTEXITCODE -ne 0) { throw 'The loaded image does not match the pinned Microsoft configuration digest.' }
    } else {
        Write-Output 'Pulling the Microsoft Windows Server 2025 full base image for this GPU test.'
        & $client --host $endpoint pull $image
        if ($LASTEXITCODE -ne 0) { throw 'Microsoft base image pull failed.' }
    }
}
$bound = [Collections.Generic.List[Net.Sockets.Socket]]::new()
$run = Join-Path $PSScriptRoot ('state\gpu-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$null = New-Item -ItemType Directory -Path $run
$name = 'cloudxr-gpu-check-' + [Guid]::NewGuid().ToString('N')
try {
    foreach ($port in @(47998,47999)) {
        $socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Dgram,[Net.Sockets.ProtocolType]::Udp)
        $bound.Add($socket)
        $socket.ExclusiveAddressUse = $true
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any,$port))
    }
    Write-Output 'Host holds UDP 47998 and 47999 exclusively; the container must bind the same ports independently.'
    $arguments = @('--host',$endpoint,'run','--rm','--name',$name,'--isolation=process','--network=none','--device','class/5B45201D-F2F2-4F3B-85BB-30FF1F953599','--mount',('type=bind,source=' + $payload + ',target=C:\lab,readonly'),$image,'C:\lab\GpuEncodeProbe.exe','--bind-udp')
    $ErrorActionPreference = 'Continue'
    try { $output = & $client @arguments 2>&1; $exitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = 'Stop' }
    $output | ForEach-Object {$_.ToString()} | Set-Content -LiteralPath (Join-Path $run 'probe.log') -Encoding UTF8
    $output | Write-Output
    $text = $output -join "`n"
    $passed = $exitCode -eq 0 -and $text.Contains('PASS UDP_NAMESPACE_BOUND') -and $text.Contains('PASS D3D11_NVENC_H264')
    @{Passed=$passed; ExitCode=$exitCode; Image=$image; ContainerName=$name; Note='This is an isolated UDP bind and single-frame NVENC check, not a CloudXR or dual-headset streaming test.'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
    if (-not $passed) { throw ('Container network/GPU check failed. Inspect ' + (Join-Path $run 'probe.log')) }
    Write-Output ('PASS: isolated UDP ports and container NVENC encoding. Report: ' + $run)
}
finally {
    foreach ($socket in $bound) { $socket.Dispose() }
    # --rm removes the completed test container. No images or other containers are deleted.
}
