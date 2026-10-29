[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$site = Join-Path $out 'site'
$null = New-Item -ItemType Directory -Path $site -Force
$archive = Join-Path $out 'nvidia-cloudxr-6.4.0.tgz'
$expected = [BitConverter]::ToString([Convert]::FromBase64String('36oZmZtCVEPoivkquSp+TwaGfi90ovLg9khzE/uMJ+c=')).Replace('-','')
if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.ngc.nvidia.com/v2/resources/nvidia/cloudxr-js/versions/6.4.0/files/nvidia-cloudxr-6.4.0.tgz'
    $download = [string]$response.Headers['Location']
    if (-not $download) { throw 'NGC did not provide a download location.' }
    Invoke-WebRequest -UseBasicParsing -Uri $download -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'CloudXR.js package SHA-256 mismatch.' }
Push-Location $PSScriptRoot
try {
    & npm.cmd install --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'Experimental web dependencies failed to install.' }
    & (Join-Path $PSScriptRoot 'node_modules\.bin\esbuild.cmd') client.js --bundle --format=esm --target=es2022 ('--outfile=' + (Join-Path $site 'bundle.js'))
    if ($LASTEXITCODE -ne 0) { throw 'Web client build failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'index.html') -Destination $site -Force
}
finally { Pop-Location }
