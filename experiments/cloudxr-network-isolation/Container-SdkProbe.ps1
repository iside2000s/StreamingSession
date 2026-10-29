$ErrorActionPreference = 'Stop'
# C:\nvidia-driver and C:\report are experiment-only container mounts.
if ($env:STREAMINGSESSION_CONTAINER_PROBE -ne '1' -or -not (Test-Path -LiteralPath C:\lab\CloudXrProbe.exe) -or -not (Test-Path -LiteralPath C:\runtime\cloudxr.dll)) { throw 'Run this script inside the lab container, not on the host.' }
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NativeDependency { [DllImport("kernel32", CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags); [DllImport("kernel32")] public static extern bool FreeLibrary(IntPtr module); }'
foreach ($name in @('nvcuda.dll','nvapi64.dll','vulkan-1.dll','MSVCP140.dll','MSVCP140_ATOMIC_WAIT.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','qwave.dll','cloudxr.dll')) {
    $path = Join-Path 'C:\runtime' $name
    if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path 'C:\Windows\System32' $name }
    $module = [NativeDependency]::LoadLibraryEx($path,[IntPtr]::Zero,8)
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Output ('DEPENDENCY ' + $name + ' exists=' + (Test-Path -LiteralPath $path) + ' loaded=' + ($module -ne [IntPtr]::Zero) + ' win32=' + $errorCode)
    if ($module -ne [IntPtr]::Zero) { $null = [NativeDependency]::FreeLibrary($module) }
}
if (Test-Path -LiteralPath C:\nvidia-driver\nv-vk64.json) {
    & reg.exe ADD 'HKLM\SOFTWARE\Khronos\Vulkan\Drivers' /v 'C:\nvidia-driver\nv-vk64.json' /t REG_DWORD /d 0 /f
    if ($LASTEXITCODE -ne 0) { throw 'Container-only Vulkan manifest registration failed.' }
}
& C:\lab\CloudXrProbe.exe --mode service --runtime C:\runtime --profile apple-vision-pro --enable-ice true --port 48322 --media-port 0 --log-dir C:\report --seconds 15 --stop-file C:\report\stop
$probeExitCode = $LASTEXITCODE
Get-ChildItem -LiteralPath C:\report -Recurse -File -Filter '*.log' | ForEach-Object { Write-Output ('INTERNAL_LOG ' + $_.Name); Get-Content -LiteralPath $_.FullName -Tail 140 }
exit $probeExitCode
