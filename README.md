# Intune Policy Explorer

Graphical PowerShell tool to browse, search, and export Microsoft Intune policies via Microsoft Graph.

Open-source software — contributions welcome.

- **Repository:** https://github.com/enginsoysal/IntunePolicyExplorer
- **License:** [MIT](LICENSE)

## Install from PowerShell Gallery

```powershell
Install-Module IntunePolicyExplorer -Scope CurrentUser -Force
Show-IntunePoliciesGUI
```

## Requirements

- Windows 10/11 with PowerShell 5.1+
- Microsoft Graph permissions (delegated) - Read **or** ReadWrite per area:
  - `DeviceManagementConfiguration.Read.All` or `.ReadWrite.All`
  - `DeviceManagementApps.Read.All` or `.ReadWrite.All`
  - `DeviceManagementManagedDevices.Read.All` or `.ReadWrite.All`
  - `Policy.Read.All` or `Policy.ReadWrite.DeviceConfiguration`
- Account with at least **Intune Reader** role

## Installation

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

## Usage

```powershell
.\Show-IntunePoliciesGUI.ps1
```

### Tabs

| Tab | Function |
|-----|----------|
| **Connection** | Sign in to Microsoft Graph |
| **Policies** | Overview of all policy types, search and filter |
| **Settings** | Detailed settings per selected policy |
| **Export** | JSON, CSV, or HTML report |

### Supported policy types

- Configuration Profiles (legacy)
- Settings Catalog
- Compliance policies
- Administrative Templates (ADMX)
- Endpoint Security
- Windows Autopilot
- App Protection (iOS / Android / Windows)
- Mobile App Configurations

### Sign-in

**Default:** Device code dialog (built into the app). No PowerShell console required.

**App registration** (Connection tab): Uses `Connect-MgGraph -TenantId -ClientId` with browser sign-in (same as in PowerShell). No client secret. Use when the default Graph CLI app is blocked by Conditional Access.

**App registration setup:** Add delegated Graph permissions and grant admin consent on your Entra app registration. Use the **Scopes** field to match the permissions on your Entra app (one scope per line).

## Export formats

- **JSON** – Full data including raw Graph object
- **CSV** – Overview + separate settings file
- **HTML** – Readable report for documentation/audit

## License

MIT License — see [LICENSE](LICENSE).

Copyright (c) 2026 Engin Soysal
