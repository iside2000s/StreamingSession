[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'An administrator PowerShell is required.' }
if ((Get-WindowsOptionalFeature -Online -FeatureName Containers).State -ne 'Enabled') { throw 'Enable Containers with the reviewed setup script and complete any required restart first.' }
$engine = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\dockerd.exe'
$client = Join-Path $PSScriptRoot 'out\tools\engine-29.9.2\docker\docker.exe'
if (-not (Test-Path -LiteralPath $engine)) { throw 'Run Build-LabTools.ps1 first.' }
$state = Join-Path $PSScriptRoot 'state'
$manifestPath = Join-Path $state 'engine.json'
if (Test-Path -LiteralPath $manifestPath) {
    $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $previousProcess = Get-Process -Id $previous.ProcessId -ErrorAction SilentlyContinue
    if ($previousProcess -and $previousProcess.Path -eq $engine -and $previousProcess.StartTime.ToUniversalTime().ToString('o') -eq $previous.StartTimeUtc) {
        throw 'The owned lab engine is already running; no process was stopped.'
    }
}
$pipeName = 'streamingsession-cloudxr-lab'
if ([IO.File]::Exists('\\.\pipe\' + $pipeName)) { throw 'The dedicated lab pipe is already in use.' }
$null = New-Item -ItemType Directory -Path $state -Force
$config = Join-Path $state 'daemon.json'
$data = Join-Path $state 'engine-data'
$hostEndpoint = 'npipe:////./pipe/' + $pipeName
@{'hosts'=@($hostEndpoint); 'data-root'=$data; 'pidfile'=(Join-Path $state 'dockerd.pid'); 'bridge'='none'} |
    ConvertTo-Json | Set-Content -LiteralPath $config -Encoding ASCII
$process = Start-Process -FilePath $engine -ArgumentList ('--config-file "' + $config + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $state 'engine.stdout.log') -RedirectStandardError (Join-Path $state 'engine.stderr.log')
@{ProcessId=$process.Id; StartTimeUtc=$process.StartTime.ToUniversalTime().ToString('o'); Executable=$engine; DockerClient=$client; HostEndpoint=$hostEndpoint; DataDirectory=$data} |
    ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while ([DateTime]::UtcNow -lt $deadline) {
    if ($process.HasExited) { throw 'Lab engine exited; inspect state/engine.stderr.log. No unrelated process was stopped.' }
    $ErrorActionPreference = 'Continue' # Windows PowerShell treats native stderr as ErrorRecord.
    try {
        & $client --host $hostEndpoint info --format '{{.OSType}}' 2>$null
        $clientExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = 'Stop' }
    if ($clientExitCode -eq 0) { Write-Output ('Lab engine ready: ' + $hostEndpoint); return }
    Start-Sleep -Milliseconds 500
}
throw 'Engine readiness timed out. Its owned PID is recorded in state/engine.json; use Stop-ContainerEngine.ps1.'
