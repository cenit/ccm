function Resolve-CcmContainerRuntime {
    <#
    .SYNOPSIS
        Resolves which container runtime (wslc, docker, or podman) to use.
    .DESCRIPTION
        Central runtime selection for CCM container scripts.

        When -Prefer is given it is a hard requirement: the tool must be on
        PATH or the function throws. When -Prefer is empty the function
        auto-detects in the order wslc -> docker -> podman and returns the
        first found. wslc is Windows-only; on other platforms it is simply
        absent and detection falls through with no OS-specific checks.

        wslc has no `compose` command yet. Callers that need `<tool> compose`
        pass -RequireCompose, which excludes wslc from both explicit selection
        and auto-detect.
    .PARAMETER Prefer
        '' (auto-detect, default), 'wslc', 'docker', or 'podman'.
    .PARAMETER RequireCompose
        The caller needs `<tool> compose`. Excludes wslc.
    .OUTPUTS
        [hashtable] @{ Kind = 'wslc'|'docker'|'podman'; Command = '<tool>' }
    .EXAMPLE
        $rt = Resolve-CcmContainerRuntime            # auto-detect, wslc-first
        & $rt.Command build -t app:latest .
    .EXAMPLE
        $rt = Resolve-CcmContainerRuntime -Prefer 'podman' -RequireCompose
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateSet('', 'wslc', 'docker', 'podman')]
        [string]$Prefer = '',

        [switch]$RequireCompose
    )

    $composeMsg = "wslc has no compose support yet; use -UseDocker or -UsePodman for compose-based workflows (tracking: https://github.com/clystian/WSL/pull/1)."

    # Explicit preference -> hard requirement.
    if ($Prefer) {
        if ($Prefer -eq 'wslc' -and $RequireCompose) {
            throw $composeMsg
        }
        if (-not (Get-Command $Prefer -ErrorAction SilentlyContinue)) {
            throw "$Prefer not found. '$Prefer' was requested but is not available on PATH."
        }
        return @{ Kind = $Prefer; Command = $Prefer }
    }

    # Auto-detect. wslc is preferred unless compose is required.
    if (-not $RequireCompose -and (Get-Command 'wslc' -ErrorAction SilentlyContinue)) {
        return @{ Kind = 'wslc'; Command = 'wslc' }
    }

    if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
        if (-not $RequireCompose) {
            Write-Host "wslc not found, using docker instead" -ForegroundColor Gray
        }
        return @{ Kind = 'docker'; Command = 'docker' }
    }

    if (Get-Command 'podman' -ErrorAction SilentlyContinue) {
        if ($RequireCompose) {
            Write-Host "docker not found, using podman instead" -ForegroundColor Yellow
        } else {
            Write-Host "wslc and docker not found, using podman instead" -ForegroundColor Yellow
        }
        return @{ Kind = 'podman'; Command = 'podman' }
    }

    if ($RequireCompose) {
        throw "Neither docker nor podman found on PATH. Install one of them to run compose-based workflows."
    }
    throw "No container runtime found on PATH. Install wslc, docker, or podman."
}
