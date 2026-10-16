# Embedded fixed-purpose MSIX worker. Values substituted once before RunAs.
# No command, path, digest or identity is accepted from the pipe client.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Do not import user-supplied modules into the elevated worker (or inherit a
# PowerShell 7 module path when this worker deliberately runs Windows PS 5.1).
$env:PSModulePath = "$PSHOME\Modules"
$pipe = $null
$package = $null
$writer = $null
try {
    $security = New-Object System.IO.Pipes.PipeSecurity
    foreach ($sid in @(__USER_SID__, 'S-1-5-18')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.IO.Pipes.PipeAccessRule($identity, [System.IO.Pipes.PipeAccessRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    $security.SetAccessRuleProtection($true, $false)
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(__PIPE_NAME__, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 4096, 4096, $security)
    $connected = $pipe.WaitForConnectionAsync()
    if (-not $connected.Wait(300000)) { exit 4 }
    $null = $connected.GetAwaiter().GetResult()
    $reader = New-Object System.IO.StreamReader($pipe)
    $writer = New-Object System.IO.StreamWriter($pipe)
    $writer.AutoFlush = $true
    $writer.WriteLine('ready')
    $request = $reader.ReadLineAsync()
    if (-not $request.Wait(2700000)) { exit 4 }
    if ($request.GetAwaiter().GetResult() -cne 'install') { exit 0 }

    # Keep the same bytes locked against writes and deletes through registration.
    $package = [System.IO.File]::Open(__PACKAGE_PATH__, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($package)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $allowed = @(__SOURCE_LOCKS__)
    $matches = @($allowed | Where-Object { $_.size -eq $package.Length -and $_.hash -ceq $digest })
    if ($matches.Count -eq 0) { throw 'Package integrity mismatch' }
    $signature = Get-AuthenticodeSignature -LiteralPath __PACKAGE_PATH__
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne __SIGNER__) { throw 'Package signature mismatch' }
    Add-Type -AssemblyName System.IO.Compression
    $package.Position = 0
    $archive = New-Object System.IO.Compression.ZipArchive($package, [System.IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $entry -or $entry.Length -gt 4194304) { throw 'Invalid manifest' }
        $stream = $entry.Open()
        try {
            $settings = New-Object System.Xml.XmlReaderSettings
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = 4194304
            $xmlReader = [System.Xml.XmlReader]::Create($stream, $settings)
            try {
                $manifest = New-Object System.Xml.XmlDocument
                $manifest.XmlResolver = $null
                $manifest.Load($xmlReader)
            } finally { $xmlReader.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
    $identity = $manifest.DocumentElement.SelectSingleNode("*[local-name()='Identity']")
    $application = $manifest.DocumentElement.SelectSingleNode("*[local-name()='Applications']/*[local-name()='Application']")
    if ($null -eq $identity -or $null -eq $application -or $identity.GetAttribute('Name') -cne __PACKAGE_NAME__ -or -not $identity.GetAttribute('Version').StartsWith(__PACKAGE_VERSION__, [StringComparison]::Ordinal) -or $identity.GetAttribute('ProcessorArchitecture') -cne __PACKAGE_ARCH__) { throw 'Package identity mismatch' }
    Add-AppxPackage -Path __PACKAGE_PATH__ __UPDATE_FLAG__ -ErrorAction Stop
    $writer.WriteLine('ok')
} catch {
    # Only a numeric system code crosses into the ordinary client. Native error
    # text may contain profile paths and remains in the Windows deployment log.
    if ($null -ne $writer) {
        try { $writer.WriteLine(('error:0x{0:X8}' -f $_.Exception.HResult)) } catch {}
    }
    exit 3
} finally {
    if ($null -ne $package) { $package.Dispose() }
    if ($null -ne $pipe) { $pipe.Dispose() }
}
