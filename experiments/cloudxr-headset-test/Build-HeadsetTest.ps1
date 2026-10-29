[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$out = Join-Path $PSScriptRoot 'out'
$app = Join-Path $out 'app'
$outputPrefix = [IO.Path]::GetFullPath($out).TrimEnd('\') + '\'
foreach ($process in @(Get-Process -Name FoveatedStreamingSample, SignalingGateway, GatewayTests, StreamingSession-OpenXRSample -ErrorAction SilentlyContinue)) {
    if ($process.Path -and $process.Path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'This experiment is still running. Stop it with Stop-HeadsetTest.ps1 before rebuilding; no process was stopped.'
    }
}
$null = New-Item -ItemType Directory -Path $out, $app -Force
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual Studio 2022 C++ tools are required.' }
$msbuild = Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
$compiler = Join-Path $installation 'MSBuild\Current\Bin\Roslyn\csc.exe'
$appOutput = $app.Replace('\', '/') + '/'
$appIntermediate = (Join-Path $out 'obj-app').Replace('\', '/') + '/'
& $msbuild (Join-Path $repository 'StreamingSession-WindowsApp\FoveatedStreamingSample.csproj') /nologo /v:minimal /p:Configuration=Release /p:Platform=AnyCPU "/p:OutputPath=$appOutput" "/p:BaseIntermediateOutputPath=$appIntermediate" "/p:IntermediateOutputPath=$appIntermediate" /p:TargetPlatformVersion=10.0.26100.0
if ($LASTEXITCODE -ne 0) { throw 'Experimental Windows app build failed.' }
$sourceServer = Join-Path $repository 'StreamingSession-WindowsApp\bin\Release\Server'
$targetServer = Join-Path $app 'Server'
$null = New-Item -ItemType Directory -Path $targetServer -Force
Get-ChildItem -LiteralPath $sourceServer | Copy-Item -Destination $targetServer -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repository 'StreamingSession-WindowsApp\bin\Release\NvStreamManagerClient.dll') -Destination $app -Force
$json = Join-Path $app 'Newtonsoft.Json.dll'
$gatewaySource = Join-Path $PSScriptRoot 'SignalingGateway.cs'
& $compiler /nologo /target:exe /platform:x64 /optimize+ /warn:4 /warnaserror+ /langversion:7.3 "/reference:$json" /reference:System.dll /reference:System.Core.dll "/out:$(Join-Path $out 'SignalingGateway.exe')" $gatewaySource
if ($LASTEXITCODE -ne 0) { throw 'Signaling gateway build failed.' }
& $compiler /nologo /target:exe /platform:x64 /optimize+ /warn:4 /warnaserror+ /langversion:7.3 "/reference:$json" /reference:System.dll /reference:System.Core.dll /main:StreamingSessionExperiments.GatewayTests "/out:$(Join-Path $out 'GatewayTests.exe')" $gatewaySource (Join-Path $PSScriptRoot 'GatewayTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Gateway test build failed.' }
Copy-Item -LiteralPath $json -Destination $out -Force
$cubeOutput = (Join-Path $out 'cube').Replace('\', '/') + '/'
$cubeIntermediate = (Join-Path $out 'obj-cube').Replace('\', '/') + '/'
& $msbuild (Join-Path $repository 'StreamingSession-OpenXRSample\StreamingSession-OpenXRSample.vcxproj') /nologo /v:minimal /p:Configuration=Release /p:Platform=x64 "/p:OutDir=$cubeOutput" "/p:IntDir=$cubeIntermediate"
if ($LASTEXITCODE -ne 0) { throw 'OpenXR cube build failed.' }
$testDirectory = Join-Path $PSScriptRoot ('test-results\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
& (Join-Path $out 'GatewayTests.exe') $testDirectory
if ($LASTEXITCODE -ne 0) { throw 'Signaling gateway integration checks failed.' }
Write-Output ('Experimental app: ' + (Join-Path $app 'FoveatedStreamingSample.exe'))
