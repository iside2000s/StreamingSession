[CmdletBinding()]
param([string]$DownloadProxy)
$ErrorActionPreference = 'Stop'
$directory = Join-Path $PSScriptRoot 'out\image-download'
$null = New-Item -ItemType Directory -Path $directory -Force
$registry = 'https://mcr.microsoft.com/v2/windows/server'
$indexDigest = 'c241b18ec3d59e82992722b473fa19e290fd27cb7819fe69a0f4ad31130a245a'
$childDigest = '9eb393ccb1817ae850b2d3be8fc4917b043dc2d5be293cc602664a4733ef89cb'
$configDigest = '7fb65857422af705198cd96f6a4481cde176dddf4cb1b8bc869d74ec51b0f06d'

function Get-VerifiedFile([string]$Url, [string]$Name, [string]$Digest, [long]$Size = 0) {
    if ($Digest -notmatch '^[a-f0-9]{64}$' -or [IO.Path]::GetFileName($Name) -ne $Name) { throw 'Invalid fixed image descriptor.' }
    $path = Join-Path $directory $Name
    $complete = $false
    if (Test-Path -LiteralPath $path) {
        $length = (Get-Item -LiteralPath $path).Length
        if ($Size -eq 0 -or $length -eq $Size) {
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Digest) { $complete = $true }
            else { throw ('Cached file checksum mismatch; inspect before replacing: ' + $path) }
        } elseif ($length -gt $Size) { throw ('Cached file exceeds the expected size: ' + $path) }
    }
    if (-not $complete) {
        Write-Output ('Downloading fixed Microsoft image file: ' + $Name)
        $curlArguments = @('--fail','--location','--silent','--show-error','--connect-timeout','10','--max-time','600','--continue-at','-','--output',$path)
        if ($DownloadProxy) { $curlArguments += @('--proxy',$DownloadProxy) }
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $ErrorActionPreference = 'Continue'
            try { & curl.exe @curlArguments $Url; $downloadExitCode = $LASTEXITCODE }
            finally { $ErrorActionPreference = 'Stop' }
            if ($downloadExitCode -eq 0) { break }
            if ($attempt -eq 3) { throw ('Image download failed: ' + $Name) }
            # A new curl invocation recomputes -C's resume offset, preserving new bytes.
            Write-Output ('Retrying from the current file length: ' + $Name)
            Start-Sleep -Seconds 2
        }
        if ($Size -gt 0 -and (Get-Item -LiteralPath $path).Length -ne $Size) { throw ('Image file size mismatch: ' + $Name) }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Digest) { throw ('Image checksum mismatch: ' + $Name) }
    }
    Write-Output ('Verified SHA-256: ' + $Name)
}

Get-VerifiedFile ($registry + '/manifests/sha256:' + $indexDigest) 'index.json' $indexDigest
$index = Get-Content -LiteralPath (Join-Path $directory 'index.json') -Raw | ConvertFrom-Json
$matches = @($index.manifests | Where-Object { $_.digest -eq ('sha256:' + $childDigest) -and $_.platform.os -eq 'windows' -and $_.platform.architecture -eq 'amd64' })
if ($matches.Count -ne 1) { throw 'The pinned index does not identify the expected Windows amd64 image.' }
Get-VerifiedFile ($registry + '/manifests/sha256:' + $childDigest) 'child.json' $childDigest
$child = Get-Content -LiteralPath (Join-Path $directory 'child.json') -Raw | ConvertFrom-Json
if ($child.config.digest -ne ('sha256:' + $configDigest)) { throw 'Unexpected image configuration digest.' }
$configName = $configDigest + '.json'
Get-VerifiedFile ($registry + '/blobs/sha256:' + $configDigest) $configName $configDigest $child.config.size
$layerNames = @()
foreach ($layer in $child.layers) {
    if ($layer.mediaType -ne 'application/vnd.docker.image.rootfs.diff.tar.gzip' -or $layer.digest -notmatch '^sha256:([a-f0-9]{64})$') { throw 'Unexpected image layer descriptor.' }
    $digest = $layer.digest.Substring(7)
    $name = $digest + '.tar.gz'
    Get-VerifiedFile ($registry + '/blobs/sha256:' + $digest) $name $digest $layer.size
    $layerNames += $name
}
$archiveManifest = @{Config=$configName; RepoTags=@('cloudxr-lab-base:ws2025'); Layers=$layerNames}
$json = ConvertTo-Json -InputObject @($archiveManifest) -Depth 5
[IO.File]::WriteAllText((Join-Path $directory 'manifest.json'), $json, [Text.UTF8Encoding]::new($false))
$archive = Join-Path $directory 'windows-server-2025.tar'
# Docker's image loader decompresses each layer and verifies its uncompressed diffID.
# Only assemble the archive here; never extract Windows image layers onto the host.
& tar.exe -cf $archive -C $directory 'manifest.json' $configName @layerNames
if ($LASTEXITCODE -ne 0) { throw 'Image archive creation failed.' }
@{SourceIndex=('sha256:' + $indexDigest); SourceManifest=('sha256:' + $childDigest); ImageId=('sha256:' + $configDigest); Archive=$archive; VerifiedUtc=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'verified-image.json') -Encoding UTF8
Write-Output ('Verified image archive ready: ' + $archive)
