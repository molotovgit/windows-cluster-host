@{
    RootModule        = 'Retry.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a44e3b4d-1c20-43f1-86b7-2d4c7c1e6da9'
    Author            = 'windows-cluster-host'
    CompanyName       = 'windows-cluster-host'
    Copyright         = '(c) windows-cluster-host. Released under repo license.'
    Description       = 'Retry-with-backoff and fallback-chain primitives for the windows-cluster-host setup script.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Invoke-WithRetry', 'Invoke-WithFallback')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','retry','fallback')
        }
    }
}
