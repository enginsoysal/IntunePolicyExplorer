#Requires -Modules PowerShellGet
<#
.SYNOPSIS
    Publishes IntunePolicyExplorer module to the PowerShell Gallery.

.PARAMETER ApiKey
    Your PowerShell Gallery API key from https://www.powershellgallery.com/account/apikeys

.PARAMETER Version
    Module version to publish. Must be higher than any existing gallery version.

.EXAMPLE
    .\Publish-ToGallery.ps1 -ApiKey 'your-api-key-here'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApiKey,

    [string]$Version
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'IntunePolicyExplorer'

if ($Version) {
    $manifestPath = Join-Path $modulePath 'IntunePolicyExplorer.psd1'
    $content = Get-Content $manifestPath -Raw
    $content = $content -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion     = '$Version'"
    Set-Content -Path $manifestPath -Value $content -Encoding UTF8 -NoNewline
}

if (-not (Test-ModuleManifest -Path (Join-Path $modulePath 'IntunePolicyExplorer.psd1'))) {
    throw 'Module manifest validation failed.'
}

Write-Host "Publishing IntunePolicyExplorer from: $modulePath" -ForegroundColor Cyan
Publish-Module -Path $modulePath -NuGetApiKey $ApiKey -Repository PSGallery -Force
Write-Host 'Published successfully to https://www.powershellgallery.com/packages/IntunePolicyExplorer' -ForegroundColor Green
