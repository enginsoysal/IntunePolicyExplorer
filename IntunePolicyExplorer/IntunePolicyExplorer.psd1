@{
    RootModule        = 'IntunePolicyExplorer.psm1'
    ModuleVersion     = '1.3.0'
    GUID              = 'a8f3c2e1-9b4d-4a6f-8e2c-1d5b7f9a3e6c'
    Author            = 'Engin Soysal'
    CompanyName       = 'ProSysTech'
    Copyright         = '(c) 2026 Engin Soysal. MIT License.'
    Description       = 'Graphical Intune Policy Explorer - browse policies, run tenant analysis (recommendations, health, conflicts), search settings, and export audit reports via Microsoft Graph.'
    PowerShellVersion = '5.1'
    DotNetFrameworkVersion = '4.7.2'
    CompatiblePSEditions   = @('Desktop')

    FunctionsToExport = @('Show-IntunePoliciesGUI')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Intune', 'MicrosoftGraph', 'Policy', 'GUI', 'DeviceManagement', 'EndpointManager', 'Export', 'OpenSource')
            LicenseUri   = 'https://github.com/enginsoysal/IntunePolicyExplorer/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/enginsoysal/IntunePolicyExplorer'
            ReleaseNotes = '1.3.0: Insights tab (recommendations, policy health, setting conflicts, cross-policy search) and HTML audit report export.'
            Prerelease   = ''
        }
    }
}
