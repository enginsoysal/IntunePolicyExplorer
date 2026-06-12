# Intune Policy Explorer

Open-source PowerShell GUI to **browse, search, and export** Microsoft Intune policies and their settings. Read-only — no policy changes.

- **Repository:** https://github.com/enginsoysal/IntunePolicyExplorer
- **License:** [MIT](LICENSE)

## Quick start

```powershell
Install-Module IntunePolicyExplorer -Scope CurrentUser -Force
Show-IntunePoliciesGUI
```

Click **Sign in with Microsoft**. No app registration required.

On first run, `Microsoft.Graph.Authentication` is installed automatically if needed.

## Who is this for?

Intune administrators who need to:

- Discover policies across Intune policy types
- Inspect settings per policy
- Export documentation (JSON, CSV, HTML)

No custom Entra app registration is required for typical use.

## Requirements

- Windows 10/11, PowerShell 5.1+
- Work or school account with **Intune read access** (e.g. Intune Reader role or equivalent)
- Microsoft Graph **delegated read** permissions (requested on first sign-in):
  - `DeviceManagementConfiguration.Read.All`
  - `DeviceManagementApps.Read.All`
  - `DeviceManagementManagedDevices.Read.All`
  - `Policy.Read.All`

## Sign-in

### Default (recommended)

**Sign in with Microsoft** uses the built-in Microsoft Graph sign-in flow:

1. Browser or sign-in window opens
2. Sign in with your work account
3. Approve read permissions (admin consent may already exist in your tenant)
4. Policies load automatically

### Advanced options (optional)

Only needed when default sign-in is blocked by **Conditional Access** (e.g. device code flow blocked).

Expand **Advanced options** and provide your own Entra app:

- Tenant ID
- Client ID
- Scopes (optional — leave empty for recommended Intune read scopes)

## Supported policy types

- Configuration Profiles
- Settings Catalog
- Compliance policies
- Administrative Templates (ADMX)
- Endpoint Security
- Windows Autopilot
- App Protection (iOS / Android / Windows)
- Mobile App Configurations

Unavailable types are skipped with a warning (depends on your permissions).

## Export

| Format | Contents |
|--------|----------|
| **JSON** | Full policy + settings + raw Graph object |
| **CSV** | Policy overview + separate settings CSV |
| **HTML** | Readable audit/documentation report |

Export selected policies or all loaded policies.

## Troubleshooting

| Issue | What to try |
|-------|-------------|
| Device code blocked by CA | Use **Advanced options** with your own Entra app |
| Invalid scope error | Update module: `Update-Module IntunePolicyExplorer -Force` |
| Empty policy list | Verify Intune Reader role and Graph read permissions |
| Sign-in window closes | Update Graph module: `Update-Module Microsoft.Graph.Authentication -Force` |

## Development

```powershell
git clone https://github.com/enginsoysal/IntunePolicyExplorer.git
.\Show-IntunePoliciesGUI.ps1
```

Publish to Gallery: `.\Publish-ToGallery.ps1 -ApiKey '<your-key>'`

## License

MIT License — Copyright (c) 2026 Engin Soysal. See [LICENSE](LICENSE).
