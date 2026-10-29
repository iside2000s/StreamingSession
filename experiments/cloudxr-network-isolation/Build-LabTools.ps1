[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'out'
$include = Join-Path $out 'include'
$tools = Join-Path $out 'tools'
$payload = Join-Path $out 'payload'
$null = New-Item -ItemType Directory -Path $include,$tools,$payload -Force
function Get-VerifiedFile([string]$Url, [string]$Path, [string]$Sha256) {
    if (-not (Test-Path -LiteralPath $Path)) { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha256) { throw ('Unexpected download hash: ' + $Path) }
}
Get-VerifiedFile 'https://raw.githubusercontent.com/NVIDIA/VideoProcessingFramework/master/src/TC/third_party/nvEncodeAPI.h' (Join-Path $include 'nvEncodeAPI.h') '067C51597E586B72CED8127B2456F48DFE3A9F7D7E0D00DCBB26F9535C05B4AD'
$archive = Join-Path $tools 'docker-29.9.2.zip'
Get-VerifiedFile 'https://download.docker.com/win/static/stable/x86_64/docker-29.9.2.zip' $archive 'B2BE959BFED1281DDAF665C0972CBA9A62CE30C542B6BCCE82F055BF8886BC7D'
$engineDirectory = Join-Path $tools 'engine-29.9.2'
if (-not (Test-Path -LiteralPath (Join-Path $engineDirectory 'docker\dockerd.exe'))) {
    Expand-Archive -LiteralPath $archive -DestinationPath $engineDirectory -Force
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual Studio C++ tools are required.' }
& (Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe') (Join-Path $PSScriptRoot 'GpuEncodeProbe.vcxproj') /nologo /v:minimal /p:Configuration=Release /p:Platform=x64
if ($LASTEXITCODE -ne 0) { throw 'GPU encode probe build failed.' }
Copy-Item -LiteralPath (Join-Path $out 'GpuEncodeProbe.exe') -Destination $payload -Force
& (Join-Path $out 'GpuEncodeProbe.exe')
if ($LASTEXITCODE -ne 0) { throw 'Host GPU encode check failed; do not proceed to container setup.' }
Write-Output 'Prepared local tools only. No container engine or Windows feature was started.'
