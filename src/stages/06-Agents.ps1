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
        UninstallMeshAgent = {
            # Run the existing agent's -fulluninstall to remove a leftover
            # from a prior test / different controller. Idempotent: no-op
            # if the binary isn't there.
            $mh = 'C:\Program Files\Mesh Agent\MeshAgent.exe'
            if (-not (Test-Path -LiteralPath $mh)) { return @{ Ok = $true; Detail = 'no prior MeshAgent.exe to uninstall' } }
            try {
                $p = Start-Process -FilePath $mh -ArgumentList '-fulluninstall' -Wait -PassThru -NoNewWindow -ErrorAction Stop
                Start-Sleep -Seconds 4
                return @{ Ok = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; Detail = "-fulluninstall exit=$($p.ExitCode)" }
            } catch { return @{ Ok = $false; ExitCode = -1; Detail = "-fulluninstall threw: $($_.Exception.Message)" } }
        }
        GetMeshAgentService = {
            try {
                $svc = Get-Service -Name 'Mesh Agent' -ErrorAction Stop
                return @{ Found = $true; Status = "$($svc.Status)" }
            } catch { return @{ Found = $false; Status = 'NotInstalled' } }
        }
        # Read the agent .msh config that ships next to MeshAgent.exe. The
        # installer writes this when -fullinstall runs; it records the
        # MeshServer URL, MeshID, and ServerID this agent binds to. We use
        # it to (a) detect a leftover agent bound to a DIFFERENT controller
        # (bug 21) and (b) rewrite MeshServer=local to an explicit URL
        # when mDNS discovery isn't reliable.
        GetAgentMshConfig = {
            param([string]$MshPath = 'C:\Program Files\Mesh Agent\MeshAgent.msh')
            if (-not (Test-Path -LiteralPath $MshPath)) {
                return [pscustomobject]@{ Found = $false; MeshServer = $null; MeshName = $null; Path = $MshPath }
            }
            $kv = @{}
            foreach ($line in (Get-Content -LiteralPath $MshPath -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*([^=#]+?)\s*=\s*(.*?)\s*$') {
                    $kv[$Matches[1]] = $Matches[2]
                }
            }
            return [pscustomobject]@{
                Found      = $true
                MeshServer = $kv['MeshServer']
                MeshName   = $kv['MeshName']
                MeshID     = $kv['MeshID']
                ServerID   = $kv['ServerID']
                Path       = $MshPath
            }
        }
        # Rewrite MeshServer=local (mDNS discovery) to an explicit
        # wss://<addr>:<port>/agent.ashx URL. Used when mDNS isn't routing
        # (most workgroup / non-flat-LAN deploys). Returns @{Ok; Changed}.
        SetAgentMshServer = {
            param([string]$NewMeshServer, [string]$MshPath = 'C:\Program Files\Mesh Agent\MeshAgent.msh')
            if (-not (Test-Path -LiteralPath $MshPath)) {
                return @{ Ok = $false; Changed = $false; Detail = "MeshAgent.msh not at $MshPath" }
            }
            try {
                $content = Get-Content -LiteralPath $MshPath -Raw
                $new = $content -replace '(?m)^MeshServer\s*=\s*.+$', "MeshServer=$NewMeshServer"
                if ($new -eq $content) {
                    return @{ Ok = $true; Changed = $false; Detail = "MeshServer already matched $NewMeshServer" }
                }
                [System.IO.File]::WriteAllText($MshPath, $new, [System.Text.UTF8Encoding]::new($false))
                return @{ Ok = $true; Changed = $true; Detail = "MeshServer rewritten to $NewMeshServer" }
            } catch { return @{ Ok = $false; Changed = $false; Detail = "$($_.Exception.Message)" } }
        }
        # Open / close SMB authentication context for the controller share.
        # Mirrors lib-level bug 17 in windows-cluster-host VMs stage.
        OpenSmbAuth = {
            param([string]$UncPath,[string]$User,[string]$Password)
            if (-not $UncPath -or -not $User -or -not $Password) {
                return @{ Ok = $false; SharePath = $null; Detail = 'no smb credentials supplied; using implicit auth' }
            }
            if ($UncPath -notmatch '^(\\\\[^\\]+\\[^\\]+)') {
                return @{ Ok = $false; SharePath = $null; Detail = "'$UncPath' is not a UNC share path" }
            }
            $share = $Matches[1]
            try {
                $existing = Get-SmbMapping -RemotePath $share -ErrorAction SilentlyContinue
                if ($existing) {
                    Remove-SmbMapping -RemotePath $share -Force -UpdateProfile -ErrorAction SilentlyContinue
                }
                New-SmbMapping -RemotePath $share -UserName $User -Password $Password -ErrorAction Stop | Out-Null
                return @{ Ok = $true; SharePath = $share; Detail = "Mounted $share as $User." }
            } catch {
                return @{ Ok = $false; SharePath = $share; Detail = "New-SmbMapping failed: $($_.Exception.Message)" }
            }
        }
        CloseSmbAuth = {
            param([string]$SharePath)
            if (-not $SharePath) { return }
            try { Remove-SmbMapping -RemotePath $SharePath -Force -UpdateProfile -ErrorAction SilentlyContinue }
            catch { $null = $_ }
        }
        # Restart the Mesh Agent service after a .msh edit so it picks up
        # the new MeshServer URL.
        RestartMeshAgentService = {
            param([int]$WaitSec = 15)
            try {
                Stop-Service 'Mesh Agent' -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Start-Service 'Mesh Agent' -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds($WaitSec)
                while ((Get-Date) -lt $deadline) {
                    $svc = Get-Service 'Mesh Agent' -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        return @{ Ok = $true; Detail = 'Mesh Agent restarted, Status=Running' }
                    }
                    Start-Sleep -Milliseconds 500
                }
                return @{ Ok = $false; Detail = "Mesh Agent did not reach Running within ${WaitSec}s" }
            } catch { return @{ Ok = $false; Detail = "Restart failed: $($_.Exception.Message)" } }
        }
        # Verify the Mesh Agent has an established TCP connection to a
        # SPECIFIC controller address:port. Returns @{Connected; Detail}
        # so the stage can distinguish "bound to OUR controller" from
        # "bound to some other MeshCentral server".
        TestAgentConnectedTo = {
            param([string]$ExpectedAddress, [int]$ExpectedPort, [int]$WaitSec = 30)
            $deadline = (Get-Date).AddSeconds($WaitSec)
            while ((Get-Date) -lt $deadline) {
                $proc = Get-Process MeshAgent -ErrorAction SilentlyContinue
                if ($proc) {
                    $conns = @(Get-NetTCPConnection -OwningProcess $proc.Id -State Established -ErrorAction SilentlyContinue |
                               Where-Object { $_.RemoteAddress -eq $ExpectedAddress -and $_.RemotePort -eq $ExpectedPort })
                    if ($conns.Count -gt 0) {
                        return @{ Connected = $true; Detail = "Established to ${ExpectedAddress}:$ExpectedPort" }
                    }
                }
                Start-Sleep -Milliseconds 750
            }
            $proc = Get-Process MeshAgent -ErrorAction SilentlyContinue
            $where = if ($proc) {
                $other = @(Get-NetTCPConnection -OwningProcess $proc.Id -State Established -ErrorAction SilentlyContinue |
                           Select-Object @{N='r';E={"$($_.RemoteAddress):$($_.RemotePort)"}} |
                           Select-Object -ExpandProperty r) -join ', '
                if ($other) { "(currently connected to: $other)" } else { '(no established connections)' }
            } else { '(MeshAgent process not running)' }
            return @{ Connected = $false; Detail = "did not observe connection to ${ExpectedAddress}:$ExpectedPort within ${WaitSec}s $where" }
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
    # Bug 21: previously this block only checked 'is the Mesh Agent service
    # running?' and called it a Pass. That accepts a leftover agent bound to
    # a DIFFERENT MeshCentral (e.g. a public meshcentral.com test). The
    # rewrite below: download the controller-specific installer from OUR
    # controller's SMB share, uninstall any leftover bound elsewhere, run
    # -fullinstall, rewrite MeshServer=local -> explicit URL when needed,
    # then VERIFY there is an established TCP connection to our controller.
    if ($SkipMeshAgent) {
        Add-AgentStep $steps 'MeshAgent' 'Skipped' '-SkipMeshAgent specified.'
    } else {
        # Resolve config-driven controller address / port / group / share /
        # SMB creds (mirrors VMs stage bug-17 design).
        $cfgController = if ($Config -and $Config.PSObject.Properties['controller']) { $Config.controller } else { $null }
        $addr = if ($cfgController -and $cfgController.PSObject.Properties['address']) { "$($cfgController.address)" } else { $null }
        $port = if ($cfgController -and $cfgController.PSObject.Properties['port'] -and $cfgController.port) {
                    [int]$cfgController.port
                } else { 443 }
        $smbUser = if ($cfgController -and $cfgController.PSObject.Properties['smb_username'] -and $cfgController.smb_username) {
                       "$($cfgController.smb_username)"
                   } else { $null }
        $smbPass = if ($cfgController -and $cfgController.PSObject.Properties['smb_password'] -and $cfgController.smb_password) {
                       "$($cfgController.smb_password)"
                   } else { $null }
        $cfgAgent = if ($Config -and $Config.PSObject.Properties['agent']) { $Config.agent } else { $null }
        $smbShare  = if ($cfgAgent -and $cfgAgent.PSObject.Properties['smb_share']  -and $cfgAgent.smb_share)  { "$($cfgAgent.smb_share)"  } else { 'ClusterShare' }
        $group     = if ($cfgAgent -and $cfgAgent.PSObject.Properties['group']      -and $cfgAgent.group)      { "$($cfgAgent.group)"      } else { 'cluster-hosts' }
        $smbSubdir = if ($cfgAgent -and $cfgAgent.PSObject.Properties['smb_subdir'] -and $cfgAgent.smb_subdir) { "$($cfgAgent.smb_subdir)" } else { "agents\$group" }
        $fileName  = if ($cfgAgent -and $cfgAgent.PSObject.Properties['filename']   -and $cfgAgent.filename)   { "$($cfgAgent.filename)"   } else { "meshagent64-$group.exe" }
        if (-not $MeshAgentSmbPath -and $addr) {
            $segments = @($smbShare, $smbSubdir, $fileName) | Where-Object { $_ } | ForEach-Object { $_.Trim('\') }
            $MeshAgentSmbPath = "\\$addr\" + ($segments -join '\')
        }
        if (-not $MeshAgentHttpsUrl -and $addr) {
            $MeshAgentHttpsUrl = "https://$addr/meshagents?id=4"
        }
        $expectedMeshServer = if ($addr) { "wss://${addr}:${port}/agent.ashx" } else { $null }

        $existing = & $script:AgentsInvokers.GetMeshAgentService

        if ($DryRun) {
            Add-AgentStep $steps 'MeshAgent' 'Skipped' "DryRun: would source from $MeshAgentSmbPath / $MeshAgentHttpsUrl, install, verify connection to ${addr}:$port."
        } elseif (-not $addr) {
            Add-AgentStep $steps 'MeshAgent' 'Warn' 'No controller.address in config and no -MeshAgentSmbPath supplied; cannot verify which controller to bind to.' 'Set controller.address in cluster-config.json or pass -MeshAgentSmbPath / -MeshAgentHttpsUrl.'
        } else {
            # Decide: is there a leftover agent bound to a DIFFERENT controller?
            $needsReinstall = $true
            if ($existing.Found) {
                $msh = & $script:AgentsInvokers.GetAgentMshConfig
                if ($msh.Found -and $msh.MeshName -eq $group) {
                    # Existing agent's group matches; check live connection too.
                    $live = & $script:AgentsInvokers.TestAgentConnectedTo $addr $port 3
                    if ($live.Connected) {
                        Add-AgentStep $steps 'MeshAgent' 'Pass' "Already installed, group='$group', connected to ${addr}:$port."
                        $needsReinstall = $false
                    } else {
                        Add-AgentStep $steps 'MeshAgent existing' 'Warn' "Found existing Mesh Agent (group='$($msh.MeshName)') but not connected to ${addr}:$port; will reinstall."
                    }
                } elseif ($msh.Found) {
                    Add-AgentStep $steps 'MeshAgent existing' 'Warn' "Found Mesh Agent bound to OTHER group '$($msh.MeshName)' / server '$($msh.MeshServer)'; uninstalling before binding to '$group'."
                }
            }

            if ($needsReinstall) {
                if ($existing.Found) {
                    $un = & $script:AgentsInvokers.UninstallMeshAgent
                    if ($un.Ok) {
                        Add-AgentStep $steps 'MeshAgent uninstall (prior)' 'Pass' $un.Detail
                    } else {
                        Add-AgentStep $steps 'MeshAgent uninstall (prior)' 'Warn' $un.Detail
                    }
                }

                # SMB auth (workgroup deploys need explicit controller creds).
                $smbAuthState = $null
                if ($MeshAgentSmbPath -and $smbUser -and $smbPass) {
                    $smbAuthState = & $script:AgentsInvokers.OpenSmbAuth $MeshAgentSmbPath $smbUser $smbPass
                    if ($smbAuthState.Ok) {
                        Add-AgentStep $steps 'SMB auth to controller' 'Pass' $smbAuthState.Detail
                    } else {
                        Add-AgentStep $steps 'SMB auth to controller' 'Warn' $smbAuthState.Detail 'Continuing with implicit auth; SMB Copy-Item may fail.'
                    }
                }
                try {
                    $d = & $script:AgentsInvokers.DownloadMeshAgent $MeshAgentSmbPath $MeshAgentHttpsUrl $MeshAgentDestination
                } finally {
                    if ($smbAuthState -and $smbAuthState.Ok -and $smbAuthState.SharePath) {
                        & $script:AgentsInvokers.CloseSmbAuth $smbAuthState.SharePath
                    }
                }
                if (-not $d.Ok) {
                    Add-AgentStep $steps 'MeshAgent download' 'Fail' $d.Detail "Verify $MeshAgentSmbPath exists on the controller and SMB auth (controller.smb_username/smb_password) is correct."
                } else {
                    Add-AgentStep $steps 'MeshAgent download' 'Pass' "Downloaded (source=$($d.Source)). $($d.Detail)"
                    $v = & $script:AgentsInvokers.VerifyMeshAgentHash $MeshAgentDestination $MeshAgentSha256
                    if (-not $v.Ok) {
                        Add-AgentStep $steps 'MeshAgent SHA256' 'Fail' $v.Detail 'Re-download from a trusted source or verify the controller has the matching installer.'
                    } else {
                        if ($v.Skipped) {
                            Add-AgentStep $steps 'MeshAgent SHA256' 'Warn' $v.Detail 'Provide -MeshAgentSha256 to enable integrity verification.'
                        } else {
                            Add-AgentStep $steps 'MeshAgent SHA256' 'Pass' $v.Detail
                        }
                        $ins = & $script:AgentsInvokers.InstallMeshAgent $MeshAgentDestination
                        if (-not $ins.Ok) {
                            Add-AgentStep $steps 'MeshAgent install' 'Fail' $ins.Detail "Run installer manually: '$MeshAgentDestination' -fullinstall"
                        } else {
                            Add-AgentStep $steps 'MeshAgent install' 'Pass' $ins.Detail
                            # If the .msh shipped with MeshServer=local (mDNS
                            # auto-discovery) and we have an explicit address,
                            # rewrite to the explicit URL so cross-subnet /
                            # mDNS-blocked LANs still work.
                            $msh2 = & $script:AgentsInvokers.GetAgentMshConfig
                            if ($msh2.Found -and $msh2.MeshServer -eq 'local' -and $expectedMeshServer) {
                                $set = & $script:AgentsInvokers.SetAgentMshServer $expectedMeshServer
                                if ($set.Changed) {
                                    $restart = & $script:AgentsInvokers.RestartMeshAgentService 20
                                    Add-AgentStep $steps 'MeshAgent .msh rewrite' 'Pass' "$($set.Detail); $($restart.Detail)"
                                } else {
                                    Add-AgentStep $steps 'MeshAgent .msh rewrite' 'Pass' $set.Detail
                                }
                            }
                        }
                    }
                }
            }

            # Final verification: regardless of whether we reinstalled or
            # accepted the existing agent, the bug-21 contract is that we
            # have to observe an established connection to OUR controller.
            $verify = & $script:AgentsInvokers.TestAgentConnectedTo $addr $port 30
            if ($verify.Connected) {
                Add-AgentStep $steps 'MeshAgent connection verify' 'Pass' $verify.Detail
            } else {
                Add-AgentStep $steps 'MeshAgent connection verify' 'Warn' $verify.Detail 'mDNS may not be routing; check controller firewall, or edit MeshAgent.msh to set MeshServer=wss://<addr>:<port>/agent.ashx and restart the Mesh Agent service.'
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
