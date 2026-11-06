#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '../dist' }
$root = Split-Path $PSScriptRoot -Parent
$manifest = Import-PowerShellDataFile (Join-Path $root 'IntunePolicyExplorer.psd1')
$version = $manifest.ModuleVersion
$source = Get-Content (Join-Path $root 'Show-IntunePoliciesGUI.ps1') -Raw
if ($source -notmatch ('\$Script:AppVersion = ''' + [regex]::Escape($version) + '''')) {
    throw 'Manifest and application version differ.'
}
$files = @('IntunePolicyExplorer.psd1', 'IntunePolicyExplorer.psm1', 'Show-IntunePoliciesGUI.ps1', 'LICENSE', 'README.md', 'CHANGELOG.md')
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$package = Join-Path $output "IntunePolicyExplorer/$version"
New-Item -ItemType Directory -Force -Path $package | Out-Null
# An allowlist prevents local files, credentials and previous build products entering a release.
$unexpected = @(Get-ChildItem -LiteralPath $package -File | Where-Object { $_.Name -notin $files })
if ($unexpected.Count -or @(Get-ChildItem -LiteralPath $package -Directory).Count) {
    throw "Output package contains unexpected files. Use a fresh output directory: $package"
}
foreach ($file in $files) {
    $text = [IO.File]::ReadAllText((Join-Path $root $file)).Replace("`r`n", "`n")
    $isPowerShell = [IO.Path]::GetExtension($file) -in @('.ps1','.psm1','.psd1')
    if ($isPowerShell) { $text = $text.Replace("`n", "`r`n") }
    # BOM keeps non-ASCII UI strings intact in Windows PowerShell 5.1.
    [IO.File]::WriteAllText((Join-Path $package $file), $text, [Text.UTF8Encoding]::new($isPowerShell))
}
Test-ModuleManifest (Join-Path $package 'IntunePolicyExplorer.psd1') | Out-Null
Import-Module (Join-Path $package 'IntunePolicyExplorer.psd1') -Force
if (-not (Get-Command Show-IntunePoliciesGUI -Module IntunePolicyExplorer)) { throw 'Packaged command is missing.' }
Remove-Module IntunePolicyExplorer
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $output "IntunePolicyExplorer-$version.zip"
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::Create)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in ($files | Sort-Object)) {
            $entry = $zip.CreateEntry("IntunePolicyExplorer/$version/$file", [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $destination = $entry.Open()
            try { $bytes = [IO.File]::ReadAllBytes((Join-Path $package $file)); $destination.Write($bytes, 0, $bytes.Length) }
            finally { $destination.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
$checksums = @($files | Sort-Object | ForEach-Object {
    "{0}  IntunePolicyExplorer/{1}/{2}" -f (Get-FileHash -LiteralPath (Join-Path $package $_) -Algorithm SHA256).Hash.ToLowerInvariant(), $version, $_
})
$checksums += "{0}  {1}" -f (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($zipPath)
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $checksums, [Text.UTF8Encoding]::new($false))
Write-Output "Built $zipPath"
