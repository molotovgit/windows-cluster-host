<#
.SYNOPSIS
    Stage 6 -- Agents. Install OpenSSH Server + MeshAgent so the cluster
    controller has two independent management channels into the host.

.DESCRIPTION
    Sub-stages, each with primary + fallback paths and idempotency probe:

      1. OpenSSH Server feature       Add-WindowsCapability (primary)
                                      -> DISM /Add-Capability (fallback)
      2. sshd service                 Set-Service Automatic + Start-Service
      3. Admin SSH key deployment     write -SshAuthorizedKey content to
                                      %ProgramData%\\ssh\\administrators_authorized_keys
      4. ACL hardening                inheritance off, SYSTEM:F + Administrators:F only
      5. MeshAgent installer          download from controller via SMB
                                      then HTTPS, verify SHA256 if known
      6. MeshAgent install            run installer with -fullinstall, verify service

    Each sub-stage logs a per-step Status. The aggregate Overall is Fail
    if any sub-stage failed, Warn if any warned, Pass otherwise.

    -DryRun reports what would change without applying.

    Returns: pscustomobject @{ Overall; Steps[]; PassCount; WarnCount; FailCount }
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultAgentsInvoker {
    @{
        # OpenSSH
        GetOpenSshState   = {
            try {
                $c = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
                     Select-Object -First 1
                if ($c) { return @{ State = "$($c.State)"; Source = 'WindowsCapability' } }
            } catch { $null = $_ }
            return @{ State = 'Unknown'; Source = 'none' }
        }
        InstallOpenSshCapability = {
            try {
                $r = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
                return @{ Ok = $true; Detail = "Add-WindowsCapability OK. RestartNeeded=$($r.RestartNeeded)." }
            } catch { return @{ Ok = $false; Detail = "Add-WindowsCapability failed: $($_.Exception.Message)" } }
        }
        InstallOpenSshDism = {
            try {
                $out  = & dism.exe '/online' '/add-capability' '/capabilityname:OpenSSH.Server~~~~0.0.1.0' '/norestart' 2>&1
                $code = $LASTEXITCODE
                $ok   = ($code -eq 0 -or $code -eq 3010)
                return @{ Ok = $ok; Detail = "DISM exit=$code. Output: $($out -join ' | ')" }
            } catch { return @{ Ok = $false; Detail = "DISM threw: $($_.Exception.Message)" } }
        }
        SetSshdService = {
            try {
                Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction Stop
                Start-Service -Name 'sshd' -ErrorAction Stop
                $svc = Get-Service -Name 'sshd' -ErrorAction Stop
                return @{ Ok = $true; Status = "$($svc.Status)"; StartType = "$($svc.StartType)"; Detail = "sshd $($svc.Status), StartType=$($svc.StartType)." }
            } catch { return @{ Ok = $false; Status = 'unknown'; StartType = 'unknown'; Detail = "sshd configure failed: $($_.Exception.Message)" } }
        }
        WriteSshAuthorizedKey = {
            param([string]$Path,[string]$Key)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            # Append-or-replace: read existing, ensure exact key line is present, write back.
            $existing = @()
            if (Test-Path -LiteralPath $Path) {
                $existing = @(Get-Content -LiteralPath $Path -Encoding utf8)
            }
            $line = $Key.Trim()
            $hasIt = @($existing | Where-Object { $_.Trim() -eq $line }).Count -gt 0
            if (-not $hasIt) {
                $combined = @($existing | Where-Object { $_.Trim() }) + @($line)
                [System.IO.File]::WriteAllLines($Path, $combined, [System.Text.UTF8Encoding]::new($false))
            }
            return @{ Ok = $true; AlreadyPresent = $hasIt; Path = $Path }
        }
        HardenAuthorizedKeyAcl = {
            param([string]$Path)
            try {
                $acl = Get-Acl -Path $Path
                # Disable inheritance AND drop inherited rules from the in-memory ACL.
                # The second-arg $false copies-then-doesn't-preserve, so inherited
                # entries are removed by the call itself.
                $acl.SetAccessRuleProtection($true, $false)
                # Snapshot before mutation to avoid enumerate-while-modify, and only
                # touch explicit (non-inherited) rules -- inherited ones were already
                # dropped by SetAccessRuleProtection above.
                $snapshot = @($acl.Access | Where-Object { -not $_.IsInherited })
                foreach ($rule in $snapshot) { [void]$acl.RemoveAccessRule($rule) }
                $sys   = New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','Allow')
                $admin = New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','Allow')
                $acl.AddAccessRule($sys); $acl.AddAccessRule($admin)
                Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
                return @{ Ok = $true; Detail = "ACL hardened: SYSTEM:F + BUILTIN\Administrators:F only, no inheritance." }
            } catch { return @{ Ok = $false; Detail = "ACL harden failed: $($_.Exception.Message)" } }
        }
        # MeshAgent
        DownloadMeshAgent = {
            param([string]$SmbPath,[string]$HttpsUrl,[string]$Destination)
            # SMB first.
            if ($SmbPath -and (Test-Path -LiteralPath $SmbPath)) {
                try {
                    Copy-Item -LiteralPath $SmbPath -Destination $Destination -Force -ErrorAction Stop
                    return @{ Ok = $true; Source = 'smb'; Detail = "Copied from $SmbPath." }
                } catch { $null = $_ }
            }
            # HTTPS fallback.
            try {
                Invoke-WebRequest -Uri $HttpsUrl -OutFile $Destination -UseBasicParsing -SkipCertificateCheck -ErrorAction Stop
                return @{ Ok = $true; Source = 'https'; Detail = "Downloaded from $HttpsUrl." }
            } catch { return @{ Ok = $false; Source = 'none'; Detail = "Both SMB and HTTPS download failed. HTTPS error: $($_.Exception.Message)" } }
        }
        VerifyMeshAgentHash = {
            param([string]$Path,[string]$ExpectedSha256)
            if (-not $ExpectedSha256) { return @{ Ok = $true; Skipped = $true; Detail = 'No -ExpectedSha256 provided; integrity verification skipped.' } }
            try {
                $h = (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash
                $ok = ($h.ToLowerInvariant() -eq $ExpectedSha256.ToLowerInvariant())
                return @{ Ok = $ok; Skipped = $false; Hash = $h; Detail = if ($ok) { 'SHA256 verified.' } else { "SHA256 mismatch: actual=$h expected=$ExpectedSha256" } }
            } catch { return @{ Ok = $false; Skipped = $false; Detail = "Get-FileHash threw: $($_.Exception.Message)" } }
        }
        InstallMeshAgent = {
            param([string]$Installer)
            try {
                $p = Start-Process -FilePath $Installer -ArgumentList '-fullinstall' -Wait -PassThru -NoNewWindow -ErrorAction Stop
                $ok = ($p.ExitCode -eq 0)
                return @{ Ok = $ok; ExitCode = $p.ExitCode; Detail = "Mesh Agent installer exit=$($p.ExitCode)." }
            } catch { return @{ Ok = $false; ExitCode = -1; Detail = "Start-Process threw: $($_.Exception.Message)" } }
        }
        GetMeshAgentService = {
            try {
                $svc = Get-Service -Name 'Mesh Agent' -ErrorAction Stop
                return @{ Found = $true; Status = "$($svc.Status)" }
            } catch { return @{ Found = $false; Status = 'NotInstalled' } }
        }
    }
}

$script:AgentsInvokers = Get-DefaultAgentsInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-AgentsInvoker / Reset-AgentsInvoker."
    }
}

function Set-AgentsInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Confirm-TestSeamAllowed
    if (-not $script:AgentsInvokers.ContainsKey($Name)) {
        throw "Set-AgentsInvoker: unknown invoker '$Name'. Known: $(($script:AgentsInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:AgentsInvokers[$Name] = $ScriptBlock
}

function Reset-AgentsInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:AgentsInvokers = Get-DefaultAgentsInvoker
}

function Add-AgentStep {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Steps,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail','Skipped')][string]$Status,
        [string]$Detail,
        [string]$Remediation
    )
    $Steps.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Remediation = $Remediation })
}

# ---------- public ----------

function Invoke-AgentsStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Stage entry point; sub-steps honor -DryRun.')]
    [CmdletBinding()]
    param(
        $Config,
        [string]$AuthorizedKeyPath = (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'),
        [string]$SshAuthorizedKey,
        [string]$MeshAgentSmbPath,
        [string]$MeshAgentHttpsUrl,
        [string]$MeshAgentDestination = (Join-Path $env:TEMP 'meshagent-installer.exe'),
        [string]$MeshAgentSha256,
        [switch]$SkipMeshAgent,
        [switch]$DryRun
    )

    $steps = New-Object System.Collections.Generic.List[object]

    # ---------- OpenSSH capability ----------
    $sshState = & $script:AgentsInvokers.GetOpenSshState
    if ($sshState.State -eq 'Installed') {
        Add-AgentStep $steps 'OpenSSH Server feature' 'Pass' "Already Installed (source: $($sshState.Source))."
    } elseif ($DryRun) {
        Add-AgentStep $steps 'OpenSSH Server feature' 'Skipped' "DryRun: would install OpenSSH.Server capability (state: $($sshState.State))."
    } else {
        $i1 = & $script:AgentsInvokers.InstallOpenSshCapability
        if ($i1.Ok) {
            Add-AgentStep $steps 'OpenSSH Server feature' 'Pass' $i1.Detail
        } else {
            $i2 = & $script:AgentsInvokers.InstallOpenSshDism
            if ($i2.Ok) {
                Add-AgentStep $steps 'OpenSSH Server feature' 'Pass' "Primary failed; DISM fallback succeeded. $($i2.Detail)"
            } else {
                Add-AgentStep $steps 'OpenSSH Server feature' 'Fail' "Both Add-WindowsCapability AND DISM failed. cmdlet: $($i1.Detail). DISM: $($i2.Detail)" 'As Administrator: Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0'
            }
        }
    }

    # ---------- sshd service ----------
    if ($DryRun) {
        Add-AgentStep $steps 'sshd service' 'Skipped' 'DryRun: would Set-Service sshd Automatic + Start-Service.'
    } else {
        $s = & $script:AgentsInvokers.SetSshdService
        if ($s.Ok) {
            Add-AgentStep $steps 'sshd service' 'Pass' $s.Detail
        } else {
            Add-AgentStep $steps 'sshd service' 'Fail' $s.Detail 'As Administrator: Set-Service sshd -StartupType Automatic; Start-Service sshd'
        }
    }

    # ---------- authorized key ----------
    if (-not $SshAuthorizedKey -and $Config -and $Config.PSObject.Properties['ssh'] -and $Config.ssh -and `
        $Config.ssh.PSObject.Properties['admin_public_key']) {
        $SshAuthorizedKey = "$($Config.ssh.admin_public_key)"
    }
    if (-not $SshAuthorizedKey) {
        Add-AgentStep $steps 'Authorized key deployment' 'Warn' 'No -SshAuthorizedKey or Config.ssh.admin_public_key supplied; skipped.' 'Pass -SshAuthorizedKey ''ssh-ed25519 AAAA...'' or set Config.ssh.admin_public_key.'
    } elseif ($DryRun) {
        Add-AgentStep $steps 'Authorized key deployment' 'Skipped' "DryRun: would write key to $AuthorizedKeyPath."
        Add-AgentStep $steps 'Authorized key ACL' 'Skipped' "DryRun: would harden ACL on $AuthorizedKeyPath to SYSTEM:F + BUILTIN\Administrators:F, no inheritance."
    } else {
        $w = & $script:AgentsInvokers.WriteSshAuthorizedKey $AuthorizedKeyPath $SshAuthorizedKey
        $verb = if ($w.AlreadyPresent) { 'already present' } else { 'appended' }
        Add-AgentStep $steps 'Authorized key deployment' 'Pass' "Key $verb at $($w.Path)."

        # ---------- ACL hardening ----------
        $h = & $script:AgentsInvokers.HardenAuthorizedKeyAcl $AuthorizedKeyPath
        if ($h.Ok) {
            Add-AgentStep $steps 'Authorized key ACL' 'Pass' $h.Detail
        } else {
            Add-AgentStep $steps 'Authorized key ACL' 'Fail' $h.Detail "As Administrator: icacls '$AuthorizedKeyPath' /inheritance:r /grant 'NT AUTHORITY\SYSTEM:F' 'BUILTIN\Administrators:F'"
        }
    }

    # ---------- MeshAgent ----------
    if ($SkipMeshAgent) {
        Add-AgentStep $steps 'MeshAgent' 'Skipped' '-SkipMeshAgent specified.'
    } else {
        # Pull controller info from -Config if not explicitly supplied.
        if ((-not $MeshAgentSmbPath -or -not $MeshAgentHttpsUrl) -and `
            $Config -and $Config.PSObject.Properties['controller'] -and $Config.controller -and `
            $Config.controller.PSObject.Properties['address'] -and $Config.controller.address) {
            $addr = "$($Config.controller.address)"
            if (-not $MeshAgentSmbPath)   { $MeshAgentSmbPath   = "\\$addr\images\meshagent.exe" }
            if (-not $MeshAgentHttpsUrl)  { $MeshAgentHttpsUrl  = "https://$addr/meshagents?id=4" }
        }
        $existing = & $script:AgentsInvokers.GetMeshAgentService
        if ($existing.Found -and $existing.Status -eq 'Running') {
            Add-AgentStep $steps 'MeshAgent' 'Pass' "Mesh Agent service already Running."
        } elseif ($DryRun) {
            Add-AgentStep $steps 'MeshAgent' 'Skipped' "DryRun: would download from $MeshAgentSmbPath / $MeshAgentHttpsUrl and run -fullinstall."
        } elseif (-not $MeshAgentSmbPath -and -not $MeshAgentHttpsUrl) {
            Add-AgentStep $steps 'MeshAgent' 'Warn' 'No -MeshAgentSmbPath/HttpsUrl and no controller.address in config; skipped install.' 'Provide controller address or pass -MeshAgentSmbPath / -MeshAgentHttpsUrl.'
        } else {
            $d = & $script:AgentsInvokers.DownloadMeshAgent $MeshAgentSmbPath $MeshAgentHttpsUrl $MeshAgentDestination
            if (-not $d.Ok) {
                $smbDisplay   = if ($MeshAgentSmbPath)  { $MeshAgentSmbPath }  else { '<none>' }
                $httpsDisplay = if ($MeshAgentHttpsUrl) { $MeshAgentHttpsUrl } else { '<none>' }
                Add-AgentStep $steps 'MeshAgent download' 'Fail' $d.Detail "Verify the controller is reachable at $smbDisplay or $httpsDisplay."
            } else {
                Add-AgentStep $steps 'MeshAgent download' 'Pass' "Downloaded (source=$($d.Source)). $($d.Detail)"
                $v = & $script:AgentsInvokers.VerifyMeshAgentHash $MeshAgentDestination $MeshAgentSha256
                if ($v.Ok) {
                    if ($v.Skipped) { Add-AgentStep $steps 'MeshAgent SHA256' 'Warn' $v.Detail 'Provide -MeshAgentSha256 to enable integrity verification.' }
                    else            { Add-AgentStep $steps 'MeshAgent SHA256' 'Pass' $v.Detail }
                    $ins = & $script:AgentsInvokers.InstallMeshAgent $MeshAgentDestination
                    if ($ins.Ok) {
                        $svc = & $script:AgentsInvokers.GetMeshAgentService
                        if ($svc.Found -and $svc.Status -eq 'Running') {
                            Add-AgentStep $steps 'MeshAgent install' 'Pass' "Installed; Mesh Agent service $($svc.Status)."
                        } else {
                            Add-AgentStep $steps 'MeshAgent install' 'Warn' "Installer exit=0 but Mesh Agent service status=$($svc.Status). Wait 30s and re-check; service registration is async." 'Get-Service ''Mesh Agent''; if Stopped, Start-Service ''Mesh Agent''.'
                        }
                    } else {
                        Add-AgentStep $steps 'MeshAgent install' 'Fail' $ins.Detail "Run installer manually: '$MeshAgentDestination' -fullinstall"
                    }
                } else {
                    Add-AgentStep $steps 'MeshAgent SHA256' 'Fail' $v.Detail 'Re-download from a trusted source or verify the controller has the matching installer.'
                }
            }
        }
    }

    # ---------- summary ----------
    $passCount = @($steps | Where-Object { $_.Status -eq 'Pass'    }).Count
    $warnCount = @($steps | Where-Object { $_.Status -eq 'Warn'    }).Count
    $failCount = @($steps | Where-Object { $_.Status -eq 'Fail'    }).Count
    $skipCount = @($steps | Where-Object { $_.Status -eq 'Skipped' }).Count
    $overall = if ($failCount -gt 0) { 'Fail' } elseif ($warnCount -gt 0) { 'Warn' } else { 'Pass' }

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($s in $steps) {
            $lvl = switch ($s.Status) {
                'Pass' { 'Info' } 'Warn' { 'Warn' } 'Fail' { 'Error' } 'Skipped' { 'Info' }
            }
            Write-ClusterLog -Level $lvl -Stage 'agents' -Message "$($s.Name): $($s.Status)" -Data @{ detail = $s.Detail }
        }
        Write-ClusterLog -Level Info -Stage 'agents' -Message "Agents complete: $overall (pass=$passCount warn=$warnCount fail=$failCount skipped=$skipCount)"
    }

    return [pscustomobject]@{
        Overall    = $overall
        Steps      = $steps.ToArray()
        PassCount  = $passCount
        WarnCount  = $warnCount
        FailCount  = $failCount
        SkipCount  = $skipCount
    }
}
