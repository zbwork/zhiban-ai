# Run after installation as an ordinary user, never from an elevated installer.
param([Parameter(Mandatory = $true)][string]$InstallDir)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this verification from a non-elevated PowerShell session.'
}
$installation = (Resolve-Path -LiteralPath $InstallDir).Path
$node = Join-Path $installation 'local-agent/node/node.exe'
$entry = Join-Path $installation 'local-agent/dsh-runtime/dist/desktop/main.js'
foreach ($file in @($node, $entry)) {
  if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw 'Installed runtime component is missing.' }
}
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $node
$start.Arguments = '"' + $entry + '" --self-check'
$start.WorkingDirectory = $installation
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.Encoding]::UTF8
$start.StandardErrorEncoding = [Text.Encoding]::UTF8
$start.EnvironmentVariables.Clear()
# Match LocalAgentService._hostEnvironment; never inherit credentials or NODE_OPTIONS.
foreach ($name in @('HOME', 'USERPROFILE', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP',
    'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA')) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ($null -ne $value) { $start.EnvironmentVariables[$name] = $value }
}
$start.EnvironmentVariables['LANG'] = 'en_US.UTF-8'
$process = [Diagnostics.Process]::Start($start)
try {
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (!$process.WaitForExit(90000)) {
    $process.Kill() # The sandbox watches its parent and kills its Job on exit.
    throw 'Installed runtime verification timed out.'
  }
  if ($process.ExitCode -ne 0) {
    throw ('Installed runtime exited with code ' + $process.ExitCode)
  }
  $report = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
  foreach ($name in @('node', 'engine', 'office', 'isolation')) {
    if ($report.checks.$name -ne $true) { throw ('Installed runtime check failed: ' + $name) }
  }
  $report | ConvertTo-Json -Depth 3
  'Installed runtime probes passed as a non-elevated user.'
} finally {
  $process.Dispose()
}
