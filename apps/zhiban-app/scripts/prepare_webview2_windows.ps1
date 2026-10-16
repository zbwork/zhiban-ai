# Build-machine dependency preparation; never run this installer on the builder.
param([string]$Output = (Join-Path $PSScriptRoot '../build/windows-dependencies/MicrosoftEdgeWebView2RuntimeInstallerX64.exe'))
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($Output)
function Assert-MicrosoftInstaller([string]$Path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
    throw 'WebView2 installer must have a valid Microsoft Authenticode signature'
  }
  $product = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
  if ($product.ProductName -notmatch 'Microsoft Edge') { throw 'Unexpected WebView2 installer product' }
}
if (!(Test-Path -LiteralPath $destination)) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
  $temporary = $destination + '.' + [guid]::NewGuid() + '.download.exe'
  try {
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124701' -OutFile $temporary
    Assert-MicrosoftInstaller $temporary
    Move-Item -LiteralPath $temporary -Destination $destination
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
  }
}
Assert-MicrosoftInstaller $destination
Get-FileHash -LiteralPath $destination -Algorithm SHA256
