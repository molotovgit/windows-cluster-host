@{
    RootModule        = 'HardwareDetect.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f3712a4b-9c1f-49d0-a8a8-7f0e6e3bc2c5'
    Author            = 'windows-cluster-host'
    CompanyName       = 'windows-cluster-host'
    Copyright         = '(c) windows-cluster-host. Released under repo license.'
    Description       = 'Per-host hardware and OS-edition detection with multi-strategy fallbacks.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-WindowsSku',
        'Get-PhysicalDriveBest',
        'Get-ActiveWifiAdapter',
        'Get-VirtualizationSupport',
        'ConvertTo-CanonicalSku'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','hardware','detection')
        }
    }
}
