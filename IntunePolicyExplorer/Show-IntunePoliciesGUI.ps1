#Requires -Version 5.1
<#
.SYNOPSIS
    Graphical Intune Policy Explorer - reads policies and settings via Microsoft Graph.

.DESCRIPTION
    Modern WPF interface to browse, search, and export Intune policies.
    Requires: Microsoft.Graph.Authentication module.

.EXAMPLE
    .\Show-IntunePoliciesGUI.ps1
#>

function Show-IntunePoliciesGUI {
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Graph PowerShell built-in public client ID
$Script:GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Valid Graph delegated scopes for session detection (Policy.ReadWrite.All does not exist on Graph)
$Script:GraphApiScopes = @(
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementApps.ReadWrite.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementManagedDevices.ReadWrite.All'
    'Policy.Read.All'
    'Policy.ReadWrite.DeviceConfiguration'
)

# Quick connect: minimal Read scopes for the built-in Graph CLI app
$Script:QuickConnectApiScopes = @(
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'Policy.Read.All'
)
$Script:QuickConnectScopes = $Script:QuickConnectApiScopes + @('offline_access', 'openid', 'profile')

# Typical delegated scopes for a custom Intune app (ReadWrite, no Policy.Read.All)
$Script:DefaultAppRegistrationScopes = @(
    'DeviceManagementConfiguration.ReadWrite.All'
    'DeviceManagementApps.ReadWrite.All'
    'DeviceManagementManagedDevices.ReadWrite.All'
    'Policy.ReadWrite.DeviceConfiguration'
    'DeviceManagementScripts.ReadWrite.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
)

function Resolve-GraphScopes {
    param(
        [string]$CustomScopesText,
        [switch]$UseAppRegistration
    )

    $parsed = if (-not [string]::IsNullOrWhiteSpace($CustomScopesText)) {
        $CustomScopesText -split '[,\r\n;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    elseif ($UseAppRegistration) {
        $Script:DefaultAppRegistrationScopes
    }
    else {
        $Script:QuickConnectApiScopes
    }

    foreach ($oauth in @('offline_access', 'openid', 'profile')) {
        if ($oauth -notin $parsed) { $parsed += $oauth }
    }
    return @($parsed | Select-Object -Unique)
}

function Test-HasIntuneGraphSession {
    param($Context)
    if (-not $Context) { return $false }
    return (@($Context.Scopes | Where-Object { $_ -match '^(DeviceManagement|Policy\.)' }).Count -gt 0)
}

function Test-MgCommandSupportsContextScope {
    param([string]$CommandName)
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    return ($cmd -and $cmd.Parameters.ContainsKey('ContextScope'))
}

function Get-MgGraphSession {
    if (Test-MgCommandSupportsContextScope -CommandName 'Get-MgContext') {
        try {
            $ctx = Get-MgContext -ContextScope CurrentUser -ErrorAction Stop
            if ($ctx) { return $ctx }
        }
        catch { }
    }
    return Get-MgContext -ErrorAction SilentlyContinue
}

function Invoke-ConnectMgGraph {
    param(
        [string]$ClientId,
        [string]$TenantId,
        [string[]]$Scopes
    )

    $params = @{
        Scopes      = $Scopes
        NoWelcome   = $true
        ErrorAction = 'Stop'
    }
    if ($ClientId) { $params.ClientId = $ClientId }
    if ($TenantId) { $params.TenantId = $TenantId }
    if (Test-MgCommandSupportsContextScope -CommandName 'Connect-MgGraph') {
        $params.ContextScope = 'CurrentUser'
    }
    Connect-MgGraph @params
    return Get-MgGraphSession
}

$Script:PolicySources = [ordered]@{
    'Configuration Profiles'     = @{ Endpoint = 'deviceManagement/deviceConfigurations';              DetailExpand = $null }
    'Settings Catalog'           = @{ Endpoint = 'deviceManagement/configurationPolicies';            DetailExpand = 'settings' }
    'Compliance'                 = @{ Endpoint = 'deviceManagement/deviceCompliancePolicies';          DetailExpand = $null }
    'Administrative Templates'   = @{ Endpoint = 'deviceManagement/groupPolicyConfigurations';          DetailExpand = 'definitionValues($expand=definition)' }
    'Endpoint Security'          = @{ Endpoint = 'deviceManagement/intents';                            DetailExpand = 'settings' }
    'Windows Autopilot'          = @{ Endpoint = 'deviceManagement/windowsAutopilotDeploymentProfiles';  DetailExpand = $null }
    'App Protection (iOS)'       = @{ Endpoint = 'deviceAppManagement/iosManagedAppProtections';        DetailExpand = $null }
    'App Protection (Android)'   = @{ Endpoint = 'deviceAppManagement/androidManagedAppProtections';    DetailExpand = $null }
    'App Protection (Windows)'   = @{ Endpoint = 'deviceAppManagement/windowsManagedAppProtections';  DetailExpand = $null }
    'Mobile App Configurations'  = @{ Endpoint = 'deviceAppManagement/mobileAppConfigurations';        DetailExpand = $null }
}

$Script:AllPolicies   = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$Script:IsConnected   = $false
$Script:CurrentTenant = $null
$Script:OwnerWindow   = $null

function Test-GraphModule {
    return (@(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication).Count -gt 0)
}

function Install-GraphModuleIfNeeded {
    if (-not (Test-GraphModule)) {
        $answer = [System.Windows.MessageBox]::Show(
            "Microsoft Graph Authentication is required for sign-in.`n`nInstall it now (CurrentUser)?",
            'Module required',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
        try {
            Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
        }
        catch {
            [System.Windows.MessageBox]::Show("Installation failed: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
            return $false
        }
    }
    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        if (-not (Test-MgCommandSupportsContextScope -CommandName 'Connect-MgGraph')) {
            Update-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -ErrorAction Stop
            Import-Module Microsoft.Graph.Authentication -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Warning 'Could not update Microsoft.Graph.Authentication. Sign-in may use device code fallback.'
    }
    return $true
}

function Show-DeviceCodeDialog {
    param(
        [string]$VerificationUrl,
        [string]$UserCode,
        [string]$Message,
        [string]$ClientId
    )

    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sign in to Microsoft Graph" Height="220" Width="540"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#F0F4F8" FontFamily="Segoe UI" ShowInTaskbar="False">
  <Border Background="White" Margin="12" CornerRadius="8" BorderBrush="#D1D9E0" BorderThickness="1" Padding="14">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Device code sign-in" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBlock Grid.Row="1" x:Name="TxtClientLabel" Foreground="#64748B" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,2"/>
      <TextBlock Grid.Row="2" x:Name="TxtCaWarning" Visibility="Collapsed" Foreground="#9A3412" TextWrapping="Wrap"
                 FontSize="10" Margin="0,0,0,6" Text="Device code blocked? Expand Advanced options on the Connection tab and use your own Entra app."/>

      <Grid Grid.Row="3" Margin="0,4,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="10"/>
          <ColumnDefinition Width="160"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="URL" FontWeight="SemiBold" FontSize="11" Margin="0,0,0,2"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtUrl" IsReadOnly="True" Height="26" FontSize="11" Padding="5,3" VerticalContentAlignment="Center"/>
            <Button x:Name="BtnCopyUrl" Grid.Column="1" Content="Copy" Width="52" Height="26" Margin="4,0,0,0"
                    Background="#E8EEF4" Foreground="#1E293B" BorderThickness="0" FontSize="11" Cursor="Hand"/>
          </Grid>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="Code" FontWeight="SemiBold" FontSize="11" Margin="0,0,0,2"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtCode" IsReadOnly="True" Height="26" FontSize="14" FontWeight="Bold"
                     Padding="5,3" VerticalContentAlignment="Center"/>
            <Button x:Name="BtnCopyCode" Grid.Column="1" Content="Copy" Width="52" Height="26" Margin="4,0,0,0"
                    Background="#E8EEF4" Foreground="#1E293B" BorderThickness="0" FontSize="11" Cursor="Hand"/>
          </Grid>
        </StackPanel>
      </Grid>

      <StackPanel Grid.Row="4" Orientation="Horizontal">
        <Button x:Name="BtnOpen" Content="Open browser" Width="110" Height="28"
                Background="#0078D4" Foreground="White" BorderThickness="0" FontSize="11" Cursor="Hand" Margin="0,0,12,0"/>
        <TextBlock x:Name="TxtStatus" Text="Waiting for sign-in..." Foreground="#0078D4" FontWeight="SemiBold"
                   FontSize="11" VerticalAlignment="Center"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $Script:OwnerWindow

    $dialog.FindName('TxtClientLabel').Text = "Client ID: $ClientId"
    $dialog.FindName('TxtUrl').Text         = $VerificationUrl
    $dialog.FindName('TxtCode').Text        = $UserCode

    if ($ClientId -eq $Script:GraphClientId) {
        $dialog.FindName('TxtCaWarning').Visibility = 'Visible'
    }

    $dialog.FindName('BtnOpen').Add_Click({
        Start-Process $VerificationUrl
    })
    $dialog.FindName('BtnCopyUrl').Add_Click({
        [System.Windows.Clipboard]::SetText($VerificationUrl)
        $dialog.FindName('TxtStatus').Text = 'URL copied to clipboard.'
    })
    $dialog.FindName('BtnCopyCode').Add_Click({
        [System.Windows.Clipboard]::SetText($UserCode)
        $dialog.FindName('TxtStatus').Text = 'Code copied to clipboard.'
    })

    [void]$dialog.Show()
    return $dialog
}

function Invoke-UiPump {
    if ($Script:OwnerWindow) {
        try {
            [void]$Script:OwnerWindow.Dispatcher.Invoke(
                [action]{},
                [System.Windows.Threading.DispatcherPriority]::Background)
        }
        catch { }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-ProcessWithUiPump {
    param([System.Diagnostics.Process]$Process)
    while (-not $Process.HasExited) {
        Invoke-UiPump
        Start-Sleep -Milliseconds 150
    }
}

function Invoke-OnUiThread {
    param([scriptblock]$Action)
    if ($window.Dispatcher.CheckAccess()) {
        & $Action
    }
    else {
        $window.Dispatcher.Invoke($Action)
    }
}

function Close-DeviceCodeDialog {
    param($Dialog)
    if (-not $Dialog) { return }
    try {
        if ($Dialog.Dispatcher) {
            if ($Dialog.Dispatcher.CheckAccess()) { $Dialog.Close() }
            else { $Dialog.Dispatcher.Invoke([action]{ $Dialog.Close() }) }
        }
        else { $Dialog.Close() }
    }
    catch { }
}

function Get-AccessTokenViaDeviceCode {
    param(
        [System.Windows.Window]$OwnerWindow,
        [string]$TenantId,
        [string]$ClientId,
        [string[]]$Scopes = $Script:QuickConnectScopes
    )

    $clientId    = if ([string]::IsNullOrWhiteSpace($ClientId)) { $Script:GraphClientId } else { $ClientId.Trim() }
    $authority   = if ([string]::IsNullOrWhiteSpace($TenantId)) { 'organizations' } else { $TenantId.Trim() }
    $scopeString = ($Scopes -join ' ')
    $deviceBody  = "client_id=$([uri]::EscapeDataString($clientId))&scope=$([uri]::EscapeDataString($scopeString))"
    $deviceUri   = "https://login.microsoftonline.com/$authority/oauth2/v2.0/devicecode"
    $deviceResult = Invoke-RestMethod -Method POST -Uri $deviceUri -Body $deviceBody -ContentType 'application/x-www-form-urlencoded'

    $dialog = Show-DeviceCodeDialog -VerificationUrl $deviceResult.verification_uri `
        -UserCode $deviceResult.user_code -Message $deviceResult.message -ClientId $clientId

    $tokenUri  = "https://login.microsoftonline.com/$authority/oauth2/v2.0/token"
    $wait      = [math]::Max(5, [int]$deviceResult.interval)
    $expires   = (Get-Date).AddSeconds([int]$deviceResult.expires_in)
    $tokenBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$([uri]::EscapeDataString($clientId))&device_code=$([uri]::EscapeDataString($deviceResult.device_code))"
    $nextPoll  = (Get-Date).AddSeconds($wait)

    try {
        while ((Get-Date) -lt $expires) {
            Invoke-UiPump

            if ((Get-Date) -lt $nextPoll) {
                Start-Sleep -Milliseconds 250
                continue
            }
            $nextPoll = (Get-Date).AddSeconds($wait)

            try {
                $tokenResult = Invoke-RestMethod -Method POST -Uri $tokenUri -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
                Close-DeviceCodeDialog -Dialog $dialog
                return $tokenResult
            }
            catch {
                $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($err.error -eq 'authorization_pending') {
                    if ($dialog.Dispatcher) {
                        $dialog.Dispatcher.Invoke([action]{ $dialog.FindName('TxtStatus').Text = 'Waiting for sign-in...' })
                    }
                    continue
                }
                if ($err.error -eq 'slow_down') {
                    $wait += 5
                    $nextPoll = (Get-Date).AddSeconds($wait)
                    continue
                }
                if ($err.error -in @('access_denied', 'interaction_required', 'invalid_grant')) {
                    throw [System.InvalidOperationException]::new(
                        "Sign-in blocked (Conditional Access / error $($err.error)).`n`n" +
                        "Try App registration with your own Entra app, or sign in with an account that meets your tenant policies.")
                }
                throw
            }
        }
        throw [System.InvalidOperationException]::new(
            "Device code sign-in timed out.`n`n" +
            "Complete sign-in in the browser before the code expires, or try App registration with your own Entra app.")
    }
    finally {
        Close-DeviceCodeDialog -Dialog $dialog
    }
}

function Invoke-MgGraphBrowserHost {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string[]]$Scopes
    )

    if (-not (Test-MgCommandSupportsContextScope -CommandName 'Connect-MgGraph')) {
        throw [System.InvalidOperationException]::new(
            'Sign-in window requires Microsoft.Graph.Authentication 2.16 or newer.`n`n' +
            'Run: Update-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force')
    }

    $scopeArray = ($Scopes | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '
    $connectArgs = @("-Scopes @($scopeArray)", '-NoWelcome', '-ContextScope CurrentUser')
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
        $connectArgs = @("-ClientId '$($ClientId.Trim().Replace("'", "''"))'") + $connectArgs
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectArgs = @("-TenantId '$($TenantId.Trim().Replace("'", "''"))'") + $connectArgs
    }

    $connectScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
Set-MgGraphOption -EnableLoginByWAM `$false | Out-Null
Connect-MgGraph $($connectArgs -join ' ')
"@

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($connectScript))
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -STA -EncodedCommand $encoded" `
        -PassThru -WindowStyle Normal
    Wait-ProcessWithUiPump -Process $proc

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context = Get-MgGraphSession
    if (-not $context) {
        throw [System.InvalidOperationException]::new(
            'Sign-in did not complete. Finish sign-in in the browser, approve permissions, and try again.')
    }
    if ($proc.ExitCode -and $proc.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new('Sign-in was cancelled or failed.')
    }
    return $context
}

function Connect-ToGraphUniversal {
    param(
        [System.Windows.Window]$OwnerWindow,
        [string]$TenantId,
        [string]$ClientId,
        [string[]]$Scopes = $Script:QuickConnectScopes
    )

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    try { Set-MgGraphOption -EnableLoginByWAM $false -ErrorAction SilentlyContinue | Out-Null } catch {}

    $tenantId = if ($TenantId) { $TenantId.Trim() } else { $null }
    $clientId = if ($ClientId) { $ClientId.Trim() } else { $null }
    $hasCustomApp = (-not [string]::IsNullOrWhiteSpace($tenantId)) -and (-not [string]::IsNullOrWhiteSpace($clientId))

    $context = Get-MgGraphSession
    if ($context) {
        $needsReconnect = $false
        if ($tenantId -and $context.TenantId -ne $tenantId) { $needsReconnect = $true }
        if ($clientId -and $context.ClientId -ne $clientId) { $needsReconnect = $true }
        if ($needsReconnect) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $context = $null
        }
    }

    if ($context) {
        $Script:IsConnected   = $true
        $Script:CurrentTenant = $context.TenantId
        return $context
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        if ($hasCustomApp) {
            return Invoke-ConnectMgGraph -ClientId $clientId -TenantId $tenantId -Scopes $Scopes
        }
        return Invoke-ConnectMgGraph -Scopes $Scopes
    }
    catch {
        $errors.Add("In-app browser: $($_.Exception.Message)")
    }

    try {
        [void][System.Windows.MessageBox]::Show(
            "A short-lived PowerShell window will open for Microsoft sign-in.`n`n" +
            'Sign in with your work account in the browser, approve read permissions, then return here.',
            'Sign in with Microsoft', 'OK', 'Information')
        $ctx = Invoke-MgGraphBrowserHost -TenantId $tenantId -ClientId $clientId -Scopes $Scopes
        $Script:IsConnected   = $true
        $Script:CurrentTenant = $ctx.TenantId
        return $ctx
    }
    catch {
        $errors.Add("Sign-in window: $($_.Exception.Message)")
    }

    try {
        $tokenResult = Get-AccessTokenViaDeviceCode -OwnerWindow $OwnerWindow -TenantId $tenantId -ClientId $clientId -Scopes $Scopes
        Connect-MgGraph -AccessToken $tokenResult.access_token -NoWelcome -ErrorAction Stop
        $ctx = Get-MgGraphSession
        if ($ctx) {
            $Script:IsConnected   = $true
            $Script:CurrentTenant = $ctx.TenantId
            return $ctx
        }
    }
    catch {
        $errors.Add("Device code: $($_.Exception.Message)")
    }

    $hint = if ($hasCustomApp) {
        'Verify Tenant ID, Client ID, and scopes on your Entra app registration.'
    }
    else {
        'If your organization blocks device code (Conditional Access), open Advanced options and connect with your own Entra app.'
    }

    throw [System.InvalidOperationException]::new(
        "Could not sign in to Microsoft Graph.`n`n$($errors -join "`n`n")`n`n$hint")
}

function Invoke-GraphPaged {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next    = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($page.value) { $results.AddRange(@($page.value)) }
        else             { $results.Add($page); break }
        $next = $page.'@odata.nextLink'
    }
    return $results
}

function Get-PolicyListItem {
    param($Policy, [string]$Type, [hashtable]$Source)
    [PSCustomObject]@{
        Type         = $Type
        Name         = if ($Policy.displayName) { $Policy.displayName } else { $Policy.name }
        Id           = $Policy.id
        Created      = $Policy.createdDateTime
        Modified     = $Policy.lastModifiedDateTime
        Description  = $Policy.description
        Platform     = if ($Policy.'@odata.type') { ($Policy.'@odata.type' -replace '#microsoft.graph.', '') } else { '' }
        Endpoint     = $Source.Endpoint
        DetailExpand = $Source.DetailExpand
        Raw          = $Policy
    }
}

function Get-AllIntunePolicies {
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Script:PolicySources.GetEnumerator()) {
        $type   = $entry.Key
        $source = $entry.Value
        try {
            $uri  = "https://graph.microsoft.com/beta/$($source.Endpoint)?`$top=999"
            $list = Invoke-GraphPaged -Uri $uri
            foreach ($p in $list) {
                $items.Add((Get-PolicyListItem -Policy $p -Type $type -Source $source))
            }
        }
        catch {
            Write-Warning "Could not load '$type': $($_.Exception.Message)"
        }
    }
    return $items
}

function Get-PolicyDetail {
    param($Item)
    $expand = $Item.DetailExpand
    $uri    = "https://graph.microsoft.com/beta/$($Item.Endpoint)/$($Item.Id)"
    if ($expand) { $uri += "?`$expand=$expand" }
    return Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
}

function Convert-PolicyToSettingsList {
    param($Detail, [string]$Type)

    $rows = [System.Collections.Generic.List[object]]::new()

    function Add-Row([string]$Category, [string]$Setting, $Value) {
        $display = if ($null -eq $Value) { '' }
                   elseif ($Value -is [string] -or $Value -is [ValueType]) { [string]$Value }
                   else { ($Value | ConvertTo-Json -Depth 8 -Compress) }
        $rows.Add([PSCustomObject]@{ Category = $Category; Setting = $Setting; Value = $display })
    }

    switch -Regex ($Type) {
        'Settings Catalog' {
            foreach ($s in @($Detail.settings)) {
                Add-Row 'Settings Catalog' $s.settingInstance.settingDefinitionId $s.settingInstance
            }
        }
        'Administrative Templates' {
            foreach ($dv in @($Detail.definitionValues)) {
                $name = if ($dv.definition) { $dv.definition.displayName } else { $dv.definitionId }
                Add-Row 'ADMX' $name $dv
            }
        }
        'Endpoint Security' {
            foreach ($s in @($Detail.settings)) {
                Add-Row 'Endpoint Security' $s.definitionId $s.valueJson
            }
        }
        default {
            $props = $Detail.PSObject.Properties |
                Where-Object { $_.Name -notmatch '^(id|@odata|roleScopeTags|supportsScopeTags|deviceManagementApplicabilityRule|assignments)$' }
            foreach ($p in $props) {
                if ($p.Name -in @('displayName','description','createdDateTime','lastModifiedDateTime','version')) { continue }
                Add-Row 'General' $p.Name $p.Value
            }
        }
    }

    if ($rows.Count -eq 0) {
        Add-Row 'Info' 'Full object' $Detail
    }
    return $rows
}

function Export-Policies {
    param(
        [array]$Policies,
        [string]$Format,
        [string]$Folder
    )
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $exported  = @()

    switch ($Format) {
        'JSON' {
            $path = Join-Path $Folder "IntunePolicies_$timestamp.json"
            $exportData = foreach ($p in $Policies) {
                $detail = Get-PolicyDetail -Item $p
                [PSCustomObject]@{
                    Type        = $p.Type
                    Name        = $p.Name
                    Id          = $p.Id
                    Description = $p.Description
                    Settings    = Convert-PolicyToSettingsList -Detail $detail -Type $p.Type
                    Raw         = $detail
                }
            }
            $exportData | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding UTF8
            $exported += $path
        }
        'CSV' {
            $path = Join-Path $Folder "IntunePolicies_$timestamp.csv"
            $Policies | Select-Object Type, Name, Id, Platform, Created, Modified, Description |
                Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
            $exported += $path

            $settingsPath = Join-Path $Folder "IntunePolicies_Settings_$timestamp.csv"
            $allSettings  = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $Policies) {
                $detail = Get-PolicyDetail -Item $p
                foreach ($s in (Convert-PolicyToSettingsList -Detail $detail -Type $p.Type)) {
                    $allSettings.Add([PSCustomObject]@{
                        PolicyType = $p.Type; PolicyName = $p.Name; PolicyId = $p.Id
                        Category   = $s.Category; Setting = $s.Setting; Value = $s.Value
                    })
                }
            }
            $allSettings | Export-Csv -Path $settingsPath -NoTypeInformation -Encoding UTF8
            $exported += $settingsPath
        }
        'HTML' {
            $path = Join-Path $Folder "IntunePolicies_$timestamp.html"
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine(@'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Intune Policies Export</title>
<style>
body{font-family:Segoe UI,sans-serif;margin:2rem;background:#f5f7fa;color:#1a1a2e}
h1{color:#0078d4}h2{color:#2d3748;border-bottom:2px solid #0078d4;padding-bottom:.3rem}
table{border-collapse:collapse;width:100%;margin:1rem 0;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.08)}
th{background:#0078d4;color:#fff;text-align:left;padding:.6rem .8rem}
td{padding:.5rem .8rem;border-bottom:1px solid #e2e8f0;vertical-align:top;word-break:break-word}
tr:hover td{background:#edf2f7}.meta{color:#64748b;font-size:.9rem}
.badge{display:inline-block;background:#e0f2fe;color:#0369a1;padding:.15rem .5rem;border-radius:4px;font-size:.8rem}
</style></head><body>
'@)
            [void]$sb.AppendLine('<h1>Intune Policies Export</h1>')
            [void]$sb.AppendLine("<p class='meta'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>")

            foreach ($p in $Policies) {
                [void]$sb.AppendLine("<h2>$([System.Web.HttpUtility]::HtmlEncode($p.Name)) <span class='badge'>$([System.Web.HttpUtility]::HtmlEncode($p.Type))</span></h2>")
                [void]$sb.AppendLine("<p class='meta'>ID: $($p.Id)</p>")
                if ($p.Description) {
                    [void]$sb.AppendLine("<p>$([System.Web.HttpUtility]::HtmlEncode($p.Description))</p>")
                }
                $detail   = Get-PolicyDetail -Item $p
                $settings = Convert-PolicyToSettingsList -Detail $detail -Type $p.Type
                [void]$sb.AppendLine('<table><tr><th>Category</th><th>Setting</th><th>Value</th></tr>')
                foreach ($s in $settings) {
                    [void]$sb.AppendLine("<tr><td>$([System.Web.HttpUtility]::HtmlEncode($s.Category))</td><td>$([System.Web.HttpUtility]::HtmlEncode($s.Setting))</td><td><pre style='margin:0;white-space:pre-wrap'>$([System.Web.HttpUtility]::HtmlEncode($s.Value))</pre></td></tr>")
                }
                [void]$sb.AppendLine('</table>')
            }
            [void]$sb.AppendLine('</body></html>')
            $sb.ToString() | Set-Content -Path $path -Encoding UTF8
            $exported += $path
        }
    }
    return $exported
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Intune Policy Explorer" Height="880" Width="1180" MinHeight="720" MinWidth="900"
        WindowStartupLocation="CenterScreen" Background="#F0F4F8" FontFamily="Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Primary" Color="#0078D4"/>
    <SolidColorBrush x:Key="PrimaryDark" Color="#005A9E"/>
    <SolidColorBrush x:Key="Surface" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Border" Color="#D1D9E0"/>
    <SolidColorBrush x:Key="TextMuted" Color="#64748B"/>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Primary}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{StaticResource PrimaryDark}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#E8EEF4"/>
      <Setter Property="Foreground" Value="#1E293B"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#D1D9E6"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,12"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder" Background="Transparent" BorderThickness="0,0,0,3" BorderBrush="Transparent" Padding="{TemplateBinding Padding}" CornerRadius="6,6,0,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="{StaticResource Primary}"/>
                <Setter Property="Foreground" Value="{StaticResource Primary}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#E8EEF4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="AlternatingRowBackground" Value="#F8FAFC"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#E8EEF4"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
  </Window.Resources>

  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{StaticResource Primary}" Padding="24,18">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="Intune Policy Explorer" FontSize="22" FontWeight="SemiBold" Foreground="White"/>
          <TextBlock x:Name="TxtSubtitle" Text="Connect to Microsoft Graph to load policies" FontSize="13" Foreground="#B3D9F8" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#FCA5A5" Margin="0,0,8,0"/>
          <TextBlock x:Name="TxtConnectionStatus" Text="Not connected" Foreground="White" FontSize="13" VerticalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>

    <TabControl Grid.Row="1" Margin="20,16,20,8">
      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M10.59,13.41C11,13.8 11,14.44 10.59,14.83C10.2,15.22 9.56,15.22 9.17,14.83L7.05,12.71C5.68,11.34 5.68,9.16 7.05,7.79C8.42,6.42 10.6,6.42 11.97,7.79L13.07,8.89M13.41,10.59C13.8,11 14.44,11 14.83,10.59C15.22,10.2 15.22,9.56 14.83,9.17L12.71,7.05C11.34,5.68 9.16,5.68 7.79,7.05C6.42,8.42 6.42,10.6 7.79,11.97L8.89,13.07" Fill="{Binding RelativeSource={RelativeSource AncestorType=TabItem}, Path=Foreground}" Width="14" Height="14" Stretch="Uniform" Margin="0,0,8,0"/>
            <TextBlock Text="Connection" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Border Background="{StaticResource Surface}" CornerRadius="10" Padding="20" Margin="0,8,0,0"
                BorderBrush="{StaticResource Border}" BorderThickness="1">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Sign in" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <TextBlock Grid.Row="1" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,0,0,14" LineHeight="20"
                       Text="Browse and export Intune policies with read-only access. No app registration required - use your work account. You need Intune read permissions (admin consent may apply on first sign-in)."/>

            <Border Grid.Row="2" Background="#F8FAFC" BorderBrush="{StaticResource Border}" BorderThickness="1"
                    CornerRadius="8" Padding="20" Margin="0,0,0,14">
              <StackPanel>
                <Button x:Name="BtnConnect" Content="Sign in with Microsoft" Height="40" FontSize="14"
                        HorizontalAlignment="Left" MinWidth="240" Margin="0,0,0,12"/>
                <TextBlock Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" FontSize="11" LineHeight="15" Margin="0,0,0,8"
                           Text="Uses the built-in Microsoft Graph sign-in. Works for most tenants with minimal setup."/>
                <Expander x:Name="ExpAdvanced" Header="Advanced options (optional)" IsExpanded="False">
                  <StackPanel Margin="0,10,0,0">
                    <TextBlock Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" FontSize="11" LineHeight="15" Margin="0,0,0,10"
                               Text="Only if default sign-in is blocked by Conditional Access. Use your own Entra app registration - not required for most users."/>
                    <TextBlock Text="Tenant ID" FontWeight="SemiBold" FontSize="12" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtTenantId" Margin="0,0,0,8" FontSize="12"/>
                    <TextBlock Text="Client ID" FontWeight="SemiBold" FontSize="12" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtClientId" Margin="0,0,0,8" FontSize="12"/>
                    <TextBlock Text="Scopes (optional, one per line)" FontWeight="SemiBold" FontSize="12" Margin="0,0,0,3"/>
                    <TextBox x:Name="TxtScopes" Height="72" FontSize="11" TextWrapping="Wrap" AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto" Margin="0,0,0,10"/>
                    <Button x:Name="BtnConnectAdvanced" Content="Connect with app registration"
                            HorizontalAlignment="Left" MinWidth="240"/>
                  </StackPanel>
                </Expander>
              </StackPanel>
            </Border>

            <StackPanel Grid.Row="3" Margin="0,0,0,4">
              <Button x:Name="BtnDisconnect" Content="Disconnect" Style="{StaticResource SecondaryButton}"
                      Width="140" HorizontalAlignment="Left" IsEnabled="False" Margin="0,0,0,10"/>
              <Border Background="#F0F9FF" BorderBrush="#BAE6FD" BorderThickness="1" CornerRadius="8" Padding="14" MinHeight="72">
                <StackPanel>
                  <TextBlock Text="Tenant information" FontWeight="SemiBold" Margin="0,0,0,6"/>
                  <TextBlock x:Name="TxtTenantInfo" Text="Not connected yet." Foreground="{StaticResource TextMuted}"
                             TextWrapping="Wrap" LineHeight="18"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </Border>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M3,3H21V5H3V3M3,7H15V9H3V7M3,11H21V13H3V11M3,15H15V17H3V15M3,19H21V21H3V19Z" Fill="{Binding RelativeSource={RelativeSource AncestorType=TabItem}, Path=Foreground}" Width="14" Height="14" Stretch="Uniform" Margin="0,0,8,0"/>
            <TextBlock Text="Policies" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Background="{StaticResource Surface}" CornerRadius="10" Padding="16" BorderBrush="{StaticResource Border}" BorderThickness="1" Margin="0,0,0,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="200"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="TxtSearch" Grid.Column="0" Margin="0,0,10,0"/>
              <ComboBox x:Name="CmbTypeFilter" Grid.Column="1" Margin="0,0,10,0"/>
              <Button x:Name="BtnRefresh" Grid.Column="2" Content="Refresh" Margin="0,0,8,0" IsEnabled="False"/>
              <Button x:Name="BtnLoadDetails" Grid.Column="3" Content="Load details" Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
            </Grid>
          </Border>
          <Border Grid.Row="1" Background="{StaticResource Surface}" CornerRadius="10" BorderBrush="{StaticResource Border}" BorderThickness="1">
            <DataGrid x:Name="DgPolicies" IsReadOnly="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="180"/>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*" MinWidth="200"/>
                <DataGridTextColumn Header="Platform" Binding="{Binding Platform}" Width="160"/>
                <DataGridTextColumn Header="Last modified" Binding="{Binding Modified}" Width="150"/>
              </DataGrid.Columns>
            </DataGrid>
          </Border>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M12,15.5A3.5,3.5 0 0,1 8.5,12A3.5,3.5 0 0,1 12,8.5A3.5,3.5 0 0,1 15.5,12A3.5,3.5 0 0,1 12,15.5M19.43,12.97C19.47,12.65 19.5,12.33 19.5,12C19.5,11.67 19.47,11.35 19.43,11.03L21.54,9.37C21.73,9.22 21.78,8.95 21.66,8.73L19.66,5.27C19.54,5.05 19.27,4.96 19.05,5.05L16.56,6.05C16.04,5.65 15.48,5.32 14.87,5.07L14.49,2.42C14.46,2.18 14.25,2 14,2H10C9.75,2 9.54,2.18 9.51,2.42L9.13,5.07C8.52,5.32 7.96,5.66 7.44,6.05L4.95,5.05C4.72,4.96 4.46,5.05 4.34,5.27L2.34,8.73C2.21,8.95 2.27,9.22 2.46,9.37L4.57,11.03C4.53,11.35 4.5,11.67 4.5,12C4.5,12.33 4.53,12.65 4.57,12.97L2.46,14.63C2.27,14.78 2.21,15.05 2.34,15.27L4.34,18.73C4.46,18.95 4.72,19.03 4.95,18.95L7.44,17.94C7.96,18.34 8.52,18.68 9.13,18.93L9.51,21.58C9.54,21.82 9.75,22 10,22H14C14.25,22 14.46,21.82 14.49,21.58L14.87,18.93C15.48,18.68 16.04,18.34 16.56,17.94L19.05,18.95C19.27,19.03 19.54,18.95 19.66,18.73L21.66,15.27C21.78,15.05 21.73,14.78 21.54,14.63L19.43,12.97Z" Fill="{Binding RelativeSource={RelativeSource AncestorType=TabItem}, Path=Foreground}" Width="14" Height="14" Stretch="Uniform" Margin="0,0,8,0"/>
            <TextBlock Text="Settings" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Background="{StaticResource Surface}" CornerRadius="10" Padding="16" BorderBrush="{StaticResource Border}" BorderThickness="1" Margin="0,0,0,10">
            <StackPanel>
              <TextBlock x:Name="TxtSelectedPolicy" Text="Select a policy on the Policies tab" FontSize="15" FontWeight="SemiBold"/>
              <TextBlock x:Name="TxtSelectedMeta" Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
            </StackPanel>
          </Border>
          <Border Grid.Row="1" Background="{StaticResource Surface}" CornerRadius="10" BorderBrush="{StaticResource Border}" BorderThickness="1">
            <DataGrid x:Name="DgSettings" IsReadOnly="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="160"/>
                <DataGridTextColumn Header="Setting" Binding="{Binding Setting}" Width="*" MinWidth="220"/>
                <DataGridTextColumn Header="Value" Binding="{Binding Value}" Width="2*" MinWidth="280"/>
              </DataGrid.Columns>
            </DataGrid>
          </Border>
        </Grid>
      </TabItem>

      <TabItem>
        <TabItem.Header>
          <StackPanel Orientation="Horizontal">
            <Path Data="M14,2H6A2,2 0 0,0 4,4V20A2,2 0 0,0 6,22H18A2,2 0 0,0 20,20V8L14,2M18,20H6V4H13V9H18V20Z" Fill="{Binding RelativeSource={RelativeSource AncestorType=TabItem}, Path=Foreground}" Width="14" Height="14" Stretch="Uniform" Margin="0,0,8,0"/>
            <TextBlock Text="Export" VerticalAlignment="Center"/>
          </StackPanel>
        </TabItem.Header>
        <Border Background="{StaticResource Surface}" CornerRadius="10" Padding="28" Margin="0,8,0,0"
                BorderBrush="{StaticResource Border}" BorderThickness="1">
          <StackPanel MaxWidth="640" HorizontalAlignment="Left">
            <TextBlock Text="Export policies" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <TextBlock Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,0,0,20"
                       Text="Export selected policies or the full overview including settings."/>
            <TextBlock Text="Format" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <ComboBox x:Name="CmbExportFormat" Width="280" HorizontalAlignment="Left" Margin="0,0,0,16">
              <ComboBoxItem Content="JSON (full, including raw data)" IsSelected="True"/>
              <ComboBoxItem Content="CSV (overview + separate settings file)"/>
              <ComboBoxItem Content="HTML (readable report)"/>
            </ComboBox>
            <TextBlock Text="Scope" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <ComboBox x:Name="CmbExportScope" Width="280" HorizontalAlignment="Left" Margin="0,0,0,20">
              <ComboBoxItem Content="Selected policies only" IsSelected="True"/>
              <ComboBoxItem Content="All loaded policies"/>
            </ComboBox>
            <Button x:Name="BtnExport" Content="Export..." Width="200" HorizontalAlignment="Left" IsEnabled="False"/>
            <TextBlock x:Name="TxtExportResult" Foreground="{StaticResource TextMuted}" Margin="0,16,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </TabItem>
    </TabControl>

    <Border Grid.Row="2" Background="#E8EEF4" Padding="20,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatus" Text="Ready." VerticalAlignment="Center" Foreground="#475569"/>
        <TextBlock x:Name="TxtPolicyCount" Grid.Column="1" Text="0 policies" VerticalAlignment="Center" Foreground="#475569"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Web, System.Windows.Forms

if (-not (Install-GraphModuleIfNeeded)) {
    Write-Error 'Microsoft.Graph.Authentication is required. Exiting.'
    exit 1
}

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [Windows.Markup.XamlReader]::Load($reader)
$Script:OwnerWindow = $window

$btnConnect         = $window.FindName('BtnConnect')
$btnConnectAdvanced = $window.FindName('BtnConnectAdvanced')
$btnDisconnect      = $window.FindName('BtnDisconnect')
$btnRefresh         = $window.FindName('BtnRefresh')
$btnLoadDetails     = $window.FindName('BtnLoadDetails')
$btnExport          = $window.FindName('BtnExport')
$txtSubtitle        = $window.FindName('TxtSubtitle')
$txtConnectionStatus= $window.FindName('TxtConnectionStatus')
$txtTenantInfo      = $window.FindName('TxtTenantInfo')
$txtTenantId        = $window.FindName('TxtTenantId')
$txtClientId        = $window.FindName('TxtClientId')
$txtScopes          = $window.FindName('TxtScopes')
$statusDot          = $window.FindName('StatusDot')
$txtSearch          = $window.FindName('TxtSearch')
$cmbTypeFilter      = $window.FindName('CmbTypeFilter')
$dgPolicies         = $window.FindName('DgPolicies')
$dgSettings         = $window.FindName('DgSettings')
$txtSelectedPolicy  = $window.FindName('TxtSelectedPolicy')
$txtSelectedMeta    = $window.FindName('TxtSelectedMeta')
$cmbExportFormat    = $window.FindName('CmbExportFormat')
$cmbExportScope     = $window.FindName('CmbExportScope')
$txtExportResult    = $window.FindName('TxtExportResult')
$txtStatus          = $window.FindName('TxtStatus')
$txtPolicyCount     = $window.FindName('TxtPolicyCount')

$dgPolicies.ItemsSource = $Script:AllPolicies

$cmbTypeFilter.Items.Add('All types') | Out-Null
$cmbTypeFilter.SelectedIndex = 0
foreach ($t in $Script:PolicySources.Keys) { [void]$cmbTypeFilter.Items.Add($t) }

$txtSearch.Text = 'Search by name...'
$txtSearch.Add_GotFocus({
    if ($txtSearch.Text -eq 'Search by name...') { $txtSearch.Text = ''; $txtSearch.Foreground = '#1E293B' }
})
$txtSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($txtSearch.Text)) { $txtSearch.Text = 'Search by name...'; $txtSearch.Foreground = '#94A3B8' }
})
$txtSearch.Foreground = '#94A3B8'

$txtTenantId.Text = ''
$txtClientId.Text = ''
$txtScopes.Text = ''
$txtTenantId.ToolTip = 'Only for Advanced sign-in: your Entra directory (tenant) ID'
$txtClientId.ToolTip = 'Only for Advanced sign-in: application (client) ID from your Entra app'
$txtScopes.ToolTip = 'Optional. Leave empty for recommended Intune read scopes. One Graph scope per line.'

$Script:FilteredView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Script:AllPolicies)
$Script:FilteredView.Filter = {
    param($item)
    $search = $txtSearch.Text
    if ($search -eq 'Search by name...') { $search = '' }
    $typeOk = ($cmbTypeFilter.SelectedIndex -le 0) -or ($item.Type -eq $cmbTypeFilter.SelectedItem)
    $searchOk = [string]::IsNullOrWhiteSpace($search) -or ($item.Name -like "*$search*")
    return ($typeOk -and $searchOk)
}

function Set-Status([string]$Message) {
    Invoke-OnUiThread { $txtStatus.Text = $Message }
}

function Set-ConnectedUI([bool]$Connected, $Context = $null) {
    Invoke-OnUiThread {
        if ($Connected) {
            $statusDot.Fill = '#86EFAC'
            $txtConnectionStatus.Text = 'Connected'
            $txtSubtitle.Text = "Tenant: $($Context.TenantId)"
            $txtTenantInfo.Text = "Client ID: $($Context.ClientId)`nAccount: $($Context.Account)`nTenant ID: $($Context.TenantId)`nScopes: $($Context.Scopes -join ', ')"
            $btnConnect.IsEnabled = $false
            $btnConnectAdvanced.IsEnabled = $false
            $btnDisconnect.IsEnabled = $true
            $btnRefresh.IsEnabled = $true
            $btnExport.IsEnabled = $true
        }
        else {
            $statusDot.Fill = '#FCA5A5'
            $txtConnectionStatus.Text = 'Not connected'
            $txtSubtitle.Text = 'Connect to Microsoft Graph to load policies'
            $txtTenantInfo.Text = 'Not connected yet.'
            $btnConnect.IsEnabled = $true
            $btnConnectAdvanced.IsEnabled = $true
            $btnDisconnect.IsEnabled = $false
            $btnRefresh.IsEnabled = $false
            $btnExport.IsEnabled = $false
            $btnLoadDetails.IsEnabled = $false
        }
    }
}

function Load-PoliciesAsync {
    Set-Status 'Loading policies from Microsoft Graph...'
    $btnRefresh.IsEnabled = $false
    $window.Dispatcher.InvokeAsync({
        try {
            $Script:AllPolicies.Clear()
            $list = Get-AllIntunePolicies
            foreach ($p in ($list | Sort-Object Type, Name)) {
                [void]$Script:AllPolicies.Add($p)
            }
            $txtPolicyCount.Text = "$($Script:AllPolicies.Count) policies"
            Set-Status "Done. $($Script:AllPolicies.Count) policies loaded."
        }
        catch {
            Set-Status "Load error: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
        }
        finally {
            $btnRefresh.IsEnabled = $Script:IsConnected
        }
    }) | Out-Null
}

function Show-PolicyDetails($Item) {
    if (-not $Item) { return }
    Set-Status "Loading settings for '$($Item.Name)'..."
    try {
        $detail   = Get-PolicyDetail -Item $Item
        $settings = Convert-PolicyToSettingsList -Detail $detail -Type $Item.Type
        $dgSettings.ItemsSource = $settings
        $txtSelectedPolicy.Text = $Item.Name
        $txtSelectedMeta.Text   = "Type: $($Item.Type)  |  ID: $($Item.Id)  |  $($settings.Count) settings"
        Set-Status 'Settings loaded.'
    }
    catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null
    }
}

function Invoke-GraphConnect {
    param([switch]$UseAdvanced)
    try {
        Set-Status 'Connecting...'
        $btnConnect.IsEnabled = $false
        $btnConnectAdvanced.IsEnabled = $false

        if ($UseAdvanced) {
            if ([string]::IsNullOrWhiteSpace($txtClientId.Text)) {
                throw [System.InvalidOperationException]::new('Client ID is required for advanced sign-in.')
            }
            if ([string]::IsNullOrWhiteSpace($txtTenantId.Text)) {
                throw [System.InvalidOperationException]::new('Tenant ID is required for advanced sign-in.')
            }
            $scopes = Resolve-GraphScopes -CustomScopesText $txtScopes.Text -UseAppRegistration
            $ctx = Connect-ToGraphUniversal -OwnerWindow $window -TenantId $txtTenantId.Text -ClientId $txtClientId.Text -Scopes $scopes
        }
        else {
            $ctx = Connect-ToGraphUniversal -OwnerWindow $window -Scopes $Script:QuickConnectScopes
        }

        Set-ConnectedUI -Connected $true -Context $ctx
        Load-PoliciesAsync
    }
    catch {
        Set-ConnectedUI -Connected $false
        Set-Status "Connection failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Connection error', 'OK', 'Error') | Out-Null
    }
}

$btnConnect.Add_Click({ Invoke-GraphConnect })
$btnConnectAdvanced.Add_Click({ Invoke-GraphConnect -UseAdvanced })

$btnDisconnect.Add_Click({
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
    $Script:IsConnected = $false
    $Script:AllPolicies.Clear()
    $dgSettings.ItemsSource = $null
    $txtPolicyCount.Text = '0 policies'
    Set-ConnectedUI -Connected $false
    Set-Status 'Disconnected.'
})

$btnRefresh.Add_Click({ Load-PoliciesAsync })

$btnLoadDetails.Add_Click({
    $selected = $dgPolicies.SelectedItem
    if ($selected) { Show-PolicyDetails -Item $selected }
})

$dgPolicies.Add_SelectionChanged({
    $hasSelection = $dgPolicies.SelectedItems.Count -gt 0
    $btnLoadDetails.IsEnabled = $hasSelection -and $Script:IsConnected
    if ($dgPolicies.SelectedItems.Count -eq 1) {
        Show-PolicyDetails -Item $dgPolicies.SelectedItem
    }
})

$txtSearch.Add_TextChanged({ $Script:FilteredView.Refresh() })
$cmbTypeFilter.Add_SelectionChanged({ $Script:FilteredView.Refresh() })

$btnExport.Add_Click({
    $scopeItem = $cmbExportScope.SelectedItem
    $scopeText = if ($scopeItem) { $scopeItem.Content } else { 'All loaded policies' }

    if ($scopeText -match 'Selected') {
        $toExport = @($dgPolicies.SelectedItems)
        if ($toExport.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Select policies on the Policies tab first.', 'No selection', 'OK', 'Warning') | Out-Null
            return
        }
    }
    else {
        $toExport = @($Script:AllPolicies)
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose a folder for the export'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $folder = $dialog.SelectedPath

    $formatItem = $cmbExportFormat.SelectedItem
    $formatText = if ($formatItem) { $formatItem.Content } else { 'JSON' }
    $format = switch -Regex ($formatText) { 'CSV' { 'CSV' } 'HTML' { 'HTML' } default { 'JSON' } }

    try {
        Set-Status 'Exporting...'
        $btnExport.IsEnabled = $false
        $paths = Export-Policies -Policies $toExport -Format $format -Folder $folder
        $txtExportResult.Text = "Export complete:`n$($paths -join "`n")"
        Set-Status 'Export complete.'
        $answer = [System.Windows.MessageBox]::Show(
            "Export successful!`n`n$($paths -join "`n")`n`nOpen folder?",
            'Export complete', 'YesNo', 'Information')
        if ($answer -eq 'Yes') { Start-Process $folder }
    }
    catch {
        Set-Status "Export failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Export error', 'OK', 'Error') | Out-Null
    }
    finally {
        $btnExport.IsEnabled = $Script:IsConnected
    }
})

try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    Set-MgGraphOption -EnableLoginByWAM $false -ErrorAction SilentlyContinue | Out-Null
} catch {}

try {
    $existing = Get-MgGraphSession
    if (Test-HasIntuneGraphSession -Context $existing) {
        $Script:IsConnected   = $true
        $Script:CurrentTenant = $existing.TenantId
        Set-ConnectedUI -Connected $true -Context $existing
        Load-PoliciesAsync
    }
} catch {}

[void]$window.ShowDialog()
}

if ($MyInvocation.InvocationName -ne '.') {
    Show-IntunePoliciesGUI
}
