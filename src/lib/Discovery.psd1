@{
    RootModule        = 'Discovery.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7d4b9a52-0a9e-43ec-94ae-d4f1c19a8e2a'
    Author            = 'windows-cluster-host'
    CompanyName       = 'windows-cluster-host'
    Copyright         = '(c) windows-cluster-host. Released under repo license.'
    Description       = 'Multi-strategy MeshCentral controller discovery for the windows-cluster-host setup script.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Find-Controller', 'Test-ControllerEndpoint', 'Get-SubnetScanTargets')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','discovery','meshcentral')
        }
    }
}
