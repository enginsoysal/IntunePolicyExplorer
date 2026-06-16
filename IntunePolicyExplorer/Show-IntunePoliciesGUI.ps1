#Requires -Version 5.1
<#
.SYNOPSIS
    Graphical Intune Policy Explorer - browse, search, and export Microsoft Intune policies.

.DESCRIPTION
    Single self-contained WPF script. Browse policies, run tenant analysis (recommendations,
    health, conflicts), search settings across policies, and export audit reports.
    Requires Microsoft.Graph.Authentication module.

.EXAMPLE
    .\Show-IntunePoliciesGUI.ps1
#>

function Show-IntunePoliciesGUI {
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:AppVersion = '1.3.0'

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

function Test-HasRequiredIntuneScopes {
    param($Context)
    if (-not $Context) { return $false }
    $scopes = @($Context.Scopes)
    return (@($scopes | Where-Object {
        $_ -in $Script:QuickConnectApiScopes -or
        $_ -match '^DeviceManagement.*\.Read' -or
        $_ -match '^DeviceManagement.*\.ReadWrite'
    }).Count -gt 0)
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
$Script:SettingsIndex = @()
$Script:AnalysisData  = $null

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
        if (-not (Test-HasRequiredIntuneScopes -Context $context)) { $needsReconnect = $true }
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

function Get-GraphProperty {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Invoke-GraphPaged {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $next    = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($page -is [System.Array]) {
            if ($page.Count -gt 0) { $results.AddRange(@($page)) }
            break
        }
        $value = Get-GraphProperty -Object $page -Name 'value'
        if ($null -ne $value) {
            $results.AddRange(@($value))
        }
        elseif ($null -ne (Get-GraphProperty -Object $page -Name 'id')) {
            $results.Add($page)
            break
        }
        else {
            break
        }
        $next = Get-GraphProperty -Object $page -Name '@odata.nextLink'
    }
    return $results
}

function Get-PolicyListItem {
    param($Policy, [string]$Type, [hashtable]$Source)
    $name = Get-GraphProperty -Object $Policy -Name 'displayName'
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = Get-GraphProperty -Object $Policy -Name 'name'
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = Get-GraphProperty -Object $Policy -Name 'id'
    }
    $odataType = Get-GraphProperty -Object $Policy -Name '@odata.type'
    [PSCustomObject]@{
        Type         = $Type
        Name         = $name
        Id           = Get-GraphProperty -Object $Policy -Name 'id'
        Created      = Get-GraphProperty -Object $Policy -Name 'createdDateTime'
        Modified     = Get-GraphProperty -Object $Policy -Name 'lastModifiedDateTime'
        Description  = Get-GraphProperty -Object $Policy -Name 'description'
        Platform     = if ($odataType) { ($odataType -replace '#microsoft.graph.', '') } else { '' }
        Endpoint         = $Source.Endpoint
        DetailExpand     = $Source.DetailExpand
        Raw              = $Policy
        AssignmentCount  = $null
    }
}

function Get-AllIntunePolicies {
    $items  = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Script:PolicySources.GetEnumerator()) {
        $type   = $entry.Key
        $source = $entry.Value
        try {
            $uri  = "https://graph.microsoft.com/beta/$($source.Endpoint)?`$top=999"
            $list = Invoke-GraphPaged -Uri $uri
            foreach ($p in $list) {
                try {
                    $items.Add((Get-PolicyListItem -Policy $p -Type $type -Source $source))
                }
                catch {
                    $id = Get-GraphProperty -Object $p -Name 'id'
                    $label = if ($id) { "$type ($id)" } else { $type }
                    $errors.Add("$label`: $($_.Exception.Message)")
                }
            }
        }
        catch {
            $errors.Add("$type`: $($_.Exception.Message)")
        }
    }
    return [PSCustomObject]@{ Policies = $items; Errors = $errors }
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
            $settings = Get-GraphProperty -Object $Detail -Name 'settings'
            foreach ($s in @($(if ($null -ne $settings) { $settings } else { @() }))) {
                $instance = Get-GraphProperty -Object $s -Name 'settingInstance'
                $settingId = Get-GraphProperty -Object $instance -Name 'settingDefinitionId'
                Add-Row 'Settings Catalog' $settingId $instance
            }
        }
        'Administrative Templates' {
            $definitionValues = Get-GraphProperty -Object $Detail -Name 'definitionValues'
            foreach ($dv in @($(if ($null -ne $definitionValues) { $definitionValues } else { @() }))) {
                $definition = Get-GraphProperty -Object $dv -Name 'definition'
                $name = Get-GraphProperty -Object $definition -Name 'displayName'
                if ([string]::IsNullOrWhiteSpace($name)) {
                    $name = Get-GraphProperty -Object $dv -Name 'definitionId'
                }
                Add-Row 'ADMX' $name $dv
            }
        }
        'Endpoint Security' {
            $settings = Get-GraphProperty -Object $Detail -Name 'settings'
            foreach ($s in @($(if ($null -ne $settings) { $settings } else { @() }))) {
                Add-Row 'Endpoint Security' (Get-GraphProperty -Object $s -Name 'definitionId') (Get-GraphProperty -Object $s -Name 'valueJson')
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

function Format-SettingDisplayValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    try { return ($Value | ConvertTo-Json -Depth 8 -Compress) }
    catch { return [string]$Value }
}

function Get-PolicyAssignments {
    param($Item)
    try {
        $uri = "https://graph.microsoft.com/beta/$($Item.Endpoint)/$($Item.Id)/assignments"
        return @(Invoke-GraphPaged -Uri $uri)
    }
    catch {
        return @()
    }
}

function New-RecommendationRow {
    param(
        [string]$Status,
        [string]$Category,
        [string]$Title,
        [string]$Detail,
        [string]$Advice
    )
    return [PSCustomObject]@{
        Status   = $Status
        Category = $Category
        Title    = $Title
        Detail   = $Detail
        Advice   = $Advice
    }
}

function Build-PolicySettingsIndex {
    param([array]$Policies)

    $index = [System.Collections.Generic.List[object]]::new()
    $skipSettings = @(
        '@odata.context', '@odata.type', 'displayName', 'description',
        'createdDateTime', 'lastModifiedDateTime', 'version', 'roleScopeTagIds'
    )

    foreach ($p in $Policies) {
        try {
            $detail   = Get-PolicyDetail -Item $p
            $settings = Convert-PolicyToSettingsList -Detail $detail -Type $p.Type
            foreach ($s in $settings) {
                if ($s.Setting -in $skipSettings) { continue }
                $valueText = Format-SettingDisplayValue $s.Value
                $index.Add([PSCustomObject]@{
                    PolicyType = $p.Type
                    PolicyName = $p.Name
                    PolicyId   = $p.Id
                    Category   = $s.Category
                    Setting    = $s.Setting
                    Value      = $valueText
                    SearchBlob = "$($s.Setting) $valueText".ToLowerInvariant()
                })
            }
        }
        catch {
            continue
        }
    }
    return @($index)
}

function Get-IntuneRecommendations {
    param(
        [array]$Policies,
        [array]$SettingsIndex
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $blob = ($SettingsIndex | ForEach-Object { $_.SearchBlob }) -join ' '

    function Test-HasType([string]$TypeName) {
        return (@($Policies | Where-Object { $_.Type -eq $TypeName }).Count -gt 0)
    }
    function Test-Blob([string]$Pattern) {
        return ($blob -match $Pattern)
    }
    function Test-Platform([string]$Pattern) {
        return (@($Policies | Where-Object { $_.Platform -match $Pattern }).Count -gt 0)
    }

    $complianceCount = @($Policies | Where-Object { $_.Type -eq 'Compliance' }).Count
    if ($complianceCount -gt 0) {
        $rows.Add((New-RecommendationRow 'Pass' 'Compliance' 'Device compliance policies defined' "$complianceCount compliance policy(ies) found." 'Review assignments and minimum OS/password requirements periodically.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Fail' 'Compliance' 'Device compliance policies defined' 'No compliance policies found.' 'Create Windows/iOS/Android compliance policies to enforce minimum security requirements.'))
    }

    if (Test-Blob 'osminimumversion|minversion|minimumos|operatingsystemversion') {
        $rows.Add((New-RecommendationRow 'Pass' 'Compliance' 'Minimum OS version enforced' 'Compliance or configuration includes minimum OS settings.' 'Keep minimum versions aligned with vendor support lifecycles.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Compliance' 'Minimum OS version enforced' 'No explicit minimum OS setting detected.' 'Add a compliance policy with minimum OS version for supported platforms.'))
    }

    if (Test-Blob 'bitlocker|encryption|requiredeviceencryption|personalvault|filevault') {
        $rows.Add((New-RecommendationRow 'Pass' 'Encryption' 'Device encryption configured' 'Encryption-related settings found in policies.' 'Verify encryption applies to all corporate device groups.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Fail' 'Encryption' 'Device encryption configured' 'No BitLocker/FileVault/encryption settings detected.' 'Configure BitLocker (Windows) or platform encryption via compliance or configuration profile.'))
    }

    if ((Test-Blob 'windowsupdate|qualitydeferral|featuredeferral|deadline|autopatch') -or (Test-Platform 'windowsUpdateForBusiness')) {
        $rows.Add((New-RecommendationRow 'Pass' 'Updates' 'Windows update management' 'Update rings or Windows Update for Business settings detected.' 'Validate deferral periods and deadline enforcement for production rings.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Updates' 'Windows update management' 'No dedicated update policy detected.' 'Use Settings Catalog or Update Rings to manage quality/feature updates.'))
    }

    if (Test-Blob 'defender|antivirus|windowdefender|tamperprotection|mde') {
        $rows.Add((New-RecommendationRow 'Pass' 'Endpoint Protection' 'Microsoft Defender settings present' 'Defender or antivirus-related settings found.' 'Consider Endpoint Security antivirus template for centralized management.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Endpoint Protection' 'Microsoft Defender settings present' 'No Defender-specific settings detected in loaded policies.' 'Deploy Defender antivirus/EDR baseline via Endpoint Security or Settings Catalog.'))
    }

    if (Test-Blob 'firewall|windowspolicyfirewall|networkprotection') {
        $rows.Add((New-RecommendationRow 'Pass' 'Network' 'Firewall policy configured' 'Firewall-related settings detected.' 'Ensure firewall rules align with least-privilege network access.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Network' 'Firewall policy configured' 'No firewall settings detected.' 'Configure Windows Firewall via Settings Catalog or Endpoint Security.'))
    }

    if (Test-Blob 'attacksurfacereduction|asrrules|asr') {
        $rows.Add((New-RecommendationRow 'Pass' 'Endpoint Protection' 'Attack Surface Reduction (ASR)' 'ASR-related settings found.' 'Audit ASR rules in audit mode before switching to block.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Endpoint Protection' 'Attack Surface Reduction (ASR)' 'No ASR rules detected.' 'Enable ASR rules via Endpoint Security Attack Surface Reduction template.'))
    }

    if (Test-HasType 'Endpoint Security') {
        $rows.Add((New-RecommendationRow 'Pass' 'Endpoint Security' 'Endpoint Security intents deployed' 'Endpoint Security policies are in use.' 'Map intents to Microsoft security baselines where possible.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Endpoint Security' 'Endpoint Security intents deployed' 'No Endpoint Security policies found.' 'Use Endpoint Security for AV, disk encryption, firewall, and ASR templates.'))
    }

    if (Test-HasType 'App Protection (iOS)') {
        $rows.Add((New-RecommendationRow 'Pass' 'App Protection' 'iOS app protection (MAM)' 'iOS app protection policy found.' 'Assign to all BYOD iOS users accessing corporate data.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'App Protection' 'iOS app protection (MAM)' 'No iOS app protection policy.' 'Create iOS MAM policy for unmanaged devices accessing corporate apps.'))
    }

    if (Test-HasType 'App Protection (Android)') {
        $rows.Add((New-RecommendationRow 'Pass' 'App Protection' 'Android app protection (MAM)' 'Android app protection policy found.' 'Require PIN/biometrics and block jailbroken devices.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'App Protection' 'Android app protection (MAM)' 'No Android app protection policy.' 'Create Android MAM policy for mobile productivity apps.'))
    }

    if (Test-HasType 'Windows Autopilot') {
        $rows.Add((New-RecommendationRow 'Pass' 'Provisioning' 'Windows Autopilot deployment profile' 'Autopilot profile(s) configured.' 'Validate ESP (Enrollment Status Page) and assignment to device groups.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Provisioning' 'Windows Autopilot deployment profile' 'No Autopilot deployment profile found.' 'Create Autopilot profiles for zero-touch Windows provisioning.'))
    }

    if (Test-HasType 'Settings Catalog') {
        $rows.Add((New-RecommendationRow 'Pass' 'Modern Management' 'Settings Catalog in use' 'Settings Catalog policies present (recommended over legacy profiles).' 'Migrate remaining legacy profiles to Settings Catalog where supported.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Modern Management' 'Settings Catalog in use' 'No Settings Catalog policies detected.' 'Prefer Settings Catalog for new Windows configuration policies.'))
    }

    if (Test-HasType 'Administrative Templates') {
        $rows.Add((New-RecommendationRow 'Pass' 'Modern Management' 'Administrative Templates (ADMX)' 'ADMX-backed policies found.' 'Document GPO migration path if co-managing with on-prem AD.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Modern Management' 'Administrative Templates (ADMX)' 'No ADMX administrative template policies.' 'Use ADMX templates only when Settings Catalog lacks required settings.'))
    }

    if (Test-Blob 'password|passcode|pin|simplepin') {
        $rows.Add((New-RecommendationRow 'Pass' 'Identity' 'Device password / PIN requirements' 'Password or PIN requirements detected.' 'Align complexity with your identity standards (e.g. 6+ digit PIN on mobile).'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Identity' 'Device password / PIN requirements' 'No password/PIN settings detected in policies.' 'Enforce passcode via compliance or app protection policies.'))
    }

    if (Test-HasType 'Mobile App Configurations') {
        $rows.Add((New-RecommendationRow 'Pass' 'Apps' 'Mobile app configuration policies' 'App configuration policies found.' 'Use app config for managed apps (Outlook, Edge) with pre-defined settings.'))
    }
    else {
        $rows.Add((New-RecommendationRow 'Warning' 'Apps' 'Mobile app configuration policies' 'No mobile app configuration policies.' 'Optional: add app config for consistent mobile app experience.'))
    }

    return @($rows)
}

function Get-PolicyHealthFindings {
    param(
        [array]$Policies,
        [hashtable]$AssignmentMap
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $staleCutoff = (Get-Date).AddMonths(-12)

    foreach ($p in $Policies) {
        $assignCount = if ($AssignmentMap.ContainsKey($p.Id)) { $AssignmentMap[$p.Id] } else { 0 }
        if ($assignCount -eq 0) {
            $findings.Add([PSCustomObject]@{
                Severity   = 'Warning'
                PolicyName = $p.Name
                PolicyType = $p.Type
                Finding    = 'Unassigned'
                Detail     = 'Policy has no group or user assignments.'
            })
        }

        if ($p.Modified) {
            try {
                $modified = [datetime]$p.Modified
                if ($modified -lt $staleCutoff) {
                    $findings.Add([PSCustomObject]@{
                        Severity   = 'Info'
                        PolicyName = $p.Name
                        PolicyType = $p.Type
                        Finding    = 'Stale'
                        Detail     = "Last modified $($modified.ToString('yyyy-MM-dd')) (>12 months ago)."
                    })
                }
            }
            catch { }
        }
    }

    foreach ($group in ($Policies | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })) {
        $findings.Add([PSCustomObject]@{
            Severity   = 'Warning'
            PolicyName = $group.Name
            PolicyType = ($group.Group | Select-Object -ExpandProperty Type -Unique) -join ', '
            Finding    = 'Duplicate name'
            Detail     = "$($group.Count) policies share the same display name."
        })
    }

    return @($findings)
}

function Get-SettingConflicts {
    param([array]$SettingsIndex)

    $conflicts = [System.Collections.Generic.List[object]]::new()
    $groups = $SettingsIndex | Where-Object { $_.Setting -and $_.Setting -notmatch '^@odata' } |
        Group-Object -Property Setting |
        Where-Object { $_.Count -gt 1 }

    foreach ($g in $groups) {
        $distinctValues = @($g.Group | Select-Object -ExpandProperty Value -Unique)
        if ($distinctValues.Count -le 1) { continue }

        $policyList = ($g.Group | ForEach-Object { "$($_.PolicyName) ($($_.PolicyType))" }) -join '; '
        $valueList  = ($g.Group | ForEach-Object { $_.Value }) -join ' | '
        $conflicts.Add([PSCustomObject]@{
            Setting  = $g.Name
            Policies = $policyList
            Values   = $valueList
            Detail   = "$($g.Count) policies configure '$($g.Name)' with $($distinctValues.Count) different values."
        })
    }
    return @($conflicts)
}

function Invoke-TenantAnalysis {
    param([array]$Policies)

    $assignmentMap = @{}
    $total = $Policies.Count
    $i = 0

    foreach ($p in $Policies) {
        $i++
        Set-Status "Analyzing assignments ($i/$total): $($p.Name)"
        $assignments = Get-PolicyAssignments -Item $p
        $assignmentMap[$p.Id] = @($assignments).Count
        $p | Add-Member -NotePropertyName AssignmentCount -NotePropertyValue @($assignments).Count -Force
    }

    Set-Status 'Building settings index (this may take a while)...'
    $settingsIndex = Build-PolicySettingsIndex -Policies $Policies

    Set-Status 'Evaluating recommendations and conflicts...'
    $recommendations = Get-IntuneRecommendations -Policies $Policies -SettingsIndex $settingsIndex
    $health          = Get-PolicyHealthFindings -Policies $Policies -AssignmentMap $assignmentMap
    $conflicts       = Get-SettingConflicts -SettingsIndex $settingsIndex

    return [PSCustomObject]@{
        SettingsIndex   = $settingsIndex
        Recommendations = $recommendations
        Health          = $health
        Conflicts       = $conflicts
        AssignmentMap   = $assignmentMap
        AnalyzedAt      = Get-Date
    }
}

function Search-PolicySettings {
    param(
        [string]$Query,
        [array]$SettingsIndex
    )
    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    $q = $Query.Trim().ToLowerInvariant()
    return @($SettingsIndex | Where-Object {
        $_.Setting -like "*$q*" -or $_.Value -like "*$q*" -or $_.SearchBlob -like "*$q*"
    })
}

function Export-AuditReport {
    param(
        [array]$Policies,
        $Analysis,
        [string]$Folder
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path      = Join-Path $Folder "IntuneAuditReport_$timestamp.html"
    $tenant    = $Script:CurrentTenant
    $passCount = @($Analysis.Recommendations | Where-Object { $_.Status -eq 'Pass' }).Count
    $warnCount = @($Analysis.Recommendations | Where-Object { $_.Status -eq 'Warning' }).Count
    $failCount = @($Analysis.Recommendations | Where-Object { $_.Status -eq 'Fail' }).Count

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(@'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Intune Audit Report</title>
<style>
body{font-family:Segoe UI,sans-serif;margin:2rem;background:#f5f7fa;color:#1a1a2e}
h1{color:#0078d4}h2{color:#2d3748;border-bottom:2px solid #0078d4;padding-bottom:.3rem;margin-top:2rem}
table{border-collapse:collapse;width:100%;margin:1rem 0;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.08)}
th{background:#0078d4;color:#fff;text-align:left;padding:.6rem .8rem}
td{padding:.5rem .8rem;border-bottom:1px solid #e2e8f0;vertical-align:top;word-break:break-word}
tr:hover td{background:#edf2f7}.meta{color:#64748b;font-size:.9rem}
.pass{color:#166534}.warn{color:#9a3412}.fail{color:#991b1b}
.summary{display:flex;gap:1rem;flex-wrap:wrap;margin:1rem 0}
.card{background:#fff;padding:1rem 1.2rem;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,.08);min-width:120px}
.card strong{font-size:1.4rem;display:block}
</style></head><body>
'@)
    [void]$sb.AppendLine('<h1>Intune Policy Audit Report</h1>')
    [void]$sb.AppendLine("<p class='meta'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Tenant: $tenant | Policies: $($Policies.Count) | Version: $($Script:AppVersion)</p>")
    [void]$sb.AppendLine("<div class='summary'><div class='card pass'><strong>$passCount</strong>Passed</div><div class='card warn'><strong>$warnCount</strong>Warnings</div><div class='card fail'><strong>$failCount</strong>Failed</div></div>")

    [void]$sb.AppendLine('<h2>Recommendations</h2><table><tr><th>Status</th><th>Category</th><th>Check</th><th>Detail</th><th>Advice</th></tr>')
    foreach ($r in $Analysis.Recommendations) {
        $cls = switch ($r.Status) { 'Pass' { 'pass' } 'Fail' { 'fail' } default { 'warn' } }
        [void]$sb.AppendLine("<tr class='$cls'><td>$([System.Web.HttpUtility]::HtmlEncode($r.Status))</td><td>$([System.Web.HttpUtility]::HtmlEncode($r.Category))</td><td>$([System.Web.HttpUtility]::HtmlEncode($r.Title))</td><td>$([System.Web.HttpUtility]::HtmlEncode($r.Detail))</td><td>$([System.Web.HttpUtility]::HtmlEncode($r.Advice))</td></tr>")
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h2>Policy Health</h2><table><tr><th>Severity</th><th>Policy</th><th>Type</th><th>Finding</th><th>Detail</th></tr>')
    foreach ($h in $Analysis.Health) {
        [void]$sb.AppendLine("<tr><td>$([System.Web.HttpUtility]::HtmlEncode($h.Severity))</td><td>$([System.Web.HttpUtility]::HtmlEncode($h.PolicyName))</td><td>$([System.Web.HttpUtility]::HtmlEncode($h.PolicyType))</td><td>$([System.Web.HttpUtility]::HtmlEncode($h.Finding))</td><td>$([System.Web.HttpUtility]::HtmlEncode($h.Detail))</td></tr>")
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h2>Setting Conflicts</h2><table><tr><th>Setting</th><th>Policies</th><th>Values</th><th>Detail</th></tr>')
    foreach ($c in $Analysis.Conflicts) {
        [void]$sb.AppendLine("<tr><td>$([System.Web.HttpUtility]::HtmlEncode($c.Setting))</td><td>$([System.Web.HttpUtility]::HtmlEncode($c.Policies))</td><td><pre style='margin:0;white-space:pre-wrap'>$([System.Web.HttpUtility]::HtmlEncode($c.Values))</pre></td><td>$([System.Web.HttpUtility]::HtmlEncode($c.Detail))</td></tr>")
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h2>Policy Inventory</h2><table><tr><th>Type</th><th>Name</th><th>Platform</th><th>Assignments</th><th>Last modified</th></tr>')
    foreach ($p in ($Policies | Sort-Object Type, Name)) {
        $ac = if ($null -ne $p.AssignmentCount) { $p.AssignmentCount } else { '-' }
        [void]$sb.AppendLine("<tr><td>$([System.Web.HttpUtility]::HtmlEncode($p.Type))</td><td>$([System.Web.HttpUtility]::HtmlEncode($p.Name))</td><td>$([System.Web.HttpUtility]::HtmlEncode($p.Platform))</td><td>$ac</td><td>$([System.Web.HttpUtility]::HtmlEncode($p.Modified))</td></tr>")
    }
    [void]$sb.AppendLine('</table></body></html>')

    $sb.ToString() | Set-Content -Path $path -Encoding UTF8
    return @($path)
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
                <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="170"/>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*" MinWidth="180"/>
                <DataGridTextColumn Header="Platform" Binding="{Binding Platform}" Width="140"/>
                <DataGridTextColumn Header="Assignments" Binding="{Binding AssignmentCount}" Width="90"/>
                <DataGridTextColumn Header="Last modified" Binding="{Binding Modified}" Width="140"/>
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
            <Path Data="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M11,17V16H9V14H13V13H11A1,1 0 0,1 10,12V9A1,1 0 0,1 11,8H13V10H11V12H13A1,1 0 0,1 14,13V16A1,1 0 0,1 13,17H11Z" Fill="{Binding RelativeSource={RelativeSource AncestorType=TabItem}, Path=Foreground}" Width="14" Height="14" Stretch="Uniform" Margin="0,0,8,0"/>
            <TextBlock Text="Insights" VerticalAlignment="Center"/>
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
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Tenant analysis" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock x:Name="TxtAnalysisSummary" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap" Margin="0,4,0,0"
                           Text="Run analysis for recommendations, policy health, setting conflicts, and cross-policy search."/>
              </StackPanel>
              <Button x:Name="BtnAnalyze" Grid.Column="1" Content="Analyze tenant" VerticalAlignment="Center" IsEnabled="False" MinWidth="140"/>
            </Grid>
          </Border>
          <Border Grid.Row="1" Background="{StaticResource Surface}" CornerRadius="10" BorderBrush="{StaticResource Border}" BorderThickness="1">
            <TabControl Margin="8">
              <TabItem Header="Recommendations">
                <DataGrid x:Name="DgRecommendations" IsReadOnly="True" Margin="4">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="80"/>
                    <DataGridTextColumn Header="Category" Binding="{Binding Category}" Width="130"/>
                    <DataGridTextColumn Header="Check" Binding="{Binding Title}" Width="*" MinWidth="200"/>
                    <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*" MinWidth="220"/>
                    <DataGridTextColumn Header="Advice" Binding="{Binding Advice}" Width="2*" MinWidth="220"/>
                  </DataGrid.Columns>
                </DataGrid>
              </TabItem>
              <TabItem Header="Policy health">
                <DataGrid x:Name="DgHealth" IsReadOnly="True" Margin="4">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Severity" Binding="{Binding Severity}" Width="90"/>
                    <DataGridTextColumn Header="Policy" Binding="{Binding PolicyName}" Width="*" MinWidth="180"/>
                    <DataGridTextColumn Header="Type" Binding="{Binding PolicyType}" Width="160"/>
                    <DataGridTextColumn Header="Finding" Binding="{Binding Finding}" Width="120"/>
                    <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*" MinWidth="220"/>
                  </DataGrid.Columns>
                </DataGrid>
              </TabItem>
              <TabItem Header="Conflicts">
                <DataGrid x:Name="DgConflicts" IsReadOnly="True" Margin="4">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Setting" Binding="{Binding Setting}" Width="*" MinWidth="180"/>
                    <DataGridTextColumn Header="Policies" Binding="{Binding Policies}" Width="2*" MinWidth="240"/>
                    <DataGridTextColumn Header="Values" Binding="{Binding Values}" Width="2*" MinWidth="200"/>
                    <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="*" MinWidth="180"/>
                  </DataGrid.Columns>
                </DataGrid>
              </TabItem>
              <TabItem Header="Find setting">
                <Grid Margin="4">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                  </Grid.RowDefinitions>
                  <Grid Margin="0,0,0,8">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="TxtFindSetting" Margin="0,0,8,0"/>
                    <Button x:Name="BtnFindSetting" Grid.Column="1" Content="Search" Style="{StaticResource SecondaryButton}" IsEnabled="False" MinWidth="100"/>
                  </Grid>
                  <DataGrid x:Name="DgFindResults" Grid.Row="1" IsReadOnly="True">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Policy" Binding="{Binding PolicyName}" Width="*" MinWidth="180"/>
                      <DataGridTextColumn Header="Type" Binding="{Binding PolicyType}" Width="150"/>
                      <DataGridTextColumn Header="Setting" Binding="{Binding Setting}" Width="*" MinWidth="180"/>
                      <DataGridTextColumn Header="Value" Binding="{Binding Value}" Width="2*" MinWidth="220"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </Grid>
              </TabItem>
            </TabControl>
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
                       Text="Export policies, settings, or a full audit report with recommendations and health findings."/>
            <TextBlock Text="Format" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <ComboBox x:Name="CmbExportFormat" Width="360" HorizontalAlignment="Left" Margin="0,0,0,16">
              <ComboBoxItem Content="JSON (full, including raw data)" IsSelected="True"/>
              <ComboBoxItem Content="CSV (overview + separate settings file)"/>
              <ComboBoxItem Content="HTML (readable report)"/>
              <ComboBoxItem Content="HTML Audit Report (recommendations + health + conflicts)"/>
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
$btnAnalyze         = $window.FindName('BtnAnalyze')
$txtAnalysisSummary = $window.FindName('TxtAnalysisSummary')
$dgRecommendations  = $window.FindName('DgRecommendations')
$dgHealth           = $window.FindName('DgHealth')
$dgConflicts        = $window.FindName('DgConflicts')
$txtFindSetting     = $window.FindName('TxtFindSetting')
$btnFindSetting     = $window.FindName('BtnFindSetting')
$dgFindResults      = $window.FindName('DgFindResults')

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

$txtFindSetting.Text = 'Search settings (e.g. BitLocker, Defender, USB)...'
$txtFindSetting.Add_GotFocus({
    if ($txtFindSetting.Text -eq 'Search settings (e.g. BitLocker, Defender, USB)...') {
        $txtFindSetting.Text = ''
        $txtFindSetting.Foreground = '#1E293B'
    }
})
$txtFindSetting.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($txtFindSetting.Text)) {
        $txtFindSetting.Text = 'Search settings (e.g. BitLocker, Defender, USB)...'
        $txtFindSetting.Foreground = '#94A3B8'
    }
})
$txtFindSetting.Foreground = '#94A3B8'

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
            $txtSubtitle.Text = "Tenant: $($Context.TenantId)  |  v$($Script:AppVersion)"
            $txtTenantInfo.Text = "Client ID: $($Context.ClientId)`nAccount: $($Context.Account)`nTenant ID: $($Context.TenantId)`nScopes: $($Context.Scopes -join ', ')"
            $btnConnect.IsEnabled = $false
            $btnConnectAdvanced.IsEnabled = $false
            $btnDisconnect.IsEnabled = $true
            $btnRefresh.IsEnabled = $true
            $btnExport.IsEnabled = $true
            $btnAnalyze.IsEnabled = $true
            $btnFindSetting.IsEnabled = $true
        }
        else {
            $statusDot.Fill = '#FCA5A5'
            $txtConnectionStatus.Text = 'Not connected'
            $txtSubtitle.Text = "Connect to Microsoft Graph to load policies  |  v$($Script:AppVersion)"
            $txtTenantInfo.Text = 'Not connected yet.'
            $btnConnect.IsEnabled = $true
            $btnConnectAdvanced.IsEnabled = $true
            $btnDisconnect.IsEnabled = $false
            $btnRefresh.IsEnabled = $false
            $btnExport.IsEnabled = $false
            $btnLoadDetails.IsEnabled = $false
            $btnAnalyze.IsEnabled = $false
            $btnFindSetting.IsEnabled = $false
        }
    }
}

function Show-PolicyLoadSummary {
    param(
        [int]$Count,
        [System.Collections.Generic.List[string]]$Errors,
        $Context
    )

    if ($Count -gt 0 -or $Errors.Count -eq 0) { return }

    $scopeHint = if (-not (Test-HasRequiredIntuneScopes -Context $Context)) {
        "`n`nYour sign-in token is missing Intune read scopes (DeviceManagement*.Read.All).`n" +
        'Click Disconnect, then sign in again and approve all requested read permissions.'
    }
    else { '' }

    $detail = if ($Errors.Count -gt 0) { "`n`nDetails:`n$($Errors -join "`n")" } else { '' }
    [void][System.Windows.MessageBox]::Show(
        "Connected, but no policies could be loaded.$scopeHint$detail",
        'No policies loaded', 'OK', 'Warning')
}

function Clear-AnalysisUI {
    $Script:AnalysisData  = $null
    $Script:SettingsIndex = @()
    $dgRecommendations.ItemsSource = $null
    $dgHealth.ItemsSource          = $null
    $dgConflicts.ItemsSource       = $null
    $dgFindResults.ItemsSource     = $null
    $txtAnalysisSummary.Text       = 'Run analysis for recommendations, policy health, setting conflicts, and cross-policy search.'
}

function Run-AnalysisAsync {
    if ($Script:AllPolicies.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Load policies first on the Policies tab.', 'No policies', 'OK', 'Warning') | Out-Null
        return
    }

    Set-Status 'Starting tenant analysis...'
    $btnAnalyze.IsEnabled = $false
    $Script:AnalysisPolicies = @($Script:AllPolicies)

    $window.Dispatcher.InvokeAsync({
        try {
            $analysis = Invoke-TenantAnalysis -Policies $Script:AnalysisPolicies
            $Script:AnalysisData  = $analysis
            $Script:SettingsIndex = $analysis.SettingsIndex

            $dgRecommendations.ItemsSource = $analysis.Recommendations
            $dgHealth.ItemsSource          = $analysis.Health
            $dgConflicts.ItemsSource       = $analysis.Conflicts

            $pass = @($analysis.Recommendations | Where-Object { $_.Status -eq 'Pass' }).Count
            $warn = @($analysis.Recommendations | Where-Object { $_.Status -eq 'Warning' }).Count
            $fail = @($analysis.Recommendations | Where-Object { $_.Status -eq 'Fail' }).Count
            $txtAnalysisSummary.Text = "Analyzed $($Script:AnalysisPolicies.Count) policies at $($analysis.AnalyzedAt.ToString('yyyy-MM-dd HH:mm')). Recommendations: $pass passed, $warn warnings, $fail failed. Health findings: $($analysis.Health.Count). Conflicts: $($analysis.Conflicts.Count)."
            $Script:FilteredView.Refresh()
            Set-Status 'Analysis complete.'
        }
        catch {
            Set-Status "Analysis error: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Analysis error', 'OK', 'Error') | Out-Null
        }
        finally {
            $btnAnalyze.IsEnabled = $Script:IsConnected
        }
    }) | Out-Null
}

function Load-PoliciesAsync {
    Set-Status 'Loading policies from Microsoft Graph...'
    $btnRefresh.IsEnabled = $false
    $Script:GraphContext = Get-MgGraphSession
    $window.Dispatcher.InvokeAsync({
        try {
            Clear-AnalysisUI
            $Script:AllPolicies.Clear()
            $result = Get-AllIntunePolicies
            foreach ($p in ($result.Policies | Sort-Object Type, Name)) {
                [void]$Script:AllPolicies.Add($p)
            }
            $txtPolicyCount.Text = "$($Script:AllPolicies.Count) policies"
            Set-Status "Done. $($Script:AllPolicies.Count) policies loaded."
            Show-PolicyLoadSummary -Count $Script:AllPolicies.Count -Errors $result.Errors -Context $Script:GraphContext
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
    Clear-AnalysisUI
    $dgSettings.ItemsSource = $null
    $txtPolicyCount.Text = '0 policies'
    Set-ConnectedUI -Connected $false
    Set-Status 'Disconnected.'
})

$btnRefresh.Add_Click({ Load-PoliciesAsync })

$btnAnalyze.Add_Click({ Run-AnalysisAsync })

$btnFindSetting.Add_Click({
    $query = $txtFindSetting.Text
    if ($query -eq 'Search settings (e.g. BitLocker, Defender, USB)...') { $query = '' }
    if ([string]::IsNullOrWhiteSpace($query)) {
        [System.Windows.MessageBox]::Show('Enter a setting name or value to search.', 'Search', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $Script:SettingsIndex -or $Script:SettingsIndex.Count -eq 0) {
        if ($Script:AllPolicies.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Load policies first, then run Analyze tenant.', 'No data', 'OK', 'Warning') | Out-Null
            return
        }
        Set-Status 'Building settings index for search...'
        $btnFindSetting.IsEnabled = $false
        $Script:FindSettingQuery = $query
        $window.Dispatcher.InvokeAsync({
            try {
                $Script:SettingsIndex = Build-PolicySettingsIndex -Policies @($Script:AllPolicies)
                $dgFindResults.ItemsSource = Search-PolicySettings -Query $Script:FindSettingQuery -SettingsIndex $Script:SettingsIndex
                Set-Status "Found $(@($dgFindResults.ItemsSource).Count) matches."
            }
            catch {
                Set-Status "Search error: $($_.Exception.Message)"
            }
            finally {
                $btnFindSetting.IsEnabled = $Script:IsConnected
            }
        }) | Out-Null
        return
    }
    $dgFindResults.ItemsSource = Search-PolicySettings -Query $query -SettingsIndex $Script:SettingsIndex
    Set-Status "Found $(@($dgFindResults.ItemsSource).Count) matches."
})

$txtFindSetting.Add_KeyDown({
    if ($_.Key -eq 'Return') { $btnFindSetting.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }
})

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
    $format = switch -Regex ($formatText) {
        'Audit' { 'AUDIT' }
        'CSV'   { 'CSV' }
        'HTML'  { 'HTML' }
        default { 'JSON' }
    }

    if ($format -eq 'AUDIT' -and -not $Script:AnalysisData) {
        $run = [System.Windows.MessageBox]::Show(
            'Audit report requires tenant analysis. Run Analyze tenant on the Insights tab now?',
            'Analysis required', 'YesNo', 'Question')
        if ($run -ne 'Yes') { return }
        try {
            Set-Status 'Running analysis for audit export...'
            $btnExport.IsEnabled = $false
            $Script:AnalysisData = Invoke-TenantAnalysis -Policies @($Script:AllPolicies)
            $Script:SettingsIndex = $Script:AnalysisData.SettingsIndex
            $dgRecommendations.ItemsSource = $Script:AnalysisData.Recommendations
            $dgHealth.ItemsSource          = $Script:AnalysisData.Health
            $dgConflicts.ItemsSource       = $Script:AnalysisData.Conflicts
            $Script:FilteredView.Refresh()
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Analysis error', 'OK', 'Error') | Out-Null
            $btnExport.IsEnabled = $Script:IsConnected
            return
        }
    }

    try {
        Set-Status 'Exporting...'
        $btnExport.IsEnabled = $false
        if ($format -eq 'AUDIT') {
            $paths = Export-AuditReport -Policies @($Script:AllPolicies) -Analysis $Script:AnalysisData -Folder $folder
        }
        else {
            $paths = Export-Policies -Policies $toExport -Format $format -Folder $folder
        }
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
