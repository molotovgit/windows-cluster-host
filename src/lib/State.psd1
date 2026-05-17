@{
    RootModule        = 'State.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6e1f2c30-2d4f-4b1d-bd72-1c6f9d1e3b22'
    Author            = 'windows-cluster-host'
    CompanyName       = 'windows-cluster-host'
    Copyright         = '(c) windows-cluster-host. Released under repo license.'
    Description       = 'Resume markers, run status, and reboot-resume scheduled-task helpers for the windows-cluster-host orchestrator.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Save-StageMarker', 'Get-StageMarker', 'Clear-StageMarker',
        'Set-ClusterRunStatus', 'Get-ClusterRunStatus',
        'Set-ClusterRunVersion', 'Reset-ClusterRunState',
        'Complete-ClusterRun',
        'Get-ResumeTaskInfo', 'Test-ResumeTask',
        'Register-ResumeTask', 'Unregister-ResumeTask',
        'New-ResumeTaskSpec'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('cluster','setup','windows','state','resume')
        }
    }
}
