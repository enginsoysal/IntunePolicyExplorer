#Requires -Version 5.1
[CmdletBinding()]
param([double]$Width = 1000, [double]$Height = 700, [switch]$RunChecks)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Script:PreviewResultsDirectory = Join-Path $PSScriptRoot 'results'
$source = Get-Content (Join-Path $root 'Show-IntunePoliciesGUI.ps1') -Raw
$source = $source.Replace("if (-not (Install-GraphModuleIfNeeded)) {", 'if ($false) {')
# All substitutions live in this test harness. Production has no test-mode sign-in path.
$start = $source.LastIndexOf("try {`r`n    Import-Module Microsoft.Graph.Authentication")
if ($start -lt 0) { $start = $source.LastIndexOf("try {`n    Import-Module Microsoft.Graph.Authentication") }
if ($start -lt 0) { throw 'Could not locate startup session bootstrap.' }
$source = $source.Substring(0,$start)
$fixtures = @'
function Get-MgGraphSession { [PSCustomObject]@{ TenantId='OFFLINE-DEMO'; ClientId='fixture-client'; Account='offline@example.invalid'; Scopes=$Script:QuickConnectScopes } }
function Connect-ToGraphUniversal { Get-MgGraphSession }
function Disconnect-MgGraph { }
function Get-AllIntunePolicies {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($definition in @(@('one','Windows encryption - Corporate','Configuration Profiles'),@('two','Windows encryption - Pilot','Configuration Profiles'),@('three','iOS compliance','Compliance'),@('four','Unavailable configuration source','Settings Catalog'))) {
        $items.Add([PSCustomObject]@{Id=$definition[0]; Name=$definition[1]; Type=$definition[2]; Platform='Windows'; Endpoint='deviceManagement/deviceConfigurations'; DetailExpand=$null; AssignmentCount=$null; Created='2026-06-01'; Modified='2026-06-22'; Description='Offline fixture'; Raw=$null})
    }
    [PSCustomObject]@{Policies=$items; Errors=[Collections.Generic.List[string]]::new()}
}
function Invoke-MgGraphRequest {
    param($Method,$Uri,$OutputType)
    if ($Uri -match '/four') { throw '403: Synthetic access denied (offline fixture)' }
    if ($Uri -match '/two/assignments') { return [PSCustomObject]@{value=@()} }
    if ($Uri -match '/assignments') { return [PSCustomObject]@{value=@([PSCustomObject]@{id='allDevices'})} }
    [PSCustomObject]@{ requireDeviceEncryption=($Uri -notmatch '/two'); defenderEnabled=$false; passwordRequired=$true; exampleLongSetting='Long setting values remain accessible with horizontal scrolling.' }
}
$window.Title='Intune Policy Explorer - OFFLINE TEST'
$txtSubtitle.Text='OFFLINE TEST - synthetic data, no Microsoft sign-in or tenant access'
'@
$source += $fixtures + "`n`$window.Width=$Width; `$window.Height=$Height`n"
if ($RunChecks) { $source += Get-Content (Join-Path $PSScriptRoot 'Invoke-GuiChecks.ps1') -Raw }
else { $source += "`n[void]`$window.ShowDialog()`n" }
$source += "`n}`nShow-IntunePoliciesGUI`n"
try { & ([scriptblock]::Create($source)) }
catch { $_ | Out-String | Set-Content (Join-Path $PSScriptRoot 'results/preview-error.txt'); throw }
