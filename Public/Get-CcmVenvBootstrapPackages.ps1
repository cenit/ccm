function Get-CcmVenvBootstrapPackages {
    <#
    .SYNOPSIS
    Selects which bootstrap packages (pip, setuptools) present in a venv should be
    upgraded, from the JSON output of `uv pip list --format json`.

    .DESCRIPTION
    `uv venv` does not seed pip; it arrives transitively (pip-audit -> pip-api ->
    pip), and setuptools arrives as a build dependency. Because `uv pip install`
    leaves an already-satisfied package alone, a long-lived venv keeps whatever
    versions it was first seeded with, which then trip ci-checks.ps1's pip-audit
    CVE gate even when nothing in the project changed.

    setup-venv.ps1 upgrades those two after the project install, but only when they
    are already present, so a bare venv that never pulled pip in stays bare. This
    function is that selection rule, split out so it can be unit tested without
    creating a venv.

    Package names are matched case-insensitively and returned in a stable order
    (pip before setuptools) so the resulting command line is deterministic.

    .PARAMETER PipListJson
    Raw stdout of `uv pip list --format json`. Accepts either a single string or
    the string array PowerShell produces when a native command writes several
    lines. Empty, whitespace-only, or malformed JSON yields an empty result rather
    than throwing: this runs at the very end of an otherwise successful venv setup,
    where failing to parse an optional listing should not fail the whole setup.

    .OUTPUTS
    [string[]] - the bootstrap package names to upgrade; empty if none are present.

    .EXAMPLE
    Get-CcmVenvBootstrapPackages -PipListJson '[{"name":"pip","version":"24.0"}]'
    # -> pip
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$PipListJson
    )

    # Known bootstrap packages, in the order they should appear on the command line.
    $bootstrapNames = @('pip', 'setuptools')

    if ($null -eq $PipListJson) { return @() }

    # A native command writes one array element per line. Both PowerShell 7 and
    # Windows PowerShell 5.1 accept that array in ConvertFrom-Json, but joining it
    # first (the convention used elsewhere in this repo) gives the emptiness check
    # below a single well-defined string to test instead of an Object[].
    $raw = (@($PipListJson) -join "`n")
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    try {
        $installed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Verbose "Get-CcmVenvBootstrapPackages: could not parse package list as JSON: $($_.Exception.Message)"
        return @()
    }

    $present = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($package in @($installed)) {
        if ($package -and $package.PSObject.Properties.Name -contains 'name' -and $package.name) {
            [void]$present.Add("$($package.name)")
        }
    }

    return @($bootstrapNames | Where-Object { $present.Contains($_) })
}
