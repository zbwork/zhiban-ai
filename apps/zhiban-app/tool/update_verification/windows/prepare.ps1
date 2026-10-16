param([string]$WinSparkleDir = $env:WINSPARKLE_DIR, [string]$OpenSsl = '')
$ErrorActionPreference = 'Stop'
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (!$WinSparkleDir) { $WinSparkleDir = Join-Path $appRoot 'windows/runner/third_party/WinSparkle' }
$WinSparkleDir = (Resolve-Path $WinSparkleDir).Path
foreach ($part in @('include/winsparkle.h', 'x64/WinSparkle.lib', 'x64/WinSparkle.dll')) {
    if (!(Test-Path (Join-Path $WinSparkleDir $part))) { throw "Missing WinSparkle SDK file: $part" }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -property installationPath
$cmake = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$iscc = @((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
          (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$OpenSsl) {
    $gitRoot = Split-Path (Split-Path (Get-Command git).Source)
    $OpenSsl = Join-Path $gitRoot 'usr/bin/openssl.exe'
}
if (!(Test-Path $cmake) -or !$iscc -or !(Test-Path $OpenSsl)) {
    throw 'Requires Visual Studio CMake, Inno Setup 6, and Git OpenSSL (or -OpenSsl path).'
}
$probeId = [guid]::NewGuid().ToString()
$probe = Join-Path $env:TEMP "easyo-update-$probeId"
New-Item -ItemType Directory -Path $probe | Out-Null
$env:EASYO_UPDATE_PROBE = $probe

function Run-Native([string]$exe, [string[]]$arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @arguments 2>&1 | Tee-Object -FilePath (Join-Path $probe 'prepare.log') -Append | Out-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    if ($code -ne 0) { throw "$exe failed with exit code $code; see $probe/prepare.log" }
}

$key = Join-Path $probe 'test-key.pem'
try {
    # Ephemeral fixture key only. Never touches release keys or user key stores.
    Run-Native $OpenSsl @('genpkey', '-algorithm', 'ED25519', '-out', $key)
    $der = Join-Path $probe 'test-public.der'
    Run-Native $OpenSsl @('pkey', '-in', $key, '-pubout', '-outform', 'DER', '-out', $der)
    $bytes = [IO.File]::ReadAllBytes($der)
    if ($bytes.Length -ne 44) { throw 'Unexpected Ed25519 public key encoding' }
    $publicKey = [Convert]::ToBase64String($bytes[12..43])
    Run-Native $cmake @('-S', $PSScriptRoot, '-B', "$probe/build", '-A', 'x64',
        "-DWINSPARKLE_DIR=$WinSparkleDir", "-DTEST_PUBLIC_KEY=$publicKey")
    Run-Native $cmake @('--build', "$probe/build", '--config', 'Release')
    Run-Native $iscc @("/DProbeRoot=$probe", "/DProbeId=$probeId", (Join-Path $PSScriptRoot 'fixture.iss'))
    Run-Native $OpenSsl @('pkeyutl', '-sign', '-rawin', '-inkey', $key,
        '-in', "$probe/fixture-101.exe", '-out', "$probe/signature.bin")
    $signature = [IO.File]::ReadAllBytes("$probe/signature.bin")
    if ($signature.Length -ne 64) { throw 'Unexpected Ed25519 signature size' }
    [IO.File]::WriteAllText("$probe/signature", [Convert]::ToBase64String($signature))
    Copy-Item "$probe/build/100" "$probe/installed" -Recurse
    Write-Host "READY: $probe"
    Write-Host 'Run: flutter --no-version-check test --no-pub tool/update_verification/windows/native_cache_test.dart --reporter expanded'
} finally {
    if (Test-Path $key) { Remove-Item -LiteralPath $key }
}
