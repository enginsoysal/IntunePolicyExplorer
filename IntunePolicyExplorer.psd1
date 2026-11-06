@{
    RootModule = 'IntunePolicyExplorer.psm1'
    ModuleVersion = '1.3.2'
    GUID = 'a8f3c2e1-9b4d-4a6f-8e2c-1d5b7f9a3e6c'
    Author = 'Engin Soysal'
    CompanyName = 'ProSysTech'
    Copyright = '(c) 2026 Engin Soysal. MIT License.'
    Description = 'Read-only graphical Intune Policy Explorer with inventory analysis, setting search and audit exports.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @('Show-IntunePoliciesGUI')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Intune', 'MicrosoftGraph', 'Policy', 'GUI', 'DeviceManagement', 'Export')
            ProjectUri = 'https://github.com/enginsoysal/IntunePolicyExplorer'
            LicenseUri = 'https://github.com/enginsoysal/IntunePolicyExplorer/blob/main/LICENSE'
            ReleaseNotes = '1.3.2: Explicit incomplete analysis and unknown assignments; inventory-only recommendations; potential conflict labeling; scrollable forms and adaptive window sizing; reproducible release build and regression tests. Windows only. Microsoft.Graph.Authentication is installed on first use when missing.'
        }
    }
}
