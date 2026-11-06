#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Web
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Show-IntunePoliciesGUI.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$app=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-IntunePoliciesGUI'},$true)
foreach ($fn in $app.Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Set-Status { param([string]$Message) }
function Get-PolicyDetail { param($Item) return $script:FixtureDetail }
function Assert-Collection($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:collectionChecks++
    Write-Output "PASS: $Message"
}
$script:collectionChecks=0
$detailFunction=$app.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-PolicyDetails'},$true)
$tryBlock=$detailFunction.Body.Find({param($n) $n -is [Management.Automation.Language.TryStatementAst]},$true).Body.Extent.Text
# Execute the actual production detail-display path, allowing exceptions to fail the test
# instead of being swallowed by its interactive MessageBox catch handler.
$displayDetails=[scriptblock]::Create($tryBlock.Substring(1,$tryBlock.Length-2))
$dgSettings=[Windows.Controls.DataGrid]::new()
$txtSelectedPolicy=[Windows.Controls.TextBlock]::new()
$txtSelectedMeta=[Windows.Controls.TextBlock]::new()
$policyTypes=@('Administrative Templates','Settings Catalog','Endpoint Security','Configuration Profiles','Compliance','Windows Autopilot','App Protection (iOS)','App Protection (Android)','App Protection (Windows)','Mobile App Configurations')
foreach ($type in $policyTypes) {
    foreach ($count in @(0,1,2)) {
        $script:FixtureDetail=[PSCustomObject]@{id='fixture';displayName='Fixture'}
        $values=@(for ($i=0;$i -lt $count;$i++) {
            switch ($type) {
                'Administrative Templates' { [PSCustomObject]@{id="object-$i";enabled=$true;definition=[PSCustomObject]@{displayName="ADMX setting $i"}} }
                'Settings Catalog' { [PSCustomObject]@{settingInstance=[PSCustomObject]@{settingDefinitionId="catalog-$i";simpleSettingValue=[PSCustomObject]@{value=$i}}} }
                'Endpoint Security' { [PSCustomObject]@{definitionId="security-$i";valueJson='true'} }
            }
        })
        switch ($type) {
            'Administrative Templates' { $script:FixtureDetail | Add-Member definitionValues $values }
            'Settings Catalog' { $script:FixtureDetail | Add-Member settings $values }
            'Endpoint Security' { $script:FixtureDetail | Add-Member settings $values }
            default { for ($i=0;$i -lt $count;$i++) { $script:FixtureDetail | Add-Member "setting$i" $true } }
        }
        $Item=[PSCustomObject]@{Id='fixture';Name='Microsoft Scout for Windows (synthetic fixture)';Type=$type}
        . $displayDetails
        $expected=[Math]::Max(1,$count) # Zero configured settings exposes the raw object as one Info row.
        Assert-Collection ($dgSettings.Items.Count -eq $expected) "$type / $count configured settings binds $expected rows without a WPF exception"
        Assert-Collection ($txtSelectedMeta.Text -match "$expected settings") "$type / $count settings label is correct"
    }
}

# Both lazy-index and cached-index search paths must bind zero, one and multiple matches.
$bindings=@($app.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$dgFindResults.ItemsSource' -and $n.Right.Extent.Text -match 'Search-PolicySettings'},$true))
$dgFindResults=[Windows.Controls.DataGrid]::new()
$query='needle'; $Script:FindSettingQuery=$query
foreach ($count in @(0,1,2)) {
    $Script:SettingsIndex=@(for ($i=0;$i -lt $count;$i++) { [PSCustomObject]@{Setting="needle-$i";Value='true';SearchBlob="needle-$i true"} })
    foreach ($binding in $bindings) {
        . ([scriptblock]::Create($binding.Extent.Text))
        Assert-Collection ($dgFindResults.Items.Count -eq $count) "Search binding / $count matches displays $count rows"
    }
}
Assert-Collection ($bindings.Count -eq 2) 'Both production search binding paths are covered'
$exportFolder=Join-Path $env:TEMP ('IntunePolicyExplorer-collections-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $exportFolder | Out-Null
$exportItem=[PSCustomObject]@{Id='admx';Name='ADMX fixture';Type='Administrative Templates';Description='Synthetic regression fixture'}
foreach ($count in @(0,1,2)) {
    $script:FixtureDetail=[PSCustomObject]@{definitionValues=@(for ($i=0;$i -lt $count;$i++) { [PSCustomObject]@{enabled=$true;definition=[PSCustomObject]@{displayName="setting-$i"}} })}
    $path=@(Export-Policies -Policies @($exportItem) -Format JSON -Folder $exportFolder)[0]
    $decoded=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
    Assert-Collection ($decoded.Settings -is [array] -and $decoded.Settings.Count -eq [Math]::Max(1,$count)) "ADMX / $count settings retains a JSON array after export and parse"
}
Write-Output "Collection regression checks passed: $script:collectionChecks"
