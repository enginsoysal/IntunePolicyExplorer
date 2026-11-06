#Requires -Version 5.1
[CmdletBinding()]
param([string]$ResultsDirectory)
$ErrorActionPreference = 'Stop'
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path $PSScriptRoot 'results' }
Set-StrictMode -Version Latest
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this test with powershell.exe -STA or pwsh.exe -STA.' }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Show-IntunePoliciesGUI.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml' }, $true)
$xaml = $assignment.Right.Expression.Value
function Pump-Layout($Window) {
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{})
    $Window.UpdateLayout()
}
function Get-Visuals($Element) {
    $Element
    for ($i=0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element); $i++) {
        Get-Visuals ([Windows.Media.VisualTreeHelper]::GetChild($Element,$i))
    }
}
$results = [Collections.Generic.List[object]]::new()
function Assert-ControlReachable($Window, $Control, $Case) {
    $Control.BringIntoView()
    Pump-Layout $Window
    if (-not $Control.IsVisible -or $Control.ActualWidth -lt 20 -or $Control.ActualHeight -lt 16) {
        throw "$Case : $($Control.Name) is not visible or is collapsed."
    }
    $bounds = $Control.TransformToAncestor($Window).TransformBounds([Windows.Rect]::new(0,0,$Control.ActualWidth,$Control.ActualHeight))
    $allowed = [Windows.Rect]::new(0,0,$Window.ActualWidth,$Window.ActualHeight)
    $parent = [Windows.Media.VisualTreeHelper]::GetParent($Control)
    while ($parent -and $parent -ne $Window) {
        if ($parent -is [Windows.FrameworkElement] -and ($parent.ClipToBounds -or $parent -is [Windows.Controls.ScrollContentPresenter])) {
            $clip = $parent.TransformToAncestor($Window).TransformBounds([Windows.Rect]::new(0,0,$parent.ActualWidth,$parent.ActualHeight))
            $allowed.Intersect($clip)
        }
        $parent = [Windows.Media.VisualTreeHelper]::GetParent($parent)
    }
    $allowed.Inflate(1,1)
    if (-not $allowed.Contains($bounds)) { throw "$Case : $($Control.Name) is clipped. Button $bounds; viewport $allowed" }
    # A visible rectangle alone is insufficient: another element could cover its center.
    $point = [Windows.Point]::new($bounds.X+$bounds.Width/2,$bounds.Y+$bounds.Height/2)
    $hit = $Window.InputHitTest($point)
    while ($hit -and $hit -ne $Control) { $hit = [Windows.Media.VisualTreeHelper]::GetParent($hit) }
    if ($hit -ne $Control) { throw "$Case : $($Control.Name) center is covered or not hit-testable." }
    if ($Control -is [Windows.Controls.Button] -and $Control.Content -is [string]) {
        $label=[Windows.Controls.TextBlock]::new()
        $label.Text=$Control.Content; $label.FontFamily=$Control.FontFamily
        $label.FontSize=$Control.FontSize; $label.FontWeight=$Control.FontWeight
        $label.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
        if ($label.DesiredSize.Width -gt ($Control.ActualWidth-$Control.Padding.Left-$Control.Padding.Right+1) -or
            $label.DesiredSize.Height -gt ($Control.ActualHeight-$Control.Padding.Top-$Control.Padding.Bottom+1)) {
            throw "$Case : $($Control.Name) label is clipped."
        }
    }
    $results.Add([PSCustomObject]@{Case=$Case; Control=$Control.Name; Bounds=$bounds.ToString(); Reachable=$true})
}
# DIP viewports model the space available at each scale without changing the user's display settings.
$screens = @(@(1366,768),@(1920,1080),@(1280,720))
foreach ($screen in $screens) {
    foreach ($scale in @(1.0,1.25,1.5,2.0)) {
        $case = "$($screen[0])x$($screen[1]) at $([int]($scale*100))%"
        $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($xaml))
        $window = [Windows.Markup.XamlReader]::Load($reader)
        $reader.Dispose()
        $window.WindowStartupLocation='Manual'; $window.Left=-20000; $window.Top=-20000
        $window.ShowInTaskbar=$false
        $window.MinWidth=[Math]::Min(640,$screen[0]/$scale)
        $window.MinHeight=[Math]::Min(480,($screen[1]-48)/$scale)
        $window.Width=[Math]::Min(1180,$screen[0]/$scale)
        $window.Height=[Math]::Min(800,($screen[1]-48)/$scale)
        try {
            $window.Show()
            $tabs=$window.FindName('MainTabs')
            for ($tab=0; $tab -lt $tabs.Items.Count; $tab++) {
                $tabs.SelectedIndex=$tab
                Pump-Layout $window
                if ($tab -eq 0) {
                    Assert-ControlReachable $window ($window.FindName('BtnConnect')) "$case / collapsed connection"
                    $window.FindName('ExpAdvanced').IsExpanded=$true
                    $window.FindName('TxtTenantInfo').Text=('Long tenant information and scope names ' * 30)
                    Pump-Layout $window
                }
                if ($tab -eq 3) {
                    $window.FindName('TxtAnalysisSummary').Text='INCOMPLETE analysis: 400 loaded policies; assignments 300/400; settings 350/400; 150 load errors. Recommendations are inventory hints. Potential conflicts: 123 (target overlap not verified). See Policy health for load errors.'
                    Pump-Layout $window
                    $summary=$window.FindName('TxtAnalysisSummary'); $analyze=$window.FindName('BtnAnalyze')
                    $summaryBounds=$summary.TransformToAncestor($window).TransformBounds([Windows.Rect]::new(0,0,$summary.ActualWidth,$summary.ActualHeight))
                    $analyzeBounds=$analyze.TransformToAncestor($window).TransformBounds([Windows.Rect]::new(0,0,$analyze.ActualWidth,$analyze.ActualHeight))
                    if ($summaryBounds.IntersectsWith($analyzeBounds)) { throw "$case : analysis button overlaps summary text" }
                    $inner=$window.FindName('InsightTabs')
                    for ($innerTab=0; $innerTab -lt $inner.Items.Count; $innerTab++) {
                        $inner.SelectedIndex=$innerTab
                        Pump-Layout $window
                        $required = @('BtnAnalyze')
                        if ($innerTab -eq 3) { $required += 'BtnFindSetting' }
                        foreach ($button in @($required | ForEach-Object { $window.FindName($_) })) {
                            $button.IsEnabled=$true
                            Assert-ControlReachable $window $button "$case / Insights $innerTab"
                        }
                    }
                }
                $required = switch ($tab) {
                    0 { @('BtnConnect','BtnConnectAdvanced','BtnDisconnect') }
                    1 { @('BtnRefresh','BtnLoadDetails','TxtSearch','CmbTypeFilter') }
                    2 { @() }
                    3 { @('BtnAnalyze','BtnFindSetting') }
                    4 { @('BtnExport','CmbExportFormat','CmbExportScope') }
                }
                foreach ($button in @($required | ForEach-Object { $window.FindName($_) })) {
                    $button.IsEnabled=$true
                    Assert-ControlReachable $window $button "$case / tab $tab"
                }
                foreach ($gridName in @('DgPolicies','DgSettings','DgRecommendations','DgHealth','DgConflicts','DgFindResults')) {
                    $grid=$window.FindName($gridName)
                    if ($grid.IsVisible -and $grid.ActualHeight -lt 32) { throw "$case : $gridName has no usable viewport" }
                    if ($grid.IsVisible) {
                        foreach ($column in $grid.Columns) {
                            if ($column.ActualWidth+1 -lt $column.MinWidth) { throw "$case : $gridName column $($column.Header) is narrower than its readable minimum" }
                        }
                    }
                }
            }
        } finally { $window.Close() }
        Write-Output "PASS: $case - all tabs and action buttons reachable"
    }
}
# Check the synthetic device-code helper separately; no authentication request is made.
$helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-DeviceCodeDialog'},$true)
. ([scriptblock]::Create($helper.Extent.Text))
$Script:OwnerWindow=$null
$Script:GraphClientId='fixture-client'
foreach ($size in @(@(540,300),@(380,200))) {
    $dialog=Show-DeviceCodeDialog -VerificationUrl 'https://example.invalid/device-login' -UserCode 'FAKE-CODE' -Message 'Offline layout fixture' -ClientId 'fixture-client'
    try {
        $dialog.Left=-20000; $dialog.Top=-20000; $dialog.Width=$size[0]; $dialog.Height=$size[1]
        Pump-Layout $dialog
        foreach ($name in @('BtnCopyUrl','BtnCopyCode','BtnOpen')) { Assert-ControlReachable $dialog ($dialog.FindName($name)) "Device-code helper $($size[0])x$($size[1])" }
    } finally { $dialog.Close() }
}
New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
$results.ToArray() | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ResultsDirectory 'layout.json') -Encoding UTF8
Write-Output "Layout checks passed: $($results.Count)"
