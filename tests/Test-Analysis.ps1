#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Show-IntunePoliciesGUI.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$app = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-IntunePoliciesGUI' }, $true)
# Load the actual production function definitions without opening a window or contacting Graph.
foreach ($fn in $app.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$Script:AppVersion = '1.3.2'; $Script:CurrentTenant = 'offline-test'; $Script:PolicyLoadErrors = @()
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Output "PASS: $Message"
}
function Set-Status { param([string]$Message) }
function New-TestPolicy([string]$Id, [string]$Name = 'Test policy') {
    [PSCustomObject]@{ Id=$Id; Name=$Name; Type='Configuration Profiles'; Platform='windows10GeneralConfiguration'; Endpoint='deviceManagement/deviceConfigurations'; DetailExpand=$null; AssignmentCount=$null; Modified='2026-06-22'; Created='2026-06-01'; Description='Fixture'; Raw=$null }
}
function New-TestSetting([string]$Id, [string]$Value, [string]$Platform = 'Windows', [string]$Type = 'Configuration Profiles') {
    [PSCustomObject]@{ PolicyId=$Id; PolicyName=$Id; PolicyType=$Type; Platform=$Platform; Category='General'; Setting='requireDeviceEncryption'; Value=$Value; SearchBlob="requiredeviceencryption $Value" }
}

$policies = @((New-TestPolicy 'empty'), (New-TestPolicy 'denied'), (New-TestPolicy 'assigned'), (New-TestPolicy 'detail-failure'))
function Invoke-MgGraphRequest {
    param($Method, $Uri, $OutputType)
    if ($Uri -match '/denied/assignments') { throw '403: access denied <test>' }
    if ($Uri -match '/empty/assignments') { return [PSCustomObject]@{value=@()} }
    if ($Uri -match '/assignments') { return [PSCustomObject]@{value=@([PSCustomObject]@{id='target'})} }
    if ($Uri -match '/detail-failure$') { throw '429: request exhausted retries' }
    return [PSCustomObject]@{ requireDeviceEncryption=$false; defenderEnabled=$false }
}
$a = Invoke-TenantAnalysis -Policies $policies
Assert (-not $a.IsComplete) 'Partial analysis is incomplete'
Assert ($a.LoadErrors.Count -eq 2) 'Assignment and detail errors are both retained'
Assert ($a.AssignmentsLoaded -eq 3 -and $a.SettingsLoaded -eq 3) 'Coverage counts include successful empty responses'
Assert ($null -eq $policies[1].AssignmentCount) 'Denied assignments remain unknown'
Assert ($policies[0].AssignmentCount -eq 0 -and $policies[2].AssignmentCount -eq 1) 'Empty and populated assignments remain distinct'
Assert (@($a.Health | Where-Object Finding -eq 'Unassigned').Count -eq 1) 'Only successfully fetched empty assignments become Unassigned'
Assert (@($a.Health | Where-Object Finding -like '*unavailable').Count -eq 2) 'Collection errors appear in Policy health'
Assert (@($a.Recommendations | Where-Object Status -in @('Pass','Fail')).Count -eq 0) 'Disabled settings cannot produce security Pass or Fail'
Assert (@($a.Recommendations | Where-Object Status -eq 'Unknown').Count -gt 0) 'Missing evidence is Unknown for partial collection'
Assert ((Get-AnalysisSummary $a) -match 'INCOMPLETE.*assignments 3/4.*settings 3/4') 'UI summary exposes partial coverage'

$Script:PolicyLoadErrors = @('App Protection: 403 unavailable')
$b = Invoke-TenantAnalysis -Policies @($policies[0])
Assert (@($b.LoadErrors | Where-Object Stage -eq 'Inventory').Count -eq 1) 'Previously failed inventory sources propagate into analysis'
Assert (-not $b.IsComplete) 'Successful details cannot hide inventory errors'
$Script:PolicyLoadErrors = @()
$c = Invoke-TenantAnalysis -Policies @($policies[0])
Assert ($c.IsComplete -and $c.LoadErrors.Count -eq 0) 'A later successful analysis does not retain previous errors'
Assert (@($c.Recommendations | Where-Object Status -in @('Pass','Fail','Unknown')).Count -eq 0) 'Complete inventory produces informational hints and warnings only'
$empty = Invoke-TenantAnalysis -Policies @()
Assert ($empty.PolicyCount -eq 0 -and $empty.SettingsIndex.Count -eq 0) 'Empty tenant can be analyzed without exceptions'
$missing = @(Get-PolicyHealthFindings -Policies @($policies[1]) -AssignmentMap @{})
Assert (@($missing | Where-Object Finding -eq 'Unassigned').Count -eq 0) 'Missing assignment map entry is never Unassigned'

$rows = @((New-TestSetting 'one' 'False'), (New-TestSetting 'two' 'True'))
$conflicts = @(Get-SettingConflicts $rows)
Assert ($conflicts.Count -eq 1 -and $conflicts[0].Detail -match 'Potential.*not been evaluated') 'Different values across policies produce explicitly potential conflicts'
Assert (@(Get-SettingConflicts @($rows[0],$rows[0])).Count -eq 0) 'Identical values do not conflict'
Assert (@(Get-SettingConflicts @($rows[0],(New-TestSetting 'one' 'True'))).Count -eq 0) 'Repeated setting in one policy is not a cross-policy conflict'
Assert (@(Get-SettingConflicts @($rows[0],(New-TestSetting 'two' 'True' 'iOS'))).Count -eq 0) 'Different platforms are not compared'
Assert (@(Get-SettingConflicts @($rows[0],(New-TestSetting 'two' 'True' 'Windows' 'Compliance'))).Count -eq 0) 'Different policy types are not compared'
$info = New-TestSetting 'two' 'True'; $info.Category='Info'
Assert (@(Get-SettingConflicts @($rows[0],$info)).Count -eq 0) 'Raw fallback objects are excluded from conflicts'
$jsonRows = @((New-TestSetting 'one' '{"id":"first","enabled":false,"values":[1,2]}'), (New-TestSetting 'two' '{"values":[1,2],"enabled":false,"id":"second"}'))
Assert (@(Get-SettingConflicts $jsonRows).Count -eq 0) 'JSON property order and per-policy object IDs do not create conflicts'
$jsonRows[1].Value='{"enabled":true,"values":[1,2]}'
Assert (@(Get-SettingConflicts $jsonRows).Count -eq 1) 'Actual JSON value differences remain detectable'
Assert ((Get-SettingComparisonValue 'not JSON') -eq 'not JSON') 'Plain string values remain comparable'

$script:pageCalls = 0
function Invoke-MgGraphRequest {
    param($Method, $Uri, $OutputType)
    $script:pageCalls++
    if ($Uri -eq 'page1') { return [PSCustomObject]@{value=@([PSCustomObject]@{id='a'}); '@odata.nextLink'='page2'} }
    if ($Uri -eq 'page2') { return [PSCustomObject]@{value=@([PSCustomObject]@{id='b'})} }
    throw '503 final page failed'
}
$pages = @(Invoke-GraphPaged 'page1')
Assert ($pages.Count -eq 2 -and $script:pageCalls -eq 2) 'Pagination fetches all pages'
$threw = $false
try { Invoke-GraphPaged 'bad' | Out-Null } catch { $threw=$true }
Assert $threw 'Failed collection requests propagate to coverage handling'
function Invoke-MgGraphRequest {
    param($Method, $Uri, $OutputType)
    if ($Uri -eq 'empty-first') { return [PSCustomObject]@{value=@(); '@odata.nextLink'='nonempty-last'} }
    if ($Uri -eq 'nonempty-last') { return [PSCustomObject]@{value=@([PSCustomObject]@{id='last'})} }
    if ($Uri -eq 'malformed') { return [PSCustomObject]@{unexpected='response'} }
    if ($Uri -eq 'settings-last') { return [PSCustomObject]@{value=@([PSCustomObject]@{settingInstance=[PSCustomObject]@{settingDefinitionId='second'}})} }
    return [PSCustomObject]@{id='catalog'; settings=@([PSCustomObject]@{settingInstance=[PSCustomObject]@{settingDefinitionId='first'}}); 'settings@odata.nextLink'='settings-last'}
}
Assert (@(Invoke-GraphPaged 'empty-first').Count -eq 1) 'Empty intermediate page still follows nextLink'
$threw=$false
try { Invoke-GraphPaged 'malformed' | Out-Null } catch { $threw=$true }
Assert $threw 'Malformed responses cannot masquerade as empty assignments'
$catalog=New-TestPolicy 'catalog'; $catalog.DetailExpand='settings'
$detail=Get-PolicyDetail $catalog
Assert ($detail.settings.Count -eq 2) 'Expanded settings collections follow their own nextLink'
$catalogRows=@(Convert-PolicyToSettingsList -Detail $detail -Type 'Settings Catalog')
Assert ($catalogRows[0].Setting -eq 'first' -and $catalogRows[1].Setting -eq 'second') 'Expanded page contents remain flat and searchable'
$emptyValue=Get-GraphProperty -Object @{ value=@() } -Name 'value'
Assert ($null -ne $emptyValue -and $emptyValue.Count -eq 0) 'Graph dictionary properties preserve an empty collection'

Add-Type -AssemblyName System.Web
$exportFolder = Join-Path $env:TEMP ('IntunePolicyExplorer-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $exportFolder | Out-Null
$reportPath = @(Export-AuditReport -Policies $policies -Analysis $a -Folder $exportFolder)[0]
$html = Get-Content -LiteralPath $reportPath -Raw
Assert ($html -match 'INCOMPLETE' -and $html -match 'Data collection errors') 'Audit HTML exposes incomplete collection'
Assert ($html -match 'Unknown' -and $html -match 'Potential Setting Conflicts') 'Audit HTML uses unknown and potential conflict labels'
Assert ($html -match '&lt;test&gt;' -and $html -notmatch 'access denied <test>') 'Error text is HTML encoded'
Assert ($html -notmatch '>Passed<' -and $html -notmatch '>Failed<') 'Audit cards do not claim security compliance'
Import-Module (Join-Path $root 'IntunePolicyExplorer.psd1') -Force
Assert (@(Get-Command -Module IntunePolicyExplorer).Count -eq 1) 'Module imports without launching GUI and exports only intended command'
Remove-Module IntunePolicyExplorer
Write-Output "Analysis regression checks passed: $script:checks"
