function Get-CcmImageBuildArgs {
    <#
    .SYNOPSIS
        Build the --build-arg list for a container image build, injecting APP_VERSION.

    .DESCRIPTION
        Every application wants to report its own version, and every one that
        hard-codes it drifts from its version file eventually: the app serves one
        number while the image it runs in carries another, and nobody notices
        until someone compares the two during an incident.

        The deploy script already knows the version -- it resolved it from the
        project's version file, or from an explicit image tag -- so this injects
        it as APP_VERSION rather than making every project wire the same thing up
        for itself.

        Injecting here rather than from a pipeline is deliberate: a local deploy
        run gets the same value, instead of silently falling back to whatever
        default the Dockerfile declares.

        An image that does not declare `ARG APP_VERSION` is unaffected. An
        unconsumed build arg is a warning in both docker and podman, never an
        error, so this is safe for projects that have not adopted it.

    .PARAMETER Version
        The resolved application version, injected as APP_VERSION unless the
        caller already supplies one.

    .PARAMETER BuildArgs
        Caller-supplied build arguments as key=value strings. A caller-supplied
        APP_VERSION wins and suppresses the injection, so this is always
        overridable.

    .OUTPUTS
        [string[]] The flattened argument list, alternating '--build-arg' and
        each key=value pair, ready to splat into a container build command.
        Returns an empty array when there is nothing to pass.

    .EXAMPLE
        Get-CcmImageBuildArgs -Version '1.2.3'
        # --build-arg APP_VERSION=1.2.3

    .EXAMPLE
        Get-CcmImageBuildArgs -Version '1.2.3' -BuildArgs 'VITE_API_URL=https://example.com'
        # --build-arg APP_VERSION=1.2.3 --build-arg VITE_API_URL=https://example.com

    .EXAMPLE
        Get-CcmImageBuildArgs -Version '1.2.3' -BuildArgs 'APP_VERSION=override'
        # --build-arg APP_VERSION=override
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Version,

        [string[]]$BuildArgs
    )

    $result = @()

    $callerSuppliedAppVersion = @($BuildArgs) | Where-Object { $_ -like 'APP_VERSION=*' }
    if (-not $callerSuppliedAppVersion -and -not [string]::IsNullOrWhiteSpace($Version)) {
        $result += '--build-arg'
        $result += "APP_VERSION=$Version"
    }

    foreach ($arg in @($BuildArgs)) {
        if ([string]::IsNullOrWhiteSpace($arg)) { continue }
        $result += '--build-arg'
        $result += $arg
    }

    return , [string[]]$result
}
