@{
    RootModule        = 'Logging.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8c5b1c12-9f4f-4e51-9c0a-7a3a1d2bdc11'
    Author            = 'windows-cluster-host'
    CompanyName       = 'windows-cluster-host'
    Copyright         = '(c) windows-cluster-host. Released under repo license.'
    Description       = 'Structured, level-filtered, stage-aware logging for the windows-cluster-host setup script.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Initialize-ClusterLog',
        'Get-ClusterLogPath',
        'Write-ClusterLog',
        'Start-StageLog',
        'Stop-StageLog',
        'Get-OpenStageName',
        'Reset-ClusterLogState'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','logging')
        }
    }
}
