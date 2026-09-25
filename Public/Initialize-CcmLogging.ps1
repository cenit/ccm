function Initialize-CcmLogging {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Name,
        [string]$LogDirectory,
        [switch]$NoCreateDockerignore,
        [switch]$NoIgnorePatching
    )

    $callerFrame = (Get-PSCallStack)[1]
    $callerScript = $callerFrame.ScriptName
    if (-not $Name) {
        if (-not $callerScript) {
            throw "Initialize-CcmLogging requires -Name when called outside a script (no caller script frame found)."
        }
        $Name = [IO.Path]::GetFileNameWithoutExtension($callerScript)
    }

    if (-not $LogDirectory) {
        if (-not $callerScript) {
            throw "Initialize-CcmLogging requires -LogDirectory when called outside a script."
        }
        $scriptDir = Split-Path -Parent $callerScript
        if ($IsInGitSubmodule) {
            $LogDirectory = Split-Path -Parent $scriptDir
        } else {
            $LogDirectory = $scriptDir
        }
    }
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path

    $logPath = Join-Path $LogDirectory "$Name.log"
    try {
        Start-Transcript -Path $logPath -ErrorAction Stop | Out-Null
    } catch {
        $logPath = Join-Path $LogDirectory ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $Name, (Get-Date))
        Start-Transcript -Path $logPath -ErrorAction Stop | Out-Null
    }
    $started = Get-Date

    $repoRoot = $null
    try {
        Push-Location $LogDirectory
        $rawRoot = (& git rev-parse --show-toplevel 2>$null) | Out-String
        $rawRoot = $rawRoot.Trim()
        if ($rawRoot) {
            $repoRoot = (Resolve-Path -LiteralPath $rawRoot).Path
        }
    } catch { $repoRoot = $null } finally { Pop-Location }

    $gitignorePatched    = $false
    $dockerignorePatched = $false
    $containerized       = $false
    if ($repoRoot -and -not $NoIgnorePatching) {
        $pattern = "$Name*.log"
        $gitignorePatched = Add-IgnorePatternBlock -Path (Join-Path $repoRoot '.gitignore') -Pattern $pattern -BlockId 'CCM logs' -CreateIfMissing $true
        $containerized = Test-IsContainerizedRepository -Path $repoRoot
        if ($containerized) {
            $createDocker = -not $NoCreateDockerignore.IsPresent
            $dockerignorePatched = Add-IgnorePatternBlock -Path (Join-Path $repoRoot '.dockerignore') -Pattern $pattern -BlockId 'CCM logs' -CreateIfMissing $createDocker
        }
    } elseif (-not $repoRoot) {
        Write-CcmWarning "Initialize-CcmLogging: $LogDirectory is not inside a git repository - skipping .gitignore/.dockerignore patching."
    }

    $exitSub = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    $state = [pscustomobject]@{
        Name                = $Name
        LogPath             = (Resolve-Path -LiteralPath $logPath).Path
        LogDirectory        = $LogDirectory
        RepoRoot            = $repoRoot
        IsContainerized     = $containerized
        GitignorePatched    = $gitignorePatched
        DockerignorePatched = $dockerignorePatched
        Started             = $started
        EventSubscriberId   = $exitSub.Id
        Stopped             = $false
    }
    Add-Member -InputObject $state -MemberType ScriptMethod -Name 'Stop' -Value { Stop-CcmLogging $this }

    return $state
}
