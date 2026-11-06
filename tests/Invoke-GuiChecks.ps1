# Executed inside the actual production GUI function by Start-OfflinePreview.ps1 -RunChecks.
$guiResults = $Script:PreviewResultsDirectory
New-Item -ItemType Directory -Force -Path $guiResults | Out-Null
$script:guiCheckCount = 0
function Assert-Gui($Condition, [string]$Message) {
    if (-not $Condition) { throw "GUI FAIL: $Message" }
    $script:guiCheckCount++
    Write-Output "GUI PASS: $Message"
}
function Pump-Gui {
    $window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [action]{})
    $window.UpdateLayout()
}
function Click-TestButton($Button) {
    Assert-Gui $Button.IsEnabled "$($Button.Name) is enabled"
    $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Pump-Gui
}
function Save-GuiRender([string]$Name) {
    Pump-Gui
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Content.ActualWidth,[int]$window.Content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $background=[Windows.Media.DrawingVisual]::new()
    $drawing=$background.RenderOpen()
    $drawing.DrawRectangle($window.Background,$null,[Windows.Rect]::new(0,0,$window.Content.ActualWidth,$window.Content.ActualHeight))
    $drawing.Close()
    $bitmap.Render($background)
    $bitmap.Render($window.Content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $guiResults "$($window.Width)x$($window.Height)-$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
$window.WindowStartupLocation='Manual'; $window.Left=-20000; $window.Top=-20000; $window.ShowInTaskbar=$false
try {
    $window.Show()
    Pump-Gui
    Assert-Gui (-not $btnDisconnect.IsEnabled -and -not $btnAnalyze.IsEnabled) 'Disconnected actions are disabled'
    Save-GuiRender '01-connection'
    $window.FindName('ExpAdvanced').IsExpanded=$true
    Pump-Gui
    $btnConnectAdvanced.BringIntoView()
    Save-GuiRender '02-advanced-scrolled'
    $window.FindName('ExpAdvanced').IsExpanded=$false
    Click-TestButton $btnConnect
    Assert-Gui ($Script:IsConnected -and $Script:AllPolicies.Count -eq 4) 'Sign-in event loads synthetic policies'
    Assert-Gui ($btnDisconnect.IsEnabled -and $btnRefresh.IsEnabled -and $btnExport.IsEnabled -and $btnAnalyze.IsEnabled) 'Connected actions become enabled'
    Assert-Gui ($Script:CurrentTenant -eq 'OFFLINE-DEMO') 'Sign-in synchronizes the internal tenant without a stateful mock'
    $mainTabs=$window.FindName('MainTabs')
    $mainTabs.SelectedIndex=1
    Click-TestButton $btnRefresh
    Assert-Gui ($Script:AllPolicies.Count -eq 4) 'Refresh event reloads inventory'
    Assert-Gui $btnRefresh.IsEnabled 'Refresh remains enabled after the real completion handler'
    $dgPolicies.SelectedItem=@($Script:AllPolicies | Where-Object Id -eq 'one')[0]
    Pump-Gui
    Assert-Gui ($dgSettings.Items.Count -eq 4) 'Selecting a policy loads all fixture settings'
    Click-TestButton $btnLoadDetails
    Save-GuiRender '03-policies'
    $txtSearch.Text='Pilot'
    Pump-Gui
    Assert-Gui ($dgPolicies.Items.Count -eq 1) 'Policy name filter updates the table'
    $txtSearch.Text=''
    $mainTabs.SelectedIndex=2
    Save-GuiRender '04-settings'
    $mainTabs.SelectedIndex=3
    Click-TestButton $btnAnalyze
    Assert-Gui ($null -ne $Script:AnalysisData -and -not $Script:AnalysisData.IsComplete) 'Analyze event produces incomplete fixture analysis'
    Assert-Gui $btnAnalyze.IsEnabled 'Analyze remains enabled after completion'
    Assert-Gui ($txtAnalysisSummary.Text -match 'INCOMPLETE.*assignments 3/4.*settings 3/4') 'Analysis coverage is displayed in the actual label'
    Assert-Gui ($dgRecommendations.Items.Count -gt 0 -and $dgHealth.Items.Count -gt 0 -and $dgConflicts.Items.Count -gt 0) 'Recommendations, health and potential conflicts are bound to the grids'
    $inner=$window.FindName('InsightTabs')
    foreach ($index in 0..3) {
        $inner.SelectedIndex=$index
        if ($index -eq 3) {
            $txtFindSetting.Text='encryption'
            Click-TestButton $btnFindSetting
            Assert-Gui ($dgFindResults.Items.Count -eq 3) 'Find setting event returns matches from loaded settings'
            $savedIndex=$Script:SettingsIndex
            $Script:SettingsIndex=@($savedIndex | Select-Object -First 1)
            $txtFindSetting.Text=$Script:SettingsIndex[0].Setting
            Click-TestButton $btnFindSetting
            Assert-Gui ($dgFindResults.Items.Count -eq 1) 'Find setting event binds exactly one match'
            $txtFindSetting.Text='no-such-setting-fixture'
            Click-TestButton $btnFindSetting
            Assert-Gui ($dgFindResults.Items.Count -eq 0) 'Find setting event clears the grid for zero matches'
            $Script:SettingsIndex=$savedIndex
            $txtFindSetting.Text='encryption'
            Click-TestButton $btnFindSetting
        }
        Save-GuiRender ("05-insights-$index")
    }
    $mainTabs.SelectedIndex=4
    Save-GuiRender '06-export'
    $btnExport.BringIntoView()
    Save-GuiRender '07-export-scrolled'
    # Export the same fixture data with the real production exporters, without a native folder picker.
    $exportPolicies=@($Script:AllPolicies | Where-Object Id -ne 'four')
    foreach ($format in @('JSON','CSV','HTML')) {
        $paths=@(Export-Policies -Policies $exportPolicies -Format $format -Folder $guiResults)
        Assert-Gui ($paths.Count -gt 0 -and @($paths | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0) "$format export files exist"
        if ($format -eq 'JSON') {
            $roundTrip=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $paths[0] -Raw)
            Assert-Gui ($roundTrip.Count -eq 3 -and $roundTrip[0].Settings.Count -eq 4) 'JSON export round-trips policies and settings'
        }
        if ($format -eq 'CSV') {
            Assert-Gui (@(Import-Csv -LiteralPath $paths[1]).Count -eq 12) 'CSV settings export contains every fixture setting'
        }
    }
    $auditPaths=@(Export-AuditReport -Policies @($Script:AllPolicies) -Analysis $Script:AnalysisData -Folder $guiResults)
    Assert-Gui ((Get-Content -LiteralPath $auditPaths[0] -Raw) -match 'INCOMPLETE') 'Audit exporter retains coverage from GUI analysis'
    $mainTabs.SelectedIndex=0
    Click-TestButton $btnDisconnect
    Assert-Gui (-not $Script:IsConnected -and $Script:AllPolicies.Count -eq 0) 'Disconnect clears policies'
    Assert-Gui ($null -eq $Script:AnalysisData -and $null -eq $dgSettings.ItemsSource -and -not $btnExport.IsEnabled) 'Disconnect clears analysis, settings and enabled actions'
    Write-Output "GUI integration checks passed: $script:guiCheckCount"
} finally { $window.Close() }
